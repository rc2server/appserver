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
	var wsclient: WebSocketClient?
	
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
	}

	// MARK: - functions
	
	public func start() throws {
		assert(state == .uninitialized, "programmer error: invalid state")
		guard !config.computeViaK8s else {
			assert(k8sServer != nil, "programmer error: can't use k8s without a k8s server")
			// need to start dance of finding and/or launching the compute k8s pod
			state = .initialHostSearch
			updateStatus()
			return
		}
		logger.info("getting compute port number")
		let rc = CaptureRedirect()
		let initReq = URLRequest(url: URL(string: "ws://\(config.computeHost):7714/")!)
		state = .loading
		rc.perform(request: initReq, callback: handleRedirect(response:request:error:))
	}
	
	public func shutdown() throws {
		guard state == .connected, let wsclient = wsclient, wsclient.isConnected else {
			logger.info("asked to shutdown when not running")
			throw ComputeError.notConnected
		}
		wsclient.close()
	}
	
	public func send(data: Data) throws {
		guard data.count > 0 else { throw ComputeError.sendingEmptyMessage }
		guard state == .connected, let wsclient = wsclient, wsclient.isConnected else { throw ComputeError.notConnected }
		wsclient.sendMessage(data: data, opcode: .text)
	}

	// MARK: - private methods
	
	private func handleRedirect(response: HTTPURLResponse?, request: URLRequest?, error: Error?) {
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
		self.wsclient = WebSocketClient(url.absoluteString, eventLoopGroup: eventGroup)! // code shows no path to return nil
		self.state = .connecting
		// FIXME: this delay should be on compute
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
			self.logger.info("opening ws connection")
			do {
				try self.wsclient?.connect()
			} catch {
				self.logger.info("failed to connect websocket: \(error.localizedDescription)")
				self.delegate?.handleCompute(error: .failedToConnect)
			}
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

	private func updateStatus() {
		fatalError("not implemented")
	}
}

extension ComputeWorker: WebSocketClientDelegate {
	public func onText(text: String) {
		logger.info("rcvd t from compute")
		delegate?.handleCompute(data: text.data(using: .utf8)!)
	}
	
	public func onBinary(data: Data) {
		logger.info("rcvd b from compute")
		delegate?.handleCompute(data: data)
	}
	
	public func onPing(data: Data) {
		wsclient?.pong(data: data)
	}
	
	public func onPong(data: Data) {
		wsclient?.ping(data: data)
	}
	
	public func onClose(channel: Channel, data: Data) {
		delegate?.handleConnectionClosed()
	}
	
	public func onError(error: Error?, status: HTTPResponseStatus?) {
		logger.warning("computer socket error: \(error?.localizedDescription ?? "?") for status: \(status?.reasonPhrase ?? "-")")
		delegate?.handleCompute(error: .network)
	}
	
	
}
