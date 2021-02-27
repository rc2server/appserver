//
//  ComputeWorker.swift
//  kappserver
//
//  Created by Mark Lilback on 9/14/19.
//

import Foundation
import Logging
import Starscream

// FIXME: This viersion using KituraWebSocketClient is having serious issues. Saving this version so can re-implement but come back if necessary

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
	static func create(wspaceId: Int, sessionId: Int, k8sServer:  K8sServer? = nil, config: AppConfiguration, logger: Logger, delegate: ComputeWorkerDelegate, queue: DispatchQueue?) -> ComputeWorker
	{
		return ComputeWorker(wspaceId: wspaceId, sessionId: sessionId, config: config, logger: logger, delegate: delegate, queue: queue)
	}
	
	let logger: Logger
	let config: AppConfiguration
	let wspaceId: Int
	let sessionId: Int
	let k8sServer: K8sServer?
	var wssocket: WebSocket?
	private var initialRequestInProgress = false

	private weak var delegate: ComputeWorkerDelegate?
	// FIXME: make this threadsafe
	private(set) var state: ComputeState = .uninitialized {
		didSet { delegate?.handleCompute(statusUpdate: state) }
	}
	private var podFailureCount = 0
	
	private init(wspaceId: Int, sessionId: Int, k8sServer:  K8sServer? = nil, config: AppConfiguration, logger: Logger, delegate: ComputeWorkerDelegate, queue: DispatchQueue?)
	{
		self.logger = logger
		self.config = config
		self.sessionId = sessionId
		self.wspaceId = wspaceId
		self.delegate = delegate
		self.k8sServer = k8sServer
	}

	// MARK: - functions
	
	public func start() throws {
		assert(state == .uninitialized, "programmer error: invalid state")
		guard config.computeViaK8s else {
			logger.info("getting compute port number")
			let rc = CaptureRedirect()
			let initReq = URLRequest(url: URL(string: "ws://\(config.computeHost):7714/")!)
			state = .loading
			rc.perform(request: initReq) { (response, _, error) in
				guard error == nil else {
					self.logger.error("failed to get ws port: \(error?.localizedDescription ?? "no new request")")
					self.delegate?.handleCompute(error: .failedToConnect)
					return
				}
				guard let rsp = response, rsp.statusCode == 302, var urlstr = rsp.allHeaderFields["Location"] as? String else {
					self.logger.error("failed to redirect location")
					self.delegate?.handleCompute(error: .failedToConnect)
					return
				}
				if !urlstr.starts(with: "ws") {
					urlstr = "ws://\(urlstr)"
				}
				guard let url = URL(string: urlstr) else {
					self.logger.error("failed to turn \(urlstr) into a url")
					self.delegate?.handleCompute(error: .failedToConnect)
					return
				}
				self.logger.info("connecting to compute on \(url.port ?? -1)")
				self.wssocket = WebSocket(request: URLRequest(url: url))
				self.wssocket?.delegate = self
				self.wssocket?.respondToPingWithPong = true
				self.wssocket?.callbackQueue = .global()
				self.state = .connecting
				// FIXME: this delay should be on compute
				DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
					self.logger.info("opening ws connection")
					self.wssocket?.connect()
				}
			}
			return
		}
		guard k8sServer != nil else { fatalError("programmer error: can't use k8s without a k8s server") }
		// need to start dance of finding and/or launching the compute k8s pod
		state = .initialHostSearch
		updateStatus()
	}
	
	public func shutdown() throws {
		guard let ws = wssocket, state == .connected else {
			logger.info("asked to shutdown when not running")
			throw ComputeError.notConnected
		}
		ws.disconnect()
	}
	
	public func send(data: Data) throws {
		guard data.count > 0 else { throw ComputeError.sendingEmptyMessage }
		guard let ws = wssocket, state == .connected else { throw ComputeError.notConnected }
		// FIXME: compute should accept binary so we don't have this unnecessary serialization
		let strJson = String(data: data, encoding: .utf8)!
		if config.logComputeOutgoing {
			logger.info("to compute: \(strJson)")
		}
		ws.write(string: strJson)
//		ws.write(data: data)
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

extension ComputeWorker: WebSocketDelegate {
	public func websocketDidConnect(socket: WebSocketClient) {
		state = .connected
	}
	
	public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
		delegate?.handleConnectionClosed()
	}
	
	public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
		delegate?.handleCompute(data: text.data(using: .utf8)!)
	}
	
	public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
		delegate?.handleCompute(data: data)
	}
	
	/*public func didReceive(event: WebSocketEvent, client: WebSocket) {
		switch event {
		
		case .connected(_):
			state = .connected
		case .disconnected(_, _):
			delegate?.handleConnectionClosed()
		case .text(let text):
			delegate?.handleCompute(data: text.data(using: .utf8)!)
		case .binary(let data):
			delegate?.handleCompute(data: data)
		case .pong(_):
			break
		case .ping(_):
			break
		case .error(let error):
			logger.warning("got error from compute: \(error?.localizedDescription ?? "unknown")")
			delegate?.handleCompute(error: .network)
		case .viabilityChanged(_):
			break
		case .reconnectSuggested(_):
			break
		case .cancelled:
			state = .unusable
			logger.warning("compute ws said cancelled")
		}
	} */
}
