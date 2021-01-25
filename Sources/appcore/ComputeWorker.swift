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
import NIOHTTP1
import KituraWebSocketClient

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
	let wsclient: WebSocketClient
	
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
		let wsUrl = "ws://\(config.computeHost):9001/";
		self.wsclient = WebSocketClient(wsUrl, eventLoopGroup: eventGroup)! // code shows no path to return nil
	}

	// MARK: - functions
	
	public func start() throws {
		assert(state == .uninitialized, "programmer error: invalid state")
		guard config.computeViaK8s else {
			do {
				try wsclient.connect()
			} catch {
				throw ComputeError.failedToConnect
			}
			return
		}
		guard k8sServer != nil else { fatalError("programmer error: can't use k8s without a k8s server") }
		// need to start dance of finding and/or launching the compute k8s pod
		state = .initialHostSearch
		updateStatus()
	}
	
	public func shutdown() throws {
		guard state == .connected, wsclient.isConnected else {
			logger.info("asked to shutdown when not running")
			throw ComputeError.notConnected
		}
		wsclient.close()
	}
	
	public func send(data: Data) throws {
		guard data.count > 0 else { throw ComputeError.sendingEmptyMessage }
		guard state == .connected, wsclient.isConnected else { throw ComputeError.notConnected }
		wsclient.sendMessage(data: data, opcode: .text)
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

	private func updateStatus() {
		fatalError("not implemented")
	}
}

extension ComputeWorker: WebSocketClientDelegate {
	public func onText(text: String) {
		logger.warning("compute worker received unexpected text from server");
	}
	
	public func onBinary(data: Data) {
		delegate?.handleCompute(data: data)
	}
	
	public func onPing(data: Data) {
		wsclient.pong(data: data)
	}
	
	public func onPong(data: Data) {
		wsclient.ping(data: data)
	}
	
	public func onClose(channel: Channel, data: Data) {
		delegate?.handleConnectionClosed()
	}
	
	public func onError(error: Error?, status: HTTPResponseStatus?) {
		logger.warning("computer socket error: \(error?.localizedDescription ?? "?") for status: \(status?.reasonPhrase ?? "-")")
		delegate?.handleCompute(error: .network)
	}
	
	
}
