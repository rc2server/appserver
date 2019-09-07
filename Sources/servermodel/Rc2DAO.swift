//
//  Rc2DAO.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation
import Dispatch
import pgswift
import Rc2Model
import Logging

internal let logger = Logger(label: "io.rc2.appserver.servermodel")

open class Rc2DAO {
	public enum DBError: Error {
		case queryFailed
		case connectionFailed
		case invalidFile
		case versionMismatch
		case noSuchRow
	}
	
	internal let pgdb: Connection
	// queue is used by internal methods all database calls ultimately use
	let queue: DispatchQueue
	// file monitor
	var fileMonitor: FileChangeMonitor?
	
	public init(connection: Connection) {
		queue = DispatchQueue(label: "database serial queue")
		pgdb = connection
	}
	
	public func createTokenDAO() -> LoginTokenDAO {
		return LoginTokenDAO(connection: pgdb)
	}
	
	//MARK: - access methods
	/// Returns bulk info about a user to return to a client on successful connection
	///
	/// - Parameter user: the user who's info should be returned
	/// - Returns: the requested user info
	/// - Throws: any errors from communicating with the database server
	public func getUserInfo(user: User) throws -> BulkUserInfo {
		let projects = try getProjects(ownedBy: user)
		var wspaceDict = [Int: [Workspace]]()
		var fileDict = [Int: [File]]()
		// load workspaces
		let params = [try QueryParameter(type: .int8, value: user.id, connection: pgdb)]
		let wspaceQuery = "select w.* from rcproject p join rcworkspace w on w.projectid = p.id  where p.userid = $1"
		let result = try pgdb.execute(query: wspaceQuery, parameters: params)
		guard result.wasSuccessful else {
			logger.warning("error fetching workspaces: \(result.errorMessage)")
			throw ModelError.dbError
		}
		projects.forEach { wspaceDict[$0.id] = [] }
		for row in 0..<result.rowCount {
			let wspace = try workspace(from: result, row: row)
			wspaceDict[wspace.projectId]!.append(wspace)
			fileDict[wspace.id] = []
		}
		let fileQuery = "select f.* from rcproject p join rcworkspace w on w.projectid = p.id join rcfile f on f.wspaceid = w.id  where p.userid = $1"
		// uses same parameters as workspace query
		let fresult = try pgdb.execute(query: fileQuery, parameters: params)
		guard result.wasSuccessful else {
			logger.warning("error fetching workspace files: \(result.errorMessage)")
			throw ModelError.dbError
		}
		for row in 0..<fresult.rowCount {
			let aFile = try file(from: result, row: row)
			fileDict[aFile.wspaceId]!.append(aFile)
		}
		return BulkUserInfo(user: user, projects: projects, workspaces: wspaceDict, files: fileDict)
	}
	
	/// get user with specified id
	///
	/// - Parameters:
	///   - id: the desired user's id
	///   - connection: optional database connection
	/// - Returns: user with specified id
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getUser(id: Int) throws -> User? {
		let results = try pgdb.execute(query: "select * from rcuser where id = $1", parameters: [QueryParameter(type: .int8, value: id, connection: pgdb)])
		return try user(from: results)
	}
	

	/// get user with specified login
	///
	/// - Parameters:
	///   - login: the desired user's login
	///   - connection: optional database connection
	/// - Returns: user with specified login
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getUser(login: String) throws -> User? {
		let rawResults: PGResult? = try pgdb.execute(query: "select * from user where login = $1", parameters: [QueryParameter(type: .varchar, value: login, connection: pgdb)])
		guard let results = rawResults
			else { throw DBError.queryFailed }
		return try user(from: results)
	}
	
	/// gets the user with the specified login and password. Returns nil if no user matches.
	///
	/// - Parameters:
	///   - login: user's login
	///   - password: user's password
	/// - Returns: user if the login/password are valid, nil if user not found
	/// - Throws: node errors 
	public func getUser(login: String, password: String) throws -> User? {
		var query = "select * from user where login = $1"
		var params: [QueryParameter?] = []
		params.append(try QueryParameter(type: .varchar, value: login, connection: pgdb))
		if password.count == 0 {
			query += " and passworddata IS NULL"
		} else {
			query += " and passwordata = crypt($2, passworddata)"
			params.append(try QueryParameter(type: .varchar, value: password, connection: pgdb))
		}
		let rawResults: PGResult? = try pgdb.execute(query: query, parameters: [QueryParameter(type: .varchar, value: login, connection: pgdb)])
		guard let results = rawResults, results.rowCount == 1 else {
			logger.info("failed to find user for login '\(login)'")
			return nil
		}
		return try user(from: results)
	}
	
	public func createSessionRecord(wspaceId: Int) throws -> Int {
		let query = "insert into sessionrecord (wspaceid) values ($1) returning id"
		let params = [try QueryParameter(type: .int8, value: wspaceId, connection: pgdb)]
		let result = try pgdb.execute(query: query, parameters: params)
		guard result.rowCount == 1, let sid: Int = try result.getValue(row: 0, column: 0) else {
			logger.info("failed to create session record for \(wspaceId)")
			throw DBError.queryFailed
		}
		return sid
	}
	
	public func closeSessionRecord(sessionId: Int) throws {
		let query = "update sessionrecord set enddate = now() where id = $1"
		let results = try pgdb.execute(query: query, parameters: [try QueryParameter(type: .int8, value: sessionId, connection: pgdb)])
		guard results.wasSuccessful else { throw DBError.queryFailed }
	}
	
	// MARK: - Projects
	/// get project with specific id
	///
	/// - Parameters:
	///   - id: id of the project
	/// - Returns: project with id of id
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getProject(id: Int) throws -> Project? {
		let rawResults: PGResult? = try pgdb.execute(query: "select * from rcproject where id = $1", parameters: [QueryParameter(type: .int8, value: id, connection: pgdb)])
		guard let results = rawResults
			else { throw DBError.queryFailed }
		return Project(id: try Rc2DAO.value(columnName: "id", results: results), version: try Rc2DAO.value(columnName: "version", results: results), userId: try Rc2DAO.value(columnName: "userId", results: results), name: try Rc2DAO.value(columnName: "name", results: results))
	}
	
	/// get projects owned by specified user
	///
	/// - Parameters:
	///   - ownedBy: user whose projects should be fetched
	/// - Returns: array of projects
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getProjects(ownedBy: User) throws -> [Project] {
		let query = "select * from rcproject where userId = $1"
		let params = [try QueryParameter(type: .int8, value: ownedBy.id, connection: pgdb)]
		let results = try pgdb.execute(query: query, parameters: params)
		guard results.wasSuccessful else {
			logger.warning("query failed: error: \(results.errorMessage)")
			throw DBError.queryFailed
		}
		var projects: [Project] = []
		for row in 0..<results.rowCount {
			let project = Project(id: try Rc2DAO.value(columnName: "id", results: results, row: row),
								  version: try Rc2DAO.value(columnName: "version", results: results, row: row),
								  userId: try Rc2DAO.value(columnName: "userid", results: results, row: row),
								  name: try Rc2DAO.value(columnName: "name", results: results, row: row))
			projects.append(project)
		}
		return projects
	}
	
	// MARK: - Workspaces
	/// get workspace with specific id
	///
	/// - Parameters:
	///   - id: id of the workspace
	/// - Returns: workspace with id of id
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getWorkspace(id: Int) throws -> Workspace? {
		let rawResults: PGResult? = try pgdb.execute(query: "select * from rcworkspace where id = $1", parameters: [QueryParameter(type: .int8, value: id, connection: pgdb)])
		guard let results = rawResults
			else { throw DBError.queryFailed }
		return try workspace(from: results)
	}
	
	/// gets workspaces belonging to a project
	///
	/// - Parameters:
	///   - project: a project
	/// - Returns: array of workspaces
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getWorkspaces(project: Project) throws -> [Workspace] {
		let query = "select * from rcproject where projectid = $1"
		let params = [try QueryParameter(type: .int8, value: project.id, connection: pgdb)]
		let results = try pgdb.execute(query: query, parameters: params)
		guard results.wasSuccessful else {
			logger.warning("query failed: error: \(results.errorMessage)")
			throw DBError.queryFailed
		}
		var wspaces: [Workspace] = []
		for row in 0..<results.rowCount {
			let wspace = try workspace(from: results, row: row)
			wspaces.append(wspace)
		}
		return wspaces
	}
	
	/// Çreates a new workspace. performs in a transacion so rollbacks if any file inserts fail
	///
	/// - Parameters:
	///   - project: project containing the workspace
	///   - name: the name of the workspace
	///   - insertingFiles: URLs of files to insert in the newly created workspace
	/// - Returns: the Workspace that was created
	/// - Throws: any database errors
	@discardableResult
	public func createWorkspace(project: Project, name: String, insertingFiles files: [URL]? = nil) throws -> Workspace
	{
		let wspace = try pgdb.withTransaction { (_) throws -> Workspace? in
			let results = try pgdb.execute(query: "insert into rcworkspace (name, userid, projectid) values ($1, \(project.userId), \(project.id)) returning *",
				parameters: [try QueryParameter(type: .varchar, value: name, connection: pgdb)])
			guard results.wasSuccessful, results.rowsAffected == 1, results.rowCount == 1  else {
				logger.warning("failed to insert workspace: \(results.errorMessage)")
				throw DBError.queryFailed
			}
			let wspace = try workspace(from: results, row: 0)
			
			// insert files
			if let urls = files {
				for aUrl in urls {
					guard aUrl.isFileURL else { throw DBError.invalidFile }
					let fileData = try Data(contentsOf: aUrl)
					let params = [
						try QueryParameter(type: .int8, value: wspace.id, connection: pgdb),
						try QueryParameter(type: .varchar, value: aUrl.lastPathComponent, connection: pgdb),
						try QueryParameter(type: .int8, value: fileData.count, connection: pgdb),
					]
					let fileResults = try pgdb.execute(query: "insert into rcfile(wspaceid, name, filesize) values($1, $2, $3) returning id", parameters: params)
					guard fileResults.wasSuccessful, fileResults.rowsAffected == 1, fileResults.rowCount == 1, let fileId: Int = try fileResults.getValue(row: 0, column: 0)
					else {
						logger.warning("error uploading file (\(aUrl.lastPathComponent)")
						throw DBError.invalidFile
					}
					let fileParams = [
						try QueryParameter(type: .int8, value: fileId, connection: pgdb),
						try QueryParameter(type: .bytea, value: fileData, connection: pgdb),
					]
					let dataResults = try pgdb.execute(query: "insert into rcfiledata(id, bindata) values ($1, $2)", parameters: fileParams)
					guard dataResults.wasSuccessful, dataResults.rowsAffected == 1 else {
						logger.warning("failed to insert file data: \(dataResults.errorMessage)")
						throw DBError.queryFailed
					}
				}
			}
			return wspace
		}
		assert(wspace != nil, "impossible situation")
		return wspace!
	}
	
	/// Delete the workspace with the passed in id. This will also delete all files in the workspace.
	///
	/// - Parameter workspaceId: the id of the workspace to delete
	/// - Throws: any database errors
	public func delete(workspaceId: Int) throws {
		let results = try pgdb.execute(query: "delete from rcworkspace where id = $1", parameters: [try QueryParameter(type: .int8, value: workspaceId, connection: pgdb)])
		guard results.wasSuccessful, results.rowsAffected == 1 else {
			logger.warning("failed to delete workspace: \(results.errorMessage)")
			throw DBError.queryFailed
		}
	}
	
	// MARK: - Files
	/// insert an array of files from the local file system
	///
	/// - Parameters:
	///   - urls: array of file URLs to insert
	///   - wspaceId: the id of the workspace to add them to
	/// - Throws: any database errors
//	private func insertFiles(urls: [URL], wspaceId: Int, conn: Connection) throws {
//		for aFile in urls {
//			guard aFile.isFileURL else { throw DBError.invalidFile }
//			let fileData = try Data(contentsOf: aFile)
//			let params = [try QueryParameter(type: .int8, value: wspaceId, connection: pgdb],
//			let rawResult = try conn.execute("insert into rcfile (wspaceid, name, filesize) values (\(wspaceId), $1, \(fileData.count)) returning *", [Node(stringLiteral: aFile.lastPathComponent)])
//			guard let array = rawResult.array, let fileId: Int = try array[0].get("id") else { throw DBError.queryFailed }
//			try conn.execute("insert into rcfiledata (id, bindata) values ($1, $2)",
//							 [Bind(int: fileId, configuration: conn.configuration),
//							  Bind(bytes: fileData.makeBytes(), configuration: conn.configuration)])
//		}
//	}
	
	/// get file with specific id
	///
	/// - Parameters:
	///   - id: id of the file
	///   - userId: the id of the user that owns the file
	/// - Returns: file with id
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getFile(id: Int, userId: Int) throws -> File? {
		let params = [try QueryParameter(type: .int8, value: userId, connection: pgdb),
					  try QueryParameter(type: .int8, value: id, connection: pgdb)
		]
		let results = try pgdb.execute(query: "select f.* from rcfile f join rcworkspace w on f.wspaceId = w.id where w.userId = $1 and f.id = $2", parameters: params)
		guard results.wasSuccessful else {
			logger.warning("query for files failed: \(results.errorMessage)")
			throw DBError.queryFailed
		}
		guard results.rowCount > 0 else { throw ModelError.notFound }
		// primary key makes it impossible to have more than one
		precondition(results.rowCount == 1, "more than 1 file with same id should be impossible")
		return try file(from: results, row: 0)
	}
	
	/// gets files belonging to a workspace
	///
	/// - Parameters:
	///   - workspace: a workspace
	/// - Returns: array of files
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getFiles(workspace: Workspace) throws -> [File] {
		let params = [try QueryParameter(type: .int8, value: workspace.id, connection: pgdb)]
		let results = try pgdb.execute(query: "select f.* from rcfile where f.wspaceId = $1", parameters: params)
		guard results.wasSuccessful else {
			logger.warning("query for files failed: \(results.errorMessage)")
			throw DBError.queryFailed
		}
		var files = [File]()
		for row in 0..<results.rowCount {
			files.append(try file(from: results, row: row))
		}
		return files
	}
	
	/// gets the contents of a file
	///
	/// - Parameters:
	///   - fileId: id of file
	/// - Returns: contents of file
	/// - Throws: .duplicate if more than one row in database matched, Node errors if problem parsing results
	public func getFileData(fileId: Int) throws -> Data {
		let rawResults: PGResult? = try pgdb.execute(query: "select bindata from rcfiledata where id = $1", parameters: [QueryParameter(type: .int8, value: fileId, connection: pgdb)])
		guard let results = rawResults else { throw DBError.queryFailed }
		guard results.rowCount == 1 else {
			logger.warning("failed to fetch file data: \(results.errorMessage)")
			throw DBError.queryFailed
		}
		guard let data =  try results.getDataValue(row: 0, column: 0) else {
			logger.warning("failed to read data: \(results.errorMessage)")
			throw ModelError.notFound
		}
		return data
	}
	
	/// creates a new file
	///
	/// - Parameters:
	///   - name: name for the new file
	///   - wspaceId: id of the workspace the file belongs to
	///   - bytes: the contents of the file
	/// - Returns: the newly created file object
	/// - Throws: any database errors
	public func insertFile(name: String, wspaceId: Int, bytes: Data) throws -> File {
		let insertedFile = try pgdb.withTransaction { (pgdb) -> File in
			let fparams = [try QueryParameter(type: .int8, value: wspaceId, connection: pgdb),
				try QueryParameter(type: .varchar, value: name, connection: pgdb),
				try QueryParameter(type: .int8, value: bytes.count, connection: pgdb)]
			let result = try pgdb.execute(query: "insert into rcfile (wspaceid, name, filesize) values ($1, $2, $3) returning *", parameters: fparams)
			guard result.wasSuccessful, result.rowsAffected == 1, result.rowCount == 1 else {
				logger.warning("insert file failed: \(result.errorMessage)")
				throw DBError.queryFailed
			}
			let theFile = try file(from: result)
			let dparams = [try QueryParameter(type: .int8, value: theFile.id, connection: pgdb),
						   try QueryParameter(type: .bytea, value: bytes, connection: pgdb)]
			let dresult = try pgdb.execute(query: "insert into rcfiledata (id, bindata) values ($1, $2)", parameters: dparams)
			guard dresult.wasSuccessful, dresult.rowsAffected == 1 else {
				logger.warning("insert file data failed: \(dresult.errorMessage)")
				throw ModelError.dbError
			}
			return theFile
		}
		guard let file = insertedFile else { throw ModelError.dbError }
		return file
	}
	
	/// Updates the contents of a file
	///
	/// - Parameters:
	///   - data: the updated content of the file
	///   - fileId: the id of the file
	///   - fileVersion: the version of the file being overwritten. If not nil, will throw error if file has been updated since that version
	/// - Throws: any database error
	@discardableResult
	public func setFile(data: Data, fileId: Int, fileVersion: Int? = nil) throws -> File {
		// match version if supplied
		if let version = fileVersion {
			let vparams = [try QueryParameter(type: .int8, value: version, connection: pgdb),
						   try QueryParameter(type: .int8, value: fileId, connection: pgdb) ]
			let vresults = try pgdb.execute(query: "select id from rcfile where version = $1 and id = $2", parameters: vparams)
			guard vresults.wasSuccessful, vresults.rowCount == 1 else {
				throw DBError.versionMismatch
			}
		}
		let updatedFile = try pgdb.withTransaction { (pgdb) -> File in
			let fparams = [try QueryParameter(type: .int8, value: data.count, connection: pgdb)]
			let fresult = try pgdb.execute(query: "update rcfile set = version = version + 1, lastmodified = now(), filesize = $1 where id = $1 returning *", parameters: fparams)
			guard fresult.wasSuccessful, fresult.rowsAffected == 1, fresult.rowCount == 1 else {
				logger.warning("failed to update file: \(fresult.errorMessage)")
				throw ModelError.dbError
			}
			let updatedFile = try file(from: fresult)
			let dparams = [try QueryParameter(type: .bytea, value: data, connection: pgdb)]
			let dresult = try pgdb.execute(query: "update rcfiledata set bindata = $1 where id = $2", parameters: dparams)
			guard dresult.wasSuccessful, dresult.rowsAffected == 1 else {
				logger.warning("failed to update file data: \(dresult.errorMessage)")
				throw ModelError.dbError
			}
			return updatedFile
		}
		return updatedFile!
	}
	
	/// Deletes a file
	///
	/// - Parameter fileId: the id of the file to delete
	/// - Throws: any database error
	public func delete(fileId: Int) throws {
		let results = try pgdb.execute(query: "delete from rcfile where id = $1", parameters: [try QueryParameter(type: .int8, value: fileId, connection: pgdb)])
		guard results.wasSuccessful else { throw ModelError.dbError }
	}
	
	/// Renames a file
	///
	/// - Parameter fileId: the id of the file to rename
	/// - Parameter version: the last known version of the file to delete
	/// - Parameter newName: the new name for the file
	/// - Returns: the updated file object
	/// - Throws: if the file has been updated, or any other database error
	public func rename(fileId: Int, version: Int, newName: String) throws -> File {
		let params = [try QueryParameter(type: .varchar, value: newName, connection: pgdb),
					  try QueryParameter(type: .int8, value: fileId, connection: pgdb),
					  try QueryParameter(type: .int8, value: version, connection: pgdb)]
		let result = try pgdb.execute(query: "update rcfile set name = $1 where id = $2 and version = $3 returning *", parameters: params)
		guard result.wasSuccessful, result.rowsAffected == 1, result.rowCount == 1 else {
			logger.warning("failed to uupdate for file rename: \(result.errorMessage)")
			throw ModelError.dbError
		}
		return try file(from: result)
	}
	
	/// duplicates a file
	///
	/// - Parameters:
	///   - fileId: the id of the source file
	///   - name: the name to give the duplicate
	/// - Returns: the newly created File object
	/// - Throws: any database errors
	public func duplicate(fileId: Int, withName name: String) throws -> File {
		let duplicateQuery = """
		with curfile as ( select * from rcfile where id = $1 )
		insert into rcfile (wspaceid, name, datecreated, filesize)
		values ((select wspaceid from curfile), $2, (select datecreated from curfile),
		(select filesize from curfile)) returning *;
		"""
		let dupFile = try pgdb.withTransaction { (pgdb) -> File  in
			let params = [try QueryParameter(type: .int8, value: fileId, connection: pgdb),
						  try QueryParameter(type: .varchar, value: name, connection: pgdb)]
			let result = try pgdb.execute(query: duplicateQuery, parameters: params)
			guard result.wasSuccessful, result.rowCount == 1 else {
				logger.warning("dpulicate file failed: \(result.errorMessage)")
				throw ModelError.dbError
			}
			let theFile = try file(from: result)
			let dparams = [try QueryParameter(type: .int8, value: fileId, connection: pgdb),
						 try QueryParameter(type: .int8, value: fileId, connection: pgdb)]
			let dresult = try pgdb.execute(query: "insert into rcfiledata (id, bindata) values ($1, (select bindata from rcfiledata where id = $2))", parameters: dparams)
			guard dresult.wasSuccessful, dresult.rowsAffected == 1 else {
				logger.warning("failed to insert data for duplicated file: \(dresult.errorMessage)")
				throw ModelError.dbError
			}
			return theFile
		}
		return dupFile!
	}

	// MARK: - Images
	/// Returns array of session images based on array of ids
	///
	/// - Parameter imageIds: Array of image ids
	/// - Returns: array of images
	/// - Throws: Node errors if problem fetching from database
	public func getImages(imageIds: [Int]?) throws -> [SessionImage] {
		guard let imageIds = imageIds, imageIds.count > 0 else { return [] }
		let idstring = imageIds.compactMap { String($0) }.joined(separator: ",")
		let query = "select * from sessionimage where id in (\(idstring)) order by id"
		let results = try pgdb.execute(query: query, parameters: [])
		guard results.wasSuccessful else { throw DBError.queryFailed }
		var images = [SessionImage]()
		for row in 0..<results.rowCount {
			images.append(SessionImage(id: try Rc2DAO.value(columnName: "id", results: results, row: row),
									   sessionId: try Rc2DAO.value(columnName: "sessionId", results: results, row: row),
									   batchId: try Rc2DAO.value(columnName: "batchid", results: results, row: row),
									   name: try Rc2DAO.value(columnName: "name", results: results, row: row),
									   title: try Rc2DAO.nullableValue(columnName: "title", results: results, row: row),
									   dateCreated: try Rc2DAO.value(columnName: "datecreated", results: results, row: row),
									   imageData: try Rc2DAO.value(columnName: "imgdata", results: results, row: row)))
		}
		return images
	}
	
	// MARK: - file observation
	
	public func addFileChangeObserver(wspaceId: Int, callback: @escaping (SessionResponse.FileChangedData) -> Void) throws {
		if nil == fileMonitor {
			fileMonitor = try FileChangeMonitor(connection: pgdb)
		}
		fileMonitor?.add(wspaceId: wspaceId, observer: callback)
	}

	// MARK: inline helpers
	@inline(__always)

/// helper function to clarify code
	private func user(from results: PGResult) throws -> User? {
		return User(id: try Rc2DAO.value(columnName: "id", results: results),
					version: try Rc2DAO.value(columnName: "version", results: results),
					login: try Rc2DAO.value(columnName: "login", results: results),
					email: try Rc2DAO.value(columnName: "email", results: results),
					passwordHash: try Rc2DAO.value(columnName: "passwordData", results: results),
					firstName: try Rc2DAO.value(columnName: "firstname", results: results),
					lastName: try Rc2DAO.value(columnName: "lastname", results: results),
					isAdmin: try Rc2DAO.value(columnName: "admin", results: results),
					isEnabled: try Rc2DAO.value(columnName: "enabled", results: results))
	}

	@inline(__always)
	private func workspace(from results: PGResult, row: Int = 0) throws -> Workspace {
		return Workspace(id: try Rc2DAO.value(columnName: "id", results: results, row: row),
						 version: try Rc2DAO.value(columnName: "version", results: results, row: row),
						 name: try Rc2DAO.value(columnName: "name", results: results, row: row),
						 userId: try Rc2DAO.value(columnName: "userid", results: results, row: row),
						 projectId: try Rc2DAO.value(columnName: "projectid", results: results, row: row),
						 uniqueId: try Rc2DAO.value(columnName: "uniqueid", results: results, row: row),
						 lastAccess: try Rc2DAO.value(columnName: "lastaccess", results: results, row: row),
						 dateCreated: try Rc2DAO.value(columnName: "datecreated", results: results, row: row))
	}
	
	@inline(__always)
	private func file(from results: PGResult, row: Int = 0) throws -> File {
		return File(id: try Rc2DAO.value(columnName: "id", results: results, row: row),
					wspaceId: try Rc2DAO.value(columnName: "wspaceId", results: results, row: row),
					name: try Rc2DAO.value(columnName: "name", results: results, row: row),
					version: try Rc2DAO.value(columnName: "version", results: results, row: row),
					dateCreated: try Rc2DAO.value(columnName: "datecreated", results: results, row: row),
					lastModified: try Rc2DAO.value(columnName: "lastmodified", results: results, row: row),
					fileSize: try Rc2DAO.value(columnName: "filesize", results: results, row: row))
	}

	@inline(__always)
	/// helper function to avoid checking for nil.
	internal static func value<T>(columnName: String, results: PGResult, row: Int = 0) throws -> T {
		guard let value: T = try results.getValue(row: row, columnName: columnName)
			else { throw ModelError.notFound }
		return value
	}

	@inline(__always)
	/// helper function to fetch nullable value
	internal static func nullableValue<T>(columnName: String, results: PGResult, row: Int = 0) throws -> T? {
		let value: T? = try results.getValue(row: row, columnName: columnName)
		return value
	}


	// MARK: - private methods
//	private func getSingleRow(_ connection: Connection? = nil, tableName: String, keyName: String, keyValue: Node) throws -> Node?
//	{
//		guard let pgdb = self.pgdb else { fatalError("Rc2DAO accessed without connection") }
//		var finalResults: Node? = nil
//		try queue.sync { () throws -> Void in
//			let conn = connection == nil ? try pgdb.makeConnection() : connection!
//			let result = try conn.execute("select * from \(tableName) where \(keyName) = $1", [keyValue])
//			guard let array = result.array else { return }
//			switch array.count {
//				case 0:
//					return
//				case 1:
//					finalResults = array[0]
//				default:
//					throw ModelError.duplicateObject
//			}
//		}
//		return finalResults
//	}
//
//	private func getSingleRow(_ connection: Connection? = nil, query: String, values: [Node]) throws -> Node?
//	{
//		guard let pgdb = self.pgdb else { fatalError("Rc2DAO accessed without connection") }
//		var finalResults: Node? = nil
//		try queue.sync { () throws -> Void in
//			let conn = connection == nil ? try pgdb.makeConnection() : connection!
//			let result = try conn.execute(query, values)
//			guard let array = result.array else { return }
//			switch array.count {
//			case 0:
//				return
//			case 1:
//				finalResults = array[0]
//			default:
//				throw ModelError.duplicateObject
//			}
//		}
//		return finalResults
//	}
//
//	private func getRows(_ connection: Connection? = nil, tableName: String, keyName: String, keyValue: Node) throws -> [Node]
//	{
//		guard let pgdb = self.pgdb else { fatalError("Rc2DAO accessed without connection") }
//		var finalResults: [Node] = []
//		try queue.sync  { () throws -> Void in
//			let conn = connection == nil ? try pgdb.makeConnection() : connection!
//			let result = try conn.execute("select * from \(tableName) where \(keyName) = $1", [keyValue])
//			guard let array = result.array, array.count > 0 else {
//				return
//			}
//			finalResults = array
//		}
//		return finalResults
//	}
//
//	private func getRows(query: String, connection: Connection? = nil) throws -> [Node] {
//		guard let pgdb = self.pgdb else { fatalError("Rc2DAO accessed without connection") }
//		var finalResults: [Node] = []
//		try queue.sync  { () throws -> Void in
//			let conn = connection == nil ? try pgdb.makeConnection() : connection!
//			let result = try conn.execute(query)
//			guard let array = result.array, array.count > 0 else {
//				return
//			}
//			finalResults = array
//		}
//		return finalResults
//	}
}
