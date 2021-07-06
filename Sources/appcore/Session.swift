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
import servermodel
import Kitura
import KituraWebSocket
import NIO

class Session {
	var logger: Logger
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
	private var closeHandled = false

	init(workspace: Workspace, settings: AppSettings) {
		self.workspace = workspace
		self.settings = settings
		self.coder = ComputeCoder()
		logger = Logger(label: "rc2.session.\(workspace.id).\(workspace.userId)")
	}

	deinit {
		logger.info("session for wspace \(workspace.id) closed")
	}
	
	// MARK: - basic control
	
	func start(k8sServer: K8sServer? = nil) throws {
		do {
			sessionId = try settings.dao.createSessionRecord(wspaceId: workspace.id)
			logger[metadataKey: "sessionId"] = "\(sessionId!)"
			logger.info("got sessionId: \(sessionId!)")
		} catch {
			logger.error("failed to create session record: \(error)")
			throw error
		}
		try createWorker(k8sServer: k8sServer)
	}
	
	/// allows testing subclass to override
	func createWorker(k8sServer: K8sServer? = nil) throws {
		worker = ComputeWorker.create(wspaceId: workspace.id, sessionId: sessionId, k8sServer: k8sServer, eventGroup: settings.nioGroup!, config: settings.config, logger: logger, delegate: self, queue: .global())
		try worker!.start()
		try settings.dao.addFileChangeObserver(wspaceId: workspace.id, callback: handleFileChanged(data:))
	}

	func shutdown() throws {
		if let sessionId = sessionId {
			try settings.dao.closeSessionRecord(sessionId: sessionId)
		}
		lock.wait()
		defer { lock.signal() }
		if !closeHandled {
			broadcastToAllClients(object: SessionResponse.closed(SessionResponse.CloseData(reason: .computeClosed, details: nil)))
		}
		do {
			try worker?.send(data: try coder.close())
		} catch {
			logger.warning("error sending close command: \(error)")
		}
		try worker?.shutdown()

	}
	
	// MARK: - client managemenet
	
	func added(connection: SessionConnection) {
		lock.wait()
		defer { lock.signal() }
		connections.insert(connection)
		lastClientDisconnect = nil
	}
	
	func removed(connection: SessionConnection) {
		lock.wait()
		defer { lock.signal() }
		connections.remove(connection)
		if connections.count == 0 {
			lastClientDisconnect = Date()
		}
		// see if can stop watching variables
		if watchingVariables && !connections.map({ $0.watchingVariables}).contains(true) {
			do {
				let msgData = try coder.toggleVariableWatch(enable: false, contextId: nil)
				if msgData.count < 1 { logger.info(".removed sending empty data") }
				try worker?.send(data: msgData)
			} catch {
				logger.warning("error disabling variable watch: \(error)")
			}
		}
	}
	
	/// handles a command from a client
	func handle(command: SessionCommand, from: SessionConnection) {
		logger.info("got command: \(command)")
		switch command {
		case .executeFile(let params):
			handleExecuteFile(params: params)
		case .execute(let params):
			handleExecute(params: params)
		case .fileOperation(let params):
			handleFileOperation(params: params)
		case .getVariable(let params):
			handleGetVariable(params: params, connnection: from)
		case .help(let topic):
			handleHelp(topic: topic, connection: from)
		case .info:
			sendSessionInfo(connection: from)
		case .save(let params):
			handleSave(params: params, connection: from)
		case .clearEnvironment(let envId):
			handleClearEnvironment(id: envId)
		case .watchVariables(let params):
			handleWatchVariables(params: params, connection: from)
		case .createEnvironment(let params):
			handleCreateEnvironment(transId: params.transactionId, parentId: params.parendId, variableName: params.variableName)
		case .initPreview(let data):
			handleInitPreview(updateData: data)
		case .updatePreview(let updateData):
			handleUpdatePreview(updateData: updateData)
		case .removePreview(let previewId):
			handleRemovePreview(previewId: previewId)
		
		}
	}

	// MARK: - client communications
	
	/// Send a message to all clients
	///
	/// - Parameter object: the message to send
	func broadcastToAllClients<T: Encodable>(object: T) {
		do {
			let wstatus = lock.wait(timeout: .now() + .milliseconds(50))
			if wstatus == .timedOut {
				// most likely already locked, so we'll do nothing
				logger.warning("skipping broadcast b/c lock busy")
				return
			}
			defer { lock.signal() }
			let data = try settings.encode(object)
			connections.forEach {
				do {
					try $0.send(data: data)
				} catch {
					logger.warning("error sending to single client (\(error))")
				}
			}
		} catch {
			logger.warning("error sending to all clients (\(error))")
		}
	}
	
	func broadcast<T: Encodable>(object: T, toClient clientId: String) {
		do {
			let data = try settings.encode(object)
			lock.wait()
			defer { lock.signal() }
			if let socket = connections.first(where: { $0.id == clientId } ) {
				try socket.send(data: data)
			}
		} catch {
			logger.warning("error sending to single client (\(error))")
		}
	}
	
	// MARK: - private methods
	
	/// send updated workspace info
	private func sendSessionInfo(connection: SessionConnection?) {
		do {
			let response = SessionResponse.InfoData(workspace: workspace, files: try settings.dao.getFiles(workspace: workspace))
			broadcastToAllClients(object: SessionResponse.info(response))
		} catch {
			logger.warning("error sending info: \(error)")
		}
	}

}

// MARK: - Hashable
extension Session: Hashable {
	static func == (lhs: Session, rhs: Session) -> Bool {
		return lhs.workspace.id == rhs.workspace.id
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(ObjectIdentifier(self))
	}
}

// MARK: - ComputeWorkerDelegate
extension Session: ComputeWorkerDelegate {
	func handleCompute(data: Data) {
		do {
			if settings.config.logComputeIncoming {
				logger.info("compute sent: \(String(data: data, encoding: .utf8)!)")
			}
			let response = try coder.parseResponse(data: data)
			switch response {
			case .open(let openData):
				handleOpenResponse(success: openData.success, errorMessage: openData.errorMessage)
			case .help(let helpData):
				handleHelpResponse(data: helpData)
			case .variableValue(let varData):
				handleVariableValueResponse(data: varData)
			case .variableUpdate(let varData):
				handleVariableListResponse(data: varData)
			case .error(let errData):
				handleErrorResponse(data: errData)
			case .results(let rdata):
				handleResultsResponse(data: rdata)
			case .showOutput(let odata):
				handleShowOutput(data: odata)
			case .execComplete(let edata):
				handleExecComplete(data: edata)
			case .envCreated(let data):
				handleEnvironmentCreated(data: data)
			case .previewInited(let previewData):
				handleInitPreviewResponse(data: previewData)
			case .previewUpdated(let data):
				handlePreviewUpdated(data: data)
			case .previewUpdateStarted(let data):
				handlePreviewStarted(data: data)
			}
		} catch let error as ComputeError {
			logger.warning("got compute error: \(error.localizedDescription)")
		} catch {
			logger.warning("failed to decode response from compute: \(type(of: error)): \(error)// \(String(data: data, encoding: .utf8)!)")
			let path = "/tmp/badParse." + UUID().uuidString
			logger.info("writing message to \(path)")
			try! data.write(to: URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil))

		}
	}
	
	func handleCompute(error: ComputeError) {
		logger.warning("error from compute: \(error)")
		// TODO: better handling of the error, like reconnecting
		let serr = DetailedError(error: SessionError.compute, details:  error.localizedDescription)
		let edata = SessionResponse.ErrorData(transactionId: nil, error: serr.error, details: serr.details)
		broadcastToAllClients(object: SessionResponse.error(edata))
	}
	
	func handleConnectionClosed() {
		guard !closeHandled else {
			logger.warning("duplicate call")
			return
		}
		let wresult = lock.wait(timeout: .now() + .milliseconds(1))
		guard wresult == .success else {
			// failed to acquire lock
			logger.warning("failed to acquire lock to set closeHandled=true")
			return
		}
		closeHandled = true
		lock.signal()
		let details = SessionResponse.closed(SessionResponse.CloseData(reason: .computeClosed))
		broadcastToAllClients(object: details)
	}
	
	func handleCompute(statusUpdate: ComputeState) {
		guard !closeHandled else {
			logger.warning("why are ew getting a statusUpdate after closed?")
			return
		} //theoretically server should never send an error after closed, but just in case
		// TODO: do we need to track the current status? ';
		var clientUpdate: SessionResponse.ComputeStatus?
		switch statusUpdate {
		case .uninitialized:
			fatalError("state should be impossible")
		case .initialHostSearch:
			clientUpdate = .initializing
		case .loading:
			clientUpdate = .loading
		case .connecting:
			clientUpdate = .initializing
		case .connected:
			// send open connection message
			do {
				logger.debug("connecting to compute with '\(settings.config.dbPassword)'")
				let message = try coder.openConnection(wspaceId: workspace.id, sessionId: sessionId!, dbhost: settings.config.computeDbHost, dbPort: settings.config.computeDbPort,
					dbuser: settings.config.dbUser, dbname: settings.config.dbName,
					dbpassword: settings.config.dbPassword)
				if message.count < 1 { logger.info(".connected sending empty data") }
				try worker!.send(data: message)
			} catch {
				logger.error("failed to send open connection message: \(error)")
				let errmsg = SessionResponse.error(SessionResponse.ErrorData(transactionId: nil, error: SessionError.failedToConnectToCompute))
				broadcastToAllClients(object: errmsg)
			}
		case .failedToConnect:
			clientUpdate = .failed
		case .unusable:
			logger.info("got unusable status update")
		}
		if let status = clientUpdate {
			// inform clients that status changed
			logger.debug("sending compute status \(status)")
			broadcastToAllClients(object: SessionResponse.computeStatus(status))
		}
	}
}

// MARK: - response handling
extension Session {
	/// converts help compute response to a SessionResponse
	func handleHelpResponse(data: ComputeResponse.Help) {
		var outPaths = [String: String]()
		data.paths.forEach { value in
			guard let rng = value.range(of: "/library/") else { return }
			//strip off everything before "/library"
			let idx = value.index(rng.upperBound, offsetBy: -1)
			var aPath = String(value[idx...])
			//replace "help" with "html"
			aPath = aPath.replacingOccurrences(of: "/help/", with: "/html/")
			aPath.append(".html") // add file extension
			// split components
			let components = value.split(separator: "/")
			let funName = components.last!
			let pkgName = components.count > 3 ? components[components.count - 3] : "Base"
			let title = String(funName + " (" + pkgName + ")")
			//add to outPaths with the display title as key, massaged path as value
			outPaths[title] = aPath
		}
		let helpData = SessionResponse.HelpData(topic: data.topic, items: outPaths)
		broadcastToAllClients(object: SessionResponse.help(helpData))
	}
	
	/// converts showOutput compute response to a SessionResponse
	func handleShowOutput(data: ComputeResponse.ShowOutput) {
		guard let transId = data.transId else {
			logger.error("received show output w/o a transaction id. ignoring")
			return
		}
		do {
			//refetch from database so we have updated information
			//if file is too large, only send meta info
			guard let file = try settings.dao.getFile(id: data.fileId, userId: workspace.userId) else {
				logger.warning("failed to find file \(data.fileId) to show output")
				handleErrorResponse(data: ComputeResponse.Error(error: 101, details: "unknown file requested", queryId: data.queryId, transId: transId))
				return
			}
			var fileData: Data? = nil
			if file.fileSize < (settings.config.maximumWebSocketFileSizeKB * 1024) {
				fileData = try settings.dao.getFileData(fileId: data.fileId)
			}
			let forClient = SessionResponse.ShowOutputData(transactionid: transId, file: file, fileData: fileData)
			broadcastToAllClients(object: SessionResponse.showOutput(forClient))
		} catch {
			logger.warning("error handling show file: \(error)")
		}

	}
	
	/// converts execComplete compute response to a SessionResponse
	func handleExecComplete(data: ComputeResponse.ExecComplete) {
		var images = [SessionImage]()
		do {
			images = try settings.dao.getImages(imageIds: data.images)
		} catch {
			logger.warning("Error fetching images from compute \(error)")
		}
		guard data.transId != nil else {
			assertionFailure("execComplete response sent w/o a transactionId")
			logger.warning("execComplete response sent w/o a transactionId. skipping")
			return
		}
		let cdata = SessionResponse.ExecCompleteData(transactionId: data.transId!, batchId: data.batchNumber ?? 0, expectShowOutput: data.expectShowOutput, images: images)
		broadcastToAllClients(object: SessionResponse.execComplete(cdata))
	}
	
	/// converts results compute response to a SessionResponse
	func handleResultsResponse(data: ComputeResponse.Results) {
		guard data.transId != nil else {
			logger.warning("results response sent w/o a transactionId")
			assertionFailure("results response sent w/o a transactionId")
			return
		}
		let sresults = SessionResponse.ResultsData(transactionId: data.transId!, output: data.string, isError: data.isError)
		broadcastToAllClients(object: SessionResponse.results(sresults))
	}
	
	/// converts variable value compute response to a SessionResponse
	func handleVariableValueResponse(data: ComputeResponse.VariableValue) {
		let value = SessionResponse.VariableValueData(value: data.value, environmentId: data.contextId)
		let responseObject = SessionResponse.variableValue(value)
		if let clientId = data.clientId {
			broadcast(object: responseObject, toClient: clientId)
		} else {
			broadcastToAllClients(object: responseObject)
		}
	}
	
	/// converts variableList compute response to a SessionResponse
	func handleVariableListResponse(data: ComputeResponse.VariableUpdate) {
		// we send to everyone, even those not watching
		logger.info("handling variable update with \(data.variables.count) variables")
		let varData = SessionResponse.ListVariablesData(values: data.variables, removed: data.removed, environmentId:  data.environmentId, delta: data.delta)
		logger.info("forwarding \(data.variables.count) variables")
		broadcastToAllClients(object: SessionResponse.variables(varData))
	}
	
	/// converts error compute response to a SessionResponse
	func handleErrorResponse(data: ComputeResponse.Error) {
		let serror = SessionError.compute
		let errorData = SessionResponse.ErrorData(transactionId: data.transId, error: serror)
		broadcastToAllClients(object: SessionResponse.error(errorData))
	}
	
	/// converts environmentCreated compute response to a SessionResponse
	func handleEnvironmentCreated(data: ComputeResponse.EnvCreated) {
		let value = SessionResponse.CreatedEnvironment(transactionId: data.transactionId, environmentId: data.contextId)
		broadcastToAllClients(object: value)
	}
	
	/// converts initPreview compute response to a SessionResponse
	func handleInitPreviewResponse(data: ComputeResponse.PreviewInited) {
		let obj = SessionResponse.PreviewInitedData(previewId: data.previewId, fileId: data.fileId, errorCode: data.errorCode, updateIdentifier: data.updateIdentifier)
		let value = SessionResponse.previewInitialized(obj)
		broadcastToAllClients(object: value)
	}

	/// coverts updatePreviewStarted compute resonse to a SessionResponse
	func handlePreviewStarted(data: ComputeResponse.PreviewUpdateStartedData) {
		let obj = SessionResponse.PreviewUpdateStartedData(previewId: data.previewId, updateIdentifier: data.updateIdentifier, activeChunks: data.activeChunks)
		let value = SessionResponse.previewUpdateStarted(obj)
		broadcastToAllClients(object: value)
	}
	
	/// converts updatePreview compute response to a SessionResponse
	func handlePreviewUpdated(data: ComputeResponse.PreviewUpdated) {
		let obj = SessionResponse.PreviewUpdateData(previewId: data.previewId, chunkId: data.chunkId, updateIdentifier: data.updateIdentifier, results: data.results, updateComplete: data.updateComplete)
		let value = SessionResponse.previewUpdated(obj)
		broadcastToAllClients(object: value)
	}
}

// MARK: - command handling
extension Session {
	func handleOpenResponse(success: Bool, errorMessage: String?) {
		isOpen = success
		if !success, let err = errorMessage {
			logger.error("Error in response to open compute connection: \(err)")
			let errorObj = SessionResponse.error(SessionResponse.ErrorData(transactionId: nil, error: SessionError.failedToConnectToCompute))
			broadcastToAllClients(object: errorObj)
			do {
				try shutdown()
			} catch {
				logger.error("error shutting down after failed to open compute engine: \(error)")
			}
			return
		}
		broadcastToAllClients(object: SessionResponse.computeStatus(.running))
	}

	private func handleExecute(params: SessionCommand.ExecuteParams) {
		if params.isUserInitiated {
			broadcastToAllClients(object: SessionResponse.echoExecute(SessionResponse.ExecuteData(transactionId: params.transactionId, source: params.source, environmentId: params.environmentId)))
		}
		do {
			let data = try coder.executeScript(transactionId: params.transactionId, script: params.source)
			lock.wait()
			defer { lock.signal() }
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.info("error handling execute \(error.localizedDescription)")
		}
	}

	private func handleExecuteFile(params: SessionCommand.ExecuteFileParams) {
		broadcastToAllClients(object: SessionResponse.echoExecuteFile(SessionResponse.ExecuteFileData(transactionId: params.transactionId, fileId: params.fileId, fileVersion: params.fileVersion)))
		do {
			let data = try coder.executeFile(transactionId: params.transactionId, fileId: params.fileId, fileVersion: params.fileVersion)
			lock.wait()
			defer { lock.signal() }
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.warning("error handling execute file: \(error)")
		}
	}

	private func handleFileOperation(params: SessionCommand.FileOperationParams) {
		var cmdError: SessionError?
		var fileId = params.fileId
		var dupfile: Rc2Model.File? = nil
		do {
			switch params.operation {
			case .remove:
				try settings.dao.delete(fileId: params.fileId)
			case .rename:
				guard let name = params.newName else { throw SessionError.invalidRequest }
				_ = try settings.dao.rename(fileId: params.fileId, version: params.fileVersion, newName: name)
			case .duplicate:
				guard let name = params.newName else { throw SessionError.invalidRequest }
				dupfile = try settings.dao.duplicate(fileId: fileId, withName: name)
				fileId = dupfile!.id
				break
			}
		} catch let serror as SessionError {
			logger.warning("file operation \(params.operation) on \(params.fileId) failed: \(serror)")
			cmdError = serror
		} catch {
			logger.warning("file operation \(params.operation) on \(params.fileId) failed: \(error)")
			cmdError = SessionError.databaseUpdateFailed
		}
		
		let data = SessionResponse.FileOperationData(transactionId: params.transactionId, operation: params.operation, success: cmdError == nil, fileId: fileId, file: dupfile, error: cmdError)
		broadcastToAllClients(object: SessionResponse.fileOperation(data))
		sendSessionInfo(connection: nil)
	}

	private func handleCreateEnvironment(transId: String, parentId: Int, variableName: String?) {
		do {
			let data = try coder.createEnvironment(transactionId: transId, parentId: parentId, varName: variableName)
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.warning("error sending create environment: \(error)")
		}
	}

	private func handleClearEnvironment(id: Int) {
		do {
			let data = try coder.clearEnvironment(id: id)
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.warning("error clearing environment: \(error)")
		}
	}

	private func handleHelp(topic: String, connection: SessionConnection) {
		do {
			let data = try coder.help(topic: topic)
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.warning("failure sending help message: \(error.localizedDescription)")
			return
		}
	}

	private func handleGetVariable(params: SessionCommand.VariableParams, connnection: SessionConnection) {
		do {
			let data = try coder.getVariable(name: params.name, contextId: params.environmentId, clientIdentifier: connnection.id) 
			if data.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: data)
		} catch {
			logger.warning("failure sending getting variable: \(error.localizedDescription)")
			return
		}
	}
	
	// toggle variable watch on the compute server if it needs to be based on this request
	private func handleWatchVariables(params: SessionCommand.WatchVariablesParams, connection: SessionConnection) {
		guard params.watch != connection.watchingVariables else { return } // nothing to change
		connection.watchingVariables = params.watch
		// should we still be watching?
		let shouldWatch = connections.first(where: { $0.watchingVariables }) != nil
		// either toggle if overall change in state, otherwise ask for updated list so socket can know all the current values
		do {
			var cmd = try coder.toggleVariableWatch(enable: shouldWatch, contextId: params.environmentId)
			if shouldWatch, shouldWatch == watchingVariables {
				// ask for updated values
				cmd = try coder.listVariables(deltaOnly: false, contextId: params.environmentId)
			}
			if cmd.count < 1 { logger.info("sending empty data") }
			try worker?.send(data: cmd)
			watchingVariables = shouldWatch
		} catch {
			logger.warning("error toggling variable watch: \(error)")
		}
	}
	
	func handleFileChanged(data: SessionResponse.FileChangedData) {
		logger.info("got file change \(data)")
		broadcastToAllClients(object: SessionResponse.fileChanged(data))
	}
	
	/// save file changes and broadcast appropriate response
	private func handleSave(params: SessionCommand.SaveParams, connection: SessionConnection) {
		var serror: SessionError?
		var updatedFile: Rc2Model.File?
		do {
			updatedFile = try settings.dao.setFile(data: params.content, fileId: params.fileId, fileVersion: params.fileVersion)
		} catch let dberr as Rc2DAO.DBError {
			serror = SessionError.databaseUpdateFailed
			if serror == .unknown {
				logger.warning("unknown error saving file: \(dberr)")
			}
		} catch {
			logger.warning("unknown error saving file: \(error)")
			serror = SessionError.unknown
		}
		let responseData = SessionResponse.SaveData(transactionId: params.transactionId, success: serror == nil, file: updatedFile, error: serror)
		broadcastToAllClients(object: SessionResponse.save(responseData))
	}
	
	private func handleInitPreview(updateData: SessionCommand.InitPreviewParams) {
		logger.info("handleInitPreview called: \(updateData.updateIdentifier)")
		guard let worker = worker else {
			logger.error("asked to init preview with no compute worker")
			return
		}
		do {
			let cmd = try coder.initPreview(fileId: updateData.fileId, updateIdentifier: updateData.updateIdentifier)
			if cmd.count < 1 { logger.info("sending empty data") }
			try worker.send(data: cmd)
		} catch {
			logger.warning("error initing preview: \(error)")
		}
	}

	private func handleUpdatePreview(updateData: SessionCommand.UpdatePreviewParams) {
		logger.info("handle update preview called: \(updateData.updateIdentifier)")
		guard let worker = worker else {
			logger.error("asked to handle update with no compute worker")
			return
		}
		do {
			let cmd = try coder.updatePreview(previewId: updateData.previewId, chunkNumber: updateData.chunkId, includePrevious: updateData.includePrevious, updateIdentifier: updateData.updateIdentifier)
			if cmd.count < 1 { logger.info("sending empty data") }
			try worker.send(data: cmd)
		} catch {
			logger.warning("error updating preview: \(error)")
		}
	}
	
	private func handleRemovePreview(previewId: Int) {
		guard let worker = worker else {
			logger.error("asked to handle update with no compute worker")
			return
		}
		do {
			let cmd = try coder.removePreview(previewId: previewId)
			if cmd.count < 1 { logger.info("sending empty data") }
			try worker.send(data: cmd)
		} catch {
			logger.warning("error removing preview: \(error)")
		}
	}

}
