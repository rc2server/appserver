//
//  SessionConnection.swift
//  kappserver
//
//  Created by Mark Lilback on 9/11/19.
//

import Foundation
import KituraWebSocket
import Rc2Model
import Logging

final class SessionConnection: Hashable {
	let logger: Logger
	let socket: WebSocketConnection
	let user: User
	let settings: AppSettings
	private let lock = DispatchSemaphore(value: 1)
	var watchingVariaables = false

	var id: String { return socket.id }
	
	init(connection: WebSocketConnection, user: User, settings: AppSettings, logger: Logger)
	{
		self.socket = connection
		self.user = user
		self.settings = settings
		self.logger = logger
	}
	
	func close(reason: WebSocketCloseReasonCode = .normal, description: String? = nil) {
		lock.wait()
		defer { lock.signal() }
		socket.close(reason: reason, description: description)
	}

	func close(reason: WebSocketCloseReasonCode = .normal) {
		socket.close(reason: reason, description: nil)
	}

	func send(data: Data) throws {
		lock.wait()
		defer { lock.signal() }
	logger.info("wrote to ws \(String(data: data, encoding: .utf8)!)")
		socket.send(message: data)
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
	
	static func == (lhs: SessionConnection, rhs: SessionConnection) -> Bool {
		return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
	}

}
