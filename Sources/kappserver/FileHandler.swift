//
//  FileHandler.swift
//  kappserver
//
//  Created by Mark Lilback on 9/11/19.
//

import Foundation
import Rc2Model
import Logging
import Kitura

class FileHandler: BaseHandler {
	let logger = Logger(label: "rc2.FileHandler")
	let fileNameHeader =  "Rc2-Filename"
	
	override func addRoutes(router: Router) {
		let prefix = settings.config.urlPrefixToIgnore
		router.post("\(prefix)/file/:wspaceId", middleware: BodyParser())
		router.post("\(prefix)/file/:wspaceId") { [unowned self] request, response, next in
			self.createFile(request: request, response: response, next: next)
		}
		router.put("\(prefix)/file/:fileId", middleware: BodyParser())
		router.put("\(prefix)/file/:fileId") { [unowned self] request, response, next in
			self.changeContents(request: request, response: response, next: next)
		}
		router.get("\(prefix)/file/:fileId") { [unowned self] request, response, next in
			self.downloadData(request: request, response: response, next: next)
		}
	}
	
	func createFile(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
		guard let wspaceIdStr = request.parameters["wspaceId"],
			let wspaceId = Int(wspaceIdStr),
			let filename = request.headers[fileNameHeader],
			let wspace = try? settings.dao.getWorkspace(id: wspaceId),
			wspace.userId == request.user?.id ?? -1,
			let rawData = request.body?.asRaw
			else {
				logger.warning("failed to create file")
				try? handle(error: SessionError.invalidRequest, response: response)
				return
		}
		logger.info("creating file \(filename) in wspace \(wspaceId)")
		do {
			let file = try settings.dao.insertFile(name: filename, wspaceId: wspaceId, bytes: rawData)
			response.send(file)
			response.status(.created)
		} catch {
			logger.warning("error inserting file: \(error)")
			try? handle(error: .databaseUpdateFailed, response: response)
			return
		}
		next()
	}
	
	func changeContents(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
		do {
			guard let fileIdStr = request.parameters["fileId"],
				let fileId = Int(fileIdStr),
				let user = request.user,
				let data = request.body?.asRaw,
				let _ = try? settings.dao.getFile(id: fileId, userId: user.id)
				else {
					logger.info("failed to prep for file update")
					try handle(error: SessionError.fileNotFound, response: response)
					return
				}
			try settings.dao.setFile(data: data, fileId: fileId)
			response.status(.noContent)
		} catch {
			logger.warning("failed to update file contents: \(error)")
			try! handle(error: .databaseUpdateFailed, response: response)
			return
		}
		next()
	}
	
	func downloadData(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)  {
		guard let fileIdStr = request.parameters["fileId"],
			let fileId = Int(fileIdStr),
			let user = request.user,
			let file = try? settings.dao.getFile(id: fileId, userId: user.id),
			let data = try? settings.dao.getFileData(fileId: fileId)
		else {
			try? handle(error: .invalidRequest, response: response)
			return
		}
		let fname = file.name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "\(fileId)"
		response.headers["Content-Disposition"] = "attachment; filename = \(fname)"
		response.headers["Content-Type"] = "application/octet-stream"
		response.send(data: data)
		next()
	}
}

