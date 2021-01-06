//
//  ComputeWorker.swift
//  kappserver
//
//  Created by Mark Lilback on 9/14/19.
//

import Foundation
import Logging
import Socket
import NIO

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
	static func create(wspaceId: Int, sessionId: Int, k8sServer:  K8sServer? = nil, eventGroup: EventLoopGroup, config: AppConfiguration, logger: Logger, delegate: ComputeWorkerDelegate, queue: DispatchQueue?) -> ComputeWorker
	{
		return ComputeWorker(wspaceId: wspaceId, sessionId: sessionId, config: config, eventGroup: eventGroup, logger: logger, delegate: delegate, queue: queue)
	}
	
	let logger: Logger
	let config: AppConfiguration
	let wspaceId: Int
	let sessionId: Int
	let k8sServer: K8sServer?
	let eventGroup: EventLoopGroup
	private var channel: Channel?
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
	
	private init(wspaceId: Int, sessionId: Int, k8sServer:  K8sServer? = nil, config: AppConfiguration, eventGroup: EventLoopGroup, logger: Logger, delegate: ComputeWorkerDelegate, queue: DispatchQueue?)
	{
		self.logger = logger
		self.config = config
		self.sessionId = sessionId
		self.wspaceId = wspaceId
		self.delegate = delegate
		self.k8sServer = k8sServer
		self.eventGroup = eventGroup
		readBufferSize = config.computeReadBufferSize
		readBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: readBufferSize)
		readBuffer.initialize(repeating: 0, count: readBufferSize)
		readQueue = queue ?? DispatchQueue.global(qos: .default)
		if Self._bootstrap == nil {
			Self._bootstrap = createBootstrap(group: eventGroup)
		}
	}

	deinit {
		readBuffer.deallocate()
	}
	
	// MARK: - functions
	
	public func start() throws {
		assert(state == .uninitialized, "programmer error: invalid state")
		guard config.computeViaK8s else {
			try openConnection(ipAddr: config.computeHost, port: config.computePort)
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
		guard state == .connected, let channel = channel, channel.isWritable else { throw ComputeError.notConnected }
		var headBytes = [UInt8](repeating: 0, count: 8)
		headBytes.replaceSubrange(0...3, with: valueByteArray(UInt32(0x21).byteSwapped))
		headBytes.replaceSubrange(4...7, with: valueByteArray(UInt32(data.count).byteSwapped))
		let rawData = Data(headBytes) + data
		logger.info("sending to compute: \(String(data: rawData, encoding: .utf8) ?? "no data" )")
		channel.writeAndFlush(rawData)
	}

	// MARK: - private methods
	
	private static var _bootstrap: ClientBootstrap?
	private static var bootstrap: ClientBootstrap { return _bootstrap! }
	
	private func createBootstrap(group: EventLoopGroup) -> ClientBootstrap {
		return ClientBootstrap(group: group)
			.channelInitializer { (channel) -> EventLoopFuture<Void> in
				channel.pipeline.addHandlers( [ByteToMessageHandler(MessageDecoder()), ComputeInboundHandler(delegate: self.delegate!, logger: self.logger)] )
			}
	}
	
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

	private func openConnection(ipAddr: String, port: UInt16) throws {
		precondition(!Thread.current.isMainThread)
		self.state = .connecting
		
		Self.bootstrap.connect(host: ipAddr, port: Int(port))
			.whenComplete { result in
				switch result {
				case .failure(let error):
					self.logger.error("failed to connect to compute: \(error)")
					self.state = .failedToConnect
					self.delegate?.handleCompute(error: .failedToConnect)
				case .success(let channel):
					self.state = .connected
					self.channel = channel
					self.delegate?.handleCompute(statusUpdate: .connected)
				}
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

private struct MessageDecoder: ByteToMessageDecoder {
	typealias InboundOut = ByteBuffer
	
	private var bytesNeeded: UInt32 = 0
	
	mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
		if bytesNeeded == 0 {
			guard buffer.readableBytes >= 8 else { return .needMoreData }
			let magic: UInt32 = buffer.readInteger()!
			bytesNeeded = buffer.readInteger()!
			guard magic == 0x21, buffer.readableBytes >= bytesNeeded else { return .needMoreData }
		}
		guard buffer.readableBytes >= bytesNeeded else { return .needMoreData }
		defer { bytesNeeded = 0 }
		let tmpBuffer = buffer.readSlice(length: Int(bytesNeeded))!
		context.fireChannelRead(self.wrapInboundOut(tmpBuffer))
		return .continue
	}
}

//mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
//	// if bytesNeeded == 0, try to treat as an entire package
//	if bytesNeeded == 0 {
//		guard buffer.readableBytes >= 8 else { return .needMoreData }
//		let magic: UInt32 = buffer.readInteger()!
//		let len: UInt32 = buffer.readInteger()!
//		guard magic == 0x21, buffer.readableBytes >= len else { return .needMoreData }
//		var tmpBuffer = buffer.readSlice(length: Int(len))!
//		delegate.processMessage(buffer: &tmpBuffer)
//		return .continue
//	}
//	guard buffer.readableBytes >= bytesNeeded else { return .needMoreData }
//	var tmpBuffer = buffer.readSlice(length: bytesNeeded)!
//	bytesNeeded = 0
//	delegate.processMessage(buffer: &tmpBuffer)
//	//pass so worker
//	return .continue
//}
//}

// TODO: if the romote connection is closed, what happens? Need to make sure we call delegate.handleConnectionClosed()
private class ComputeInboundHandler: ChannelInboundHandler {
	typealias InboundIn = ByteBuffer
	typealias InboundOut = [UInt8]
	// this has to be a var to be weak.
	private weak var delegate: ComputeWorkerDelegate?
	private let logger: Logger
	private var toldClosed = false
	
	init(delegate: ComputeWorkerDelegate, logger: Logger) {
		self.delegate = delegate
		self.logger = logger
	}
	
	func errorCaught(context: ChannelHandlerContext, error: Error) {
		logger.error("got error in channel: \(error)")
		guard let err = error as? ChannelError else { return }
		// TODO: handle all other types of error
		switch err {
		case .ioOnClosedChannel, .inputClosed, .alreadyClosed, .eof:
			if !toldClosed {
				toldClosed = true
				delegate?.handleConnectionClosed()
			} else {
				delegate?.handleCompute(error: .notConnected)
			}
			default:
				delegate?.handleCompute(error: .unknown)
		}
	}
	
	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		let inbuf = self.unwrapInboundIn(data)
		guard let data = inbuf.getData(at: 0, length: inbuf.readableBytes) else {
			logger.error("failed to get Data from inbound buffer")
			return
		}
		delegate?.handleCompute(data: data)
	}
}
