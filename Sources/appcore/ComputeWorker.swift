//
//  ComputeWorker.swift
//  kappserver
//
//  Created by Mark Lilback on 9/14/19.
//

import Foundation
import Logging
import Socket

/// for owner that needs to get callbacks
public protocol ComputeWorkerDelegate: class {
	/// the data will be invalid after this call. (it is pointing to a raw memory buffer that will be deallocated)
	func handleCompute(data: Data)
	func handleCompute(error: ComputeError)
	/// status updates just inform about a state change. If something failed, an error will be reported after the state change
	func handleCompute(statusUpdate: ComputeState)
	/// called when the connection is found to be closed while reading
	func handleConnectionClosed()
}

/// used for a state machine of the connection status
public enum ComputeState: Int, CaseIterable {
	case uninitialized
	case initialHostSearch
	case loading
	case connecting
	case connected
	case failedToConnect
	case unusable
}

/// encapsulates all communication with the compute engine
public class ComputeWorker {
	let logger: Logger
	let config: AppConfiguration
	let wspaceId: Int
	let sessionId: Int
	let k8sServer: K8sServer?
	private var socket: Socket? = nil
	private var readBuffer: UnsafeMutablePointer<CChar>
	private var readBufferSize: Int
	private let readQueue: DispatchQueue
	private let lock = DispatchSemaphore(value: 1)
	
	private weak var delegate: ComputeWorkerDelegate?
	private(set) var state: ComputeState = .uninitialized {
		didSet { delegate?.handleCompute(statusUpdate: state) }
	}
	private var podFailureCount = 0
	
	init(wspaceId: Int, sessionId: Int, k8sServer:  K8sServer? = nil, config: AppConfiguration, logger: Logger, delegate: ComputeWorkerDelegate, queue: DispatchQueue?)
	{
		self.logger = logger
		self.config = config
		self.sessionId = sessionId
		self.wspaceId = wspaceId
		self.delegate = delegate
		self.k8sServer = k8sServer
		readBufferSize = config.computeReadBufferSize
		readBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: readBufferSize)
		readBuffer.initialize(repeating: 0, count: readBufferSize)
		readQueue = queue ?? DispatchQueue.global(qos: .default)
	}

	deinit {
		readBuffer.deallocate()
	}
	
	// MARK: - functions
	
	public func start() throws {
		assert(state == .uninitialized, "programmer error: invalid state")
		guard config.computeViaK8s else {
			try openConnection(ipAddr: config.computeHost)
			return
		}
		guard k8sServer != nil else { fatalError("programmer error: can't use k8s without a k8s server") }
		// need to start dance of finding and/or launching the compute k8s pod
		state = .initialHostSearch
		updateStatus()
	}
	
	public func shutdown() throws {
		guard state == .connected, socket?.isConnected ?? false else {
			logger.info("asked to shutdown when not running")
			throw ComputeError.notConnected
		}
		socket?.close()
		socket = nil
	}
	
	public func send(data: Data) throws {
		guard data.count > 0 else { throw ComputeError.sendingEmptyMessage }
		guard state == .connected, let socket = socket, socket.isConnected else { throw ComputeError.notConnected }
		var headBytes = [UInt8](repeating: 0, count: 8)
		headBytes.replaceSubrange(0...3, with: valueByteArray(UInt32(0x21).byteSwapped))
		headBytes.replaceSubrange(4...7, with: valueByteArray(UInt32(data.count).byteSwapped))
		let rawData = Data(headBytes) + data
		logger.info("sending to compute: \(String(data: rawData, encoding: .utf8) ?? "no data" )")
		do {
			try socket.write(from: rawData)
		} catch {
			logger.warning("failed to write: \(error)")
			throw ComputeError.failedToWrite
		}
	}

	// MARK: - private methods
	
	private func launchCompute() {
		guard let k8sServer = k8sServer else { fatalError("missing k8s server") }
		state = .loading
		k8sServer.launchCompute(wspaceId: wspaceId, sessionId: sessionId).onSuccess { _ in
			self.updateStatus()
			}.onFailure { error in
				self.logger.error("error launching compute: \(error)")
				self.state = .unusable
				self.delegate?.handleCompute(error: .failedToConnect)
		}
	}

	private func openConnection(ipAddr: String) throws {
		do {
			self.state = .connecting
			socket = try Socket.create()
			socket?.readBufferSize = 32768 // 32 KB
			let port = Int32(config.computePort) //kitura uses Int32 for legacy purposes
			logger.debug("compute connectding to \(config.computeHost):\(port)")
			try socket?.connect(to: config.computeHost, port: port)
			logger.debug("compute worker socket open")
			self.state = .connected
			readQueue.async { [weak self] in
				self?.readNext()
			}
		} catch {
			logger.error("error opening socket to compute engine: \(error)")
			self.state = .failedToConnect
			throw ComputeError.failedToConnect
		}
	}
	
	private func updateStatus() {
		fatalError("not implemented")
	}
	
	private func readNext() {
		guard let socket = socket, socket.isActive, !socket.remoteConnectionClosed else {
			if state == .unusable { return } //duplicate time
			state = .unusable
			logger.warning("no open socket to read or closed connection")
			delegate?.handleConnectionClosed()
			return
		}
		let waitStatus = lock.wait(timeout: .now() + .milliseconds(2))
		// if lock is busy, don't want to queue another read
		guard waitStatus == .success else { return }
		defer { lock.signal() }
		// in any other case, we'll want to read again
		defer { readQueue.async { [weak self] in self?.readNext() } }
		// read our magic header
		let header = UnsafeMutablePointer<CChar>.allocate(capacity: 8)
		defer { header.deallocate() }
		header.initialize(repeating: 0, count: 8)
		do {
			let readCount = try socket.read(into: header, bufSize: 8, truncate: true)
			if readCount == 0 {
				// need to check status of socket
				if socket.remoteConnectionClosed, state != .unusable {
					self.state = .unusable
					self.socket?.close()
					delegate?.handleConnectionClosed()
				}
				return
			}
			guard readCount == 8 else {
				// this could only happen if we connected to an invalid server.
				// TODO: abort this worker
				logger.error("failed to read magic header: \(readCount)")
				return
			}
			let anticipatedSize = try verifyMagicHeader(bytes: header)
			let sizeToRead = readBufferSize > anticipatedSize ? anticipatedSize : readBufferSize
			// now read size bytes
			let sizeRead = try socket.read(into: readBuffer, bufSize: sizeToRead, truncate: true)
			guard sizeRead == sizeToRead else {
				logger.error("size read from compute (\(sizeRead)) does not match anticipated size (\(anticipatedSize))")
				return // just throw away what was read
			}
			// pass along a Data w/o copying the memory
			let rawPtr = UnsafeMutableRawPointer(readBuffer)
			let tmpData = Data(bytesNoCopy: rawPtr, count: sizeRead, deallocator: .none)
			logger.debug("read from compute: \(tmpData)")
			readQueue.sync {
				self.delegate?.handleCompute(data: tmpData)
			}
		} catch {
			logger.error("error reading from compute socket: \(error)")
			readQueue.async {
				self.delegate?.handleCompute(error: .failedToReadMessage)
			}
		}
	}
	
	private func verifyMagicHeader(bytes: UnsafeMutablePointer<CChar>) throws -> Int {
		let (header, dataLen) = bytes.withMemoryRebound(to: UInt32.self, capacity: 2) { return (UInt32(bigEndian: $0.pointee), UInt32(bigEndian: $0.advanced(by: 1).pointee))}
		// tried all kinds of withUnsafePointer & withMemoryRebound and could not figure it out.
		logger.debug("compute sent \(dataLen) worth of json")
		guard header == 0x21 else { throw ComputeError.invalidHeader }
		return Int(dataLen)
	}

	private func valueByteArray<T>(_ value:T) -> [UInt8] {
		var data = [UInt8](repeatElement(0, count: MemoryLayout<T>.size))
		data.withUnsafeMutableBufferPointer {
			UnsafeMutableRawPointer($0.baseAddress!).storeBytes(of: value, as: T.self)
		}
		return data
	}
}
