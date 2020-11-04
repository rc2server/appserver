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

protocol SessionConnectionI: Hashable {
	var logger: Logger { get }
	var socket: WebSocketConnection? { get }
	var user: User { get }
	var settings: AppSettings { get }
	var watchingVariables: Bool { get }
}

final class SessionConnection: SessionConnectionI {
	let logger: Logger
	let socket: WebSocketConnection?
	var mySocket: WebSocketConnection { return socket! }
	let user: User
	let settings: AppSettings
	private let lock = DispatchSemaphore(value: 1)
	var watchingVariables = false

	var id: String { return mySocket.id }
	
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
		mySocket.close(reason: reason, description: description)
	}

	func close(reason: WebSocketCloseReasonCode = .normal) {
		mySocket.close(reason: reason, description: nil)
	}

	func send(data: Data) throws {
		lock.wait()
		defer { lock.signal() }
	logger.info("wrote to ws \(String(data: data, encoding: .utf8)!)")
		mySocket.send(message: data)
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
	
	static func == (lhs: SessionConnection, rhs: SessionConnection) -> Bool {
		return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
	}

}
