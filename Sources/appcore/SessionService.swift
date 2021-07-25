//
//  SessionService.swift
//  kappserver
//
//  Created by Mark Lilback on 9/11/19.
//

import Foundation
import Kitura
import KituraNet
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
	private let wsIdPathRegex: NSRegularExpression
	
	/// initializes SessionService
	///
	/// - Parameter settings: The app settings to use
	/// - Parameter logger: The logger object that messages should be sent to
	/// - Parameter minimumReapTime: minimum value between this and settings.config.sessionReapDelay. If zero, no reaper will be used (such as with unit tests)
	init(settings: AppSettings, logger: Logger, minimumReapTime: TimeInterval)
	{
		self.settings = settings
		self.logger = logger
		self.wsIdPathRegex = try! NSRegularExpression(pattern: #"(?:/|\?)(\d+)$"#)
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
//					do {
						me.logger.info("reaping session \(session.sessionId ?? -1) for wspace \(wspaceId)")
//						try session.shutdown()
//					} catch {
//						me.logger.info("error reaping session \(wspaceId): \(error)")
//					}
					me.activeSessions.removeValue(forKey: wspaceId)
				}
			}
			if me.activeSessions.count == 0 {
				logger.info("suspending reaper")
				me.reapingTimer?.suspend() // resumed when a session is added
			}
		}
	}
	
	/// returns the workspaceId if found at the end of url
	private func getWorkspaceId(request: ServerRequest) -> Int? {
		if let q = request.urlURL.query, let ival = Int(q) {
			logger.debug("found wspaceId via query string")
			return ival
		}
		let path = request.urlURL.path
		let pathRange = NSRange(path.startIndex..<path.endIndex, in: path)
		let matches = wsIdPathRegex.matches(in: path, options: .anchored, range: pathRange)
		if 	let match = matches.first {
			logger.debug("found match")
			let mrng = match.range(at:0)
			if let subrng = Range(mrng, in: path),
				let wsId = Int(path[subrng]) 
			{
				logger.debug("found wsId in query string: \(wsId)")
				return wsId
			}
		}
		// didn't find in url. look for custom header
		if let wsStr = request.headers[HTTPHeaders.wspaceId]?.first, let wsId = Int(wsStr) {
			return wsId
		}
		return nil
	}

	private func checkToken(request: ServerRequest, cookies: [String: String]) -> (User, Workspace)? {
		// make sure they have a valid auth token, extract the user from it, and make sure they own the workspace
		guard let token = settings.loginToken(from: request.headers[HTTPHeaders.authorization]?.first, cookies: cookies) else {
			logger.info("checkToken: failed to find token")
			return nil
		}
		guard let wspaceId = getWorkspaceId(request: request) else {
			logger.info("checkToken: failed to get wspaceeId")
			return nil
		}
		guard let wspace = try? settings.dao.getWorkspace(id: wspaceId) else {
			logger.info("checkToken: failed to get wspaceId")
			return nil
		}
		guard let fuser = try? settings.dao.getUser(id: token.userId) else {
			logger.info("checkToken: failed to get user from token")
			return nil
		}
		guard wspace.userId == fuser.id else {
			logger.info("checkToken: user is not the owner of workspace")
			return nil
		}
		return (fuser, wspace)
	}

	private func createCookieDict(request: ServerRequest) -> [String: String] {
		var cookieDict = [String: String]()
		if let cArray = request.headers["Cookie"] {
			let all = cArray.flatMap { $0.split(separator: ";") }.map { $0.trimmingCharacters(in: .whitespaces) }
			all.forEach { str in 
				let parts = str.split(separator: "=")
				if parts.count == 2 {
					cookieDict[String(parts[0])] = String(parts[1])
				}
			}
		}
		return cookieDict
	}
	// MARK: - WebSocketService implementation
	
	func connected(connection: WebSocketConnection) {
		logger.info("sessionSerivce connected: \(connection.request.urlURL.query ?? "")")
		// create dict of cookie key/value pairs
		let cookieDict = createCookieDict(request: connection.request)
		// make sure they have a valid auth token, extract the user from it, and make sure they own the workspace
		guard let (fuser, wspace) = checkToken(request: connection.request, cookies: cookieDict) else {
			logger.warning("websocket request without an auth token")
			// close ourselves after this has returned
			// FIXME: this crashes
			DispatchQueue.main.async {
				connection.close()
			}
			return
		}
		user = fuser
		//get the session
		lock.wait()
		defer { lock.signal() }
		var session = activeSessions[wspace.id]
		if session == nil {
			if activeSessions.count == 0 {
				reapingTimer?.resume()
			}
			//create session, start it, add to activeSessions
			session = Session(workspace: wspace, settings: settings)
			do {
				try session!.start(k8sServer: self.k8sServer)
				activeSessions[wspace.id] = session
				logger.info("started Session")
			} catch {
				logger.error("failed to start session \(wspace.id): \(error)")
				connection.close()
				return
			}
		}
		let ssocket = SessionConnection(connection: connection, user: fuser, settings: settings, logger: logger)
		connections[connection.id] = ssocket
		connectionToSession[connection.id] = wspace.id
		session?.added(connection: ssocket)
	}
	
	func disconnected(connection: WebSocketConnection, reason: WebSocketCloseReasonCode) {
		logger.info("websocket disconnected: \(reason)")
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
		guard message.count > 1 else { return } // json needs {} at minimum, 1 char meesage likely newline
		if settings.config.logClientIncoming {
			let incoming = String(data: message, encoding: .utf8) ?? "huh?"
			logger.info("client >> appserver\n\(incoming)")
		}
		guard let sconnection = connections[from.id],
			let session = session(for: from) else {
			logger.warning("failed to get session for source of message")
			return
		}
		do {
//			let path = "/tmp/rcvd." + UUID().uuidString
//			logger.info("writing message to \(path)")
//			try! message.write(to: URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil))
			let command = try settings.decode(SessionCommand.self, from: message)
			// tell session to handle the query
			session.handle(command: command, from: sconnection)
		} catch {
			logger.warning("error parsing message: \(error)")
		}
	}
	
	func received(message: String, from: WebSocketConnection) {
		logger.warning("recived unsupported string message. ignoring")
		guard let data = message.data(using: .utf8) else {
			logger.warning("failed to convert string to data")
			return
		}
		received(message: data, from: from)
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
