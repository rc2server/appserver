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

//protocol SessionConnectionDelegate {
//	func connected(socket: SessionConnection)
//	func closed(socket: SessionConnection, reason: WebSocketCloseReasonCode)
//	func handle(command: SessionCommand, socket: SessionConnection)
//}

final class SessionConnection: Hashable {
	let logger: Logger
	let socket: WebSocketConnection
	let user: User
	let settings: AppSettings
//	private let delegate: SessionConnectionDelegate
	private let lock = DispatchSemaphore(value: 1)
	internal private(set) var watchingVariaables = false

	var id: String { return socket.id }
	
	init(connection: WebSocketConnection, user: User, settings: AppSettings, logger: Logger)
	{
		self.socket = connection
		self.user = user
		self.settings = settings
//		self.delegate = delegate
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

	func send(command: SessionCommand) throws {
		lock.wait()
		defer { lock.signal() }
		let data = try settings.encode(command)
		socket.send(message: data)
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
	
	static func == (lhs: SessionConnection, rhs: SessionConnection) -> Bool {
		return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
	}

}
