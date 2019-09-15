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

// TODO: implement RepeatingTimer to clean up expired sessions

let minReapTime = 5.0

/// the global service that finds/creates the Session and passes appropriate messages to it
class SessionService: WebSocketService, Hashable {
	let logger: Logger
	let settings: AppSettings
	private(set) var user: User?
	private let lock = DispatchSemaphore(value: 1)
	private var connections: [String : SessionConnection] = [:]
	private var activeSessions: [Int : Session] = [:] // key is wspaceId
	private var connectionToSession: [String : Int] = [:] // key is connection.id, value is wspaceId
	private var reapingTimer: RepeatingTimer
	private var k8sServer: K8sServer?
	
	init(settings: AppSettings, logger: Logger)
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
		let delay = min(minReapTime, Double(settings.config.sessionReapDelay))
		reapingTimer = RepeatingTimer(timeInterval: delay)
		reapingTimer.eventHandler = { [weak self] in
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
				me.reapingTimer.suspend() // resumed when a session is added
			}
		}
	}
	
	// MARK: - WebSocketService implementation
	
	func connected(connection: WebSocketConnection) {
		// make sure they have a valid auth token, extract thte user from it, and make sure they own the workspace
		let url = connection.request.urlURL
		let idStr = url.lastPathComponent
		guard let wspaceId = Int(idStr),
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
				reapingTimer.resume()
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
		guard let sconnection = connections[from.id],
			let session = session(for: from) else {
			logger.warning("failed to get session for source of message")
			return
		}
		do {
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