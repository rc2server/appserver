//
//  Session.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation
import Dispatch
import Logging
import Rc2Model
import Kitura
import KituraWebSocket

class Session {
	let workspace: Workspace
	let settings: AppSettings
	private let lock = DispatchSemaphore(value: 1)
	private var connections = Set<SessionConnection>()
	private(set) var lastClientDisconnect: Date?
	private(set) var sessionId: Int!
	private var isOpen = false
	private var watchingVariables = false

	init(workspace: Workspace, settings: AppSettings) {
		self.workspace = workspace
		self.settings = settings
	}

	func start(k8sServer: K8sServer? = nil) throws {
		
	}
	
	func shutdown() throws {
		
	}
	
	func added(connection: SessionConnection) {
		
	}
	
	func removed(connection: SessionConnection) {
		
	}
	
	func handle(command: SessionCommand, from: SessionConnection) {
		
	}
}
