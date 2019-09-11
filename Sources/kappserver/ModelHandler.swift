//
//  ModelHandler.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation
import Kitura
import Rc2Model
import servermodel
import Logging
import ZIPFoundation

class ModelHandler: BaseHandler {
	let logger = Logger(label: "rc2.ModelHandler")
	private enum Errors: Error {
		case unzipError
	}

	override func addRoutes(router: Router) {
		let prefix = settings.config.urlPrefixToIgnore
		router.post("\(prefix)/proj/:projId/wspace", middleware: BodyParser())
		router.post("\(prefix)/proj/:projId/wspace") { [weak self] request, response, next in
			self?.createWorkspace(request: request, response: response, next: next)
		}
		router.delete("\(prefix)/proj/:projId/wspace/:wspaceId") { [weak self] request, response, next in
			self?.deleteWorkspace(request: request, response: response, next: next)
		}
	}

	/// handles a request to delete a workspace
	/// returns updated BulkInfo
	func deleteWorkspace(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
		do {
			guard let user = request.user,
				let projectIdStr = request.parameters["projId"],
				let projectId = Int(projectIdStr),
				let wspaceIdStr = request.parameters["wspaceId"],
				let wspaceId = Int(wspaceIdStr),
				let project = try settings.dao.getProject(id: projectId),
				let _ = try settings.dao.getWorkspace(id: wspaceId),
				project.userId == user.id
			else {
				try handle(error: SessionError.invalidRequest, response: response)
				return
			}
			// can't delete last workspace
			if try settings.dao.getWorkspaces(project: project).count < 2 {
				try handle(error: .permissionDenied, response: response)
				return
			}
			try settings.dao.delete(workspaceId: wspaceId)

			let bulkInfo = try settings.dao.getUserInfo(user: user)
			response.send(bulkInfo)
		} catch {
			print("delete failed: \(error)")
			response.status(.notFound)
		}
		next()
	}
	
	// return bulk info for logged in user
	func createWorkspace(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) {
		do {
			guard let user = request.user,
				let projectIdStr = request.parameters["projId"],
				let projectId = Int(projectIdStr),
				let wspaceName = request.headers["Rc2-WorkspaceName"],
				wspaceName.count > 1,
				let project = try settings.dao.getProject(id: projectId),
				project.userId == user.id
			else {
					try handle(error: SessionError.invalidRequest, response: response)
					return
			}
			let wspaces = try settings.dao.getWorkspaces(project: project)
			guard wspaces.filter({ $0.name == wspaceName }).count == 0 else {
				try handle(error: SessionError.duplicate, response: response)
				return
			}
			var zipUrl: URL? // will be set to the folder of uncompressed files for later deletion
			var fileUrls: [URL]? // urls of the files in the zipUrl
			if let zipFile = request.body?.asRaw {
				// write to file
				if let uploadUrl = try unpackFiles(zipData: zipFile) {
					zipUrl = uploadUrl
					// used to use options [.skipsHiddenFiles, .skipsSubdirectoryDescendants]. but the first isn't implemented in linux 4.0.2, and the second is the default behavior
					fileUrls = try FileManager.default.contentsOfDirectory(at: uploadUrl, includingPropertiesForKeys: nil)
					// filter out hidden files
					fileUrls = fileUrls!.filter { !$0.lastPathComponent.hasPrefix(".") }
				}
			}
			defer { if let zipUrl = zipUrl { try? FileManager.default.removeItem(at: zipUrl) } }
			let wspace = try settings.dao.createWorkspace(project: project, name: wspaceName, insertingFiles: fileUrls)
			let bulkInfo = try settings.dao.getUserInfo(user: user)
			let result = CreateWorkspaceResult(wspaceId: wspace.id, bulkInfo: bulkInfo)
			response.send(result)
			response.status(.created)
		} catch {
			logger.warning("error creating workspace with files: \(error)")
			response.status(.internalServerError)
		}
		next()
	}

	func unpackFiles(zipData: Data) throws -> URL? {
		do {
			let tmpDirStr = NSTemporaryDirectory()
			let topTmpDir = URL(fileURLWithPath: tmpDirStr, isDirectory: true)
			let fm = FileManager()
			// write incoming data to zip file that will be removed
			let zipTmp = topTmpDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
			try zipData.write(to: zipTmp)
			defer { try? fm.removeItem(at: zipTmp)}
			//create directory to expand zip into
			let tmpDir = topTmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)
			try fm.unzipItem(at: zipTmp, to: tmpDir)
			try? fm.removeItem(at: tmpDir)
			return tmpDir
		} catch {
			logger.warning("error upacking zip file: \(error)")
			throw Errors.unzipError
		}
	}
}

