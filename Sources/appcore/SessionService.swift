//
//  SessionService.swift
//  kappserver
//
//  Created by Mark Lilback on 9/11/19.
//

import Foundation
import KituraWebSocket
import Rc2Model
import Logging

//protocol SessionConnectionDelegate {
//	func connected(socket: SessionConnection)
//	func closed(socket: SessionConnection, reason: WebSocketCloseReasonCode)
//	func handle(command: SessionCommand, socket: SessionConnection)
//}

let minReapTime = 5.0

/// Manages all sessions as they are created

/// the global service that finds/creates the Session and passes appropriate messages to it
class SessionService: WebSocketService, Hashable {
	let logger: Logger
	let settings: AppSettings
	var connectionTimeout: Int?
	private(set) var user: User?
	private let lock = DispatchSemaphore(value: 1)
	private var connections: [String : SessionConnection] = [:]
	private var activeSessions: [Int : Session] = [:] // key is wspaceId
	private var connectionToSession: [String : Int] = [:] // key is connection.id, value is wspaceId
	private var reapingTimer: RepeatingTimer?
	private var k8sServer: K8sServer?
	
	/// initializes SessionService
	///
	/// - Parameter settings: The app settings to use
	/// - Parameter logger: The logger object that messages should be sent to
	/// - Parameter minimumReapTime: minimum value between this and settings.config.sessionReapDelay. If zero, no reaper will be used (such as with unit tests)
	init(settings: AppSettings, logger: Logger, minimumReapTime: TimeInterval)
	{
		self.settings = settings
		self.logger = logger
		if settings.config.computeViaK8s {
			do {
				self.k8sServer = try K8sServer(config: settings.config)
			} catch {
				logger.error("failed to create K8sServer: \(error)")
				fatalError("failed to create K8sServer")
			}
		}
		guard minReapTime > 0 else { return }
		let delay = min(minReapTime, TimeInterval(settings.config.sessionReapDelay), 5.0)
		reapingTimer = RepeatingTimer(timeInterval: delay)
		reapingTimer?.eventHandler = { [weak self] in
			guard let me = self else { return }
			let reapTime = Date.timeIntervalSinceReferenceDate - delay
			me.lock.wait()
			defer { me.lock.signal() }
			for (wspaceId, session) in me.activeSessions {
				if let lastTime = session.lastClientDisconnect,
					lastTime.timeIntervalSinceReferenceDate < reapTime
				{
					do {
						me.logger.info("reaping session \(session.sessionId ?? -1) for wspace \(wspaceId)")
						try session.shutdown()
					} catch {
						me.logger.info("error reaping session \(wspaceId): \(error)")
					}
					me.activeSessions.removeValue(forKey: wspaceId)
				}
			}
			if me.activeSessions.count == 0 {
				logger.info("suspending reaper")
				me.reapingTimer?.suspend() // resumed when a session is added
			}
		}
	}
	
	// MARK: - WebSocketService implementation
	
	func connected(connection: WebSocketConnection) {
		logger.debug("sessionSerivce connected")
		// make sure they have a valid auth token, extract thte user from it, and make sure they own the workspace

		guard let wsStr = connection.request.headers[HTTPHeaders.wspaceId]?.first,
				let wspaceId = Int(wsStr),
			let token = settings.loginToken(from: connection.request.headers[HTTPHeaders.authorization]?.first),
			let wspace = try? settings.dao.getWorkspace(id: wspaceId),
			let fuser = try? settings.dao.getUser(id: token.userId),
			wspace.userId == fuser.id
		else {
			logger.warning("websocket request without an auth token")
			// close ourselves
			DispatchQueue.global().async {
				connection.close()
			}
			return
		}
		user = fuser
		//get the session
		lock.wait()
		defer { lock.signal() }
		var session = activeSessions[wspaceId]
		if session == nil {
			if activeSessions.count == 0 {
				reapingTimer?.resume()
			}
			//create session, start it, add to activeSessions
			session = Session(workspace: wspace, settings: settings)
			do {
				try session!.start(k8sServer: self.k8sServer)
				activeSessions[wspaceId] = session
			} catch {
				logger.error("failed to start session \(wspaceId): \(error)")
				connection.close()
				return
			}
		}
		let ssocket = SessionConnection(connection: connection, user: fuser, settings: settings, logger: logger)
		connections[connection.id] = ssocket
		connectionToSession[connection.id] = wspaceId
		session?.added(connection: ssocket)
	}
	
	func disconnected(connection: WebSocketConnection, reason: WebSocketCloseReasonCode) {
		// remove that from our cache, and session's records
		guard let sconnection = connections[connection.id],
			let wspaceId = connectionToSession[connection.id],
			let session = activeSessions[wspaceId]
		else {
			// TODO: this migt happen if we fail to start a session. need to test to find out
			logger.error("unknown connection disconnected")
			// assertionFailure("unknown connection disconnected")
			return
		}
		lock.wait()
		defer { lock.signal() }
		session.removed(connection: sconnection)
		connectionToSession.removeValue(forKey: connection.id)
	}
	
	func received(message: Data, from: WebSocketConnection) {
		let debugStr = String(data: message, encoding: .utf8) ?? "huh?"
		print(debugStr)
		logger.warning("ws got message: \(debugStr)")
		guard message.count > 1 else { return } // json needs {} at minimum, 1 char meesage likely newline
		guard let sconnection = connections[from.id],
			let session = session(for: from) else {
			logger.warning("failed to get session for source of message")
			return
		}
		do {
			let path = "/tmp/rcvd." + UUID().uuidString
			logger.info("writing message to \(path)")
			try! message.write(to: URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil))
			let command = try settings.decode(SessionCommand.self, from: message)
			// tell session to handle the query
			session.handle(command: command, from: sconnection)
		} catch {
			logger.warning("error parsing message: \(error)")
		}
	}
	
	func received(message: String, from: WebSocketConnection) {
		logger.warning("recived unsupported string message. ignoring")
	}
	
	// MARK: - private methods
	
	private func session(for connection: WebSocketConnection) -> Session? {
		guard  let wspaceId = connectionToSession[connection.id],
			let session = activeSessions[wspaceId]
		else { return nil }
		return session
	}
	
	// MARK: - Hashable
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
	
	static func == (lhs: SessionService, rhs: SessionService) -> Bool {
		return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
	}
	
}
