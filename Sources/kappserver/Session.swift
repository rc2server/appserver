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
	let logger: Logger
	let workspace: Workspace
	let settings: AppSettings
	private let lock = DispatchSemaphore(value: 1)
	private var connections = Set<SessionConnection>()
	private(set) var lastClientDisconnect: Date?
	private(set) var sessionId: Int!
	private var worker: ComputeWorker?
	let coder: ComputeCoder
	private var isOpen = false
	private var watchingVariables = false

	init(workspace: Workspace, settings: AppSettings) {
		self.workspace = workspace
		self.settings = settings
		self.coder = ComputeCoder()
		logger = Logger(label: "rc2.session.\(workspace.id).\(workspace.userId)")
	}

	deinit {
		logger.info("session for wspace \(workspace.id) closed")
	}
	
	func start(k8sServer: K8sServer? = nil) throws {
		
	}
	
	func shutdown() throws {
		if let sessionId = sessionId {
			try settings.dao.closeSessionRecord(sessionId: sessionId)
		}
		do {
			try worker?.send(data: try coder.close())
		} catch {
			logger.warning("error sending close command: \(error)")
		}
		try worker?.shutdown()

	}
	
	func added(connection: SessionConnection) {
		
	}
	
	func removed(connection: SessionConnection) {
		
	}
	
	func handle(command: SessionCommand, from: SessionConnection) {
		
	}
}

extension Session: ComputeWorkerDelegate {
	func handleCompute(data: Data) {
		
	}
	
	func handleCompute(error: ComputeError) {
		
	}
	
	func handleCompute(statusUpdate: ComputeState) {
		
	}
	
	
}
