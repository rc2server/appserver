//
//  ComputeWorker.swift
//  kappserver
//
//  Created by Mark Lilback on 9/14/19.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import Socket
import NIO
import NIOHTTP1
import WebSocketKit

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
	var computeWs: WebSocket?
	var closePromise: EventLoopPromise<Void>
	
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
		self.closePromise = eventGroup.next().makePromise(of: Void.self)
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
		print("Initialized Compute redirect")
		
		logger.info("getting compute port number")
		let rc = CaptureRedirect(log: logger)
		let initReq = URLRequest(url: URL(string: "http://\(config.computeHost):7714/")!)
		state = .loading
		rc.perform(request: initReq, callback: handleRedirect(response:request:error:))
	}
	
	public func shutdown() throws {
		guard state == .connected, let wsclient = computeWs, !wsclient.isClosed else {
			logger.info("asked to shutdown when not running")
			throw ComputeError.notConnected
		}
		try wsclient.close().wait()
	}
	
	public func send(data: Data) throws {
		guard data.count > 0 else { throw ComputeError.sendingEmptyMessage }
		guard state == .connected, let wsclient = computeWs, !wsclient.isClosed else { throw ComputeError.notConnected }
		// FIXME: duplicate encoding
		let str = String(data: data, encoding: .utf8)!
		if config.logComputeOutgoing {
			logger.info("sending to compute: \(str)")
		}
		wsclient.send(str)
	}

	// MARK: - private methods
	
	private func handleRedirect(response: HTTPURLResponse?, request: URLRequest?, error: Error?) {
		logger.info("handleRedirect called")
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
		logger.info("using \(urlstr)")
		self.state = .connecting
		let log = logger
		// FIXME: this delay should be on compute
		DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1800)) {
			log.info("opening ws connection")
			let connectFuture = WebSocket.connect(to: urlstr, on: self.eventGroup) { ws in
				self.computeWs = ws
				ws.onText { [weak self] ws, str in
					guard let me = self, let del = me.delegate else { return }
					del.handleCompute(data: str.data(using: .utf8)!)
				}
				ws.onBinary { [weak self] ws, bb in
					guard let me = self, let del = me.delegate else { return }
					del.handleCompute(data: Data(buffer: bb))
				}
				ws.onClose.cascade(to: self.closePromise)
			}
			connectFuture.whenFailureBlocking(onto: .global()) { [weak self] error in
				log.error("failed to connect ws to compute: \(error.localizedDescription)")
				self?.delegate?.handleCompute(error: .failedToConnect)
			}
			connectFuture.whenSuccess {
				log.info("ws connected")
				self.state = .connected
			}
			do {
				try self.closePromise.futureResult.wait()
				log.info("connection closed")
			} catch {
				log.error("error from websocket: \(error)")
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
