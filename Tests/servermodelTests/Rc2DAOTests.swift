//
//  Rc2DAOTests.swift
//
//  Copyright ©2019 Mark Lilback. This file is licensed under the ISC license.
//


///	The setup for this test (first time only) copies two files to the
///	test db container: rc2.sql creates the sql schema, testData.pgsql
///	is a PL/PGSQL code that generates 5 test users with projects,
///	workspaces, and files.
///
///	Every time a test is run, alll db objects owned by user rc2 are
///	deleted (in case a previous run had failed and not run tearDown(),
///	and then recreated. tearDown() removes all objects owned by rc2.


import XCTest
@testable import servermodel
import pgswift
import Logging
import Rc2Model

internal let logger = Logger(label: "io.rc2.appserver.tests")

enum Rc2TestErrors: Error {
	case dockerCommandFailed
	case noneZeroExitStatus
}

final class Rc2DAOTests: XCTestCase {
	var connection: Connection!
	var dockerURL: URL!
	let sqlFileQueue = DispatchQueue(label: "io.rc2.appserver.test.sqlFile")
	var sqlFileURL: URL!
	var testDataURL: URL!
	var sqlFileCopied = false
	var dao: Rc2DAO!
	
	// MARK: -
	override func setUp() {
		super.setUp()

		let projectUrl = URL(fileURLWithPath: #file)
			.deletingLastPathComponent() // filename
			.deletingLastPathComponent() // test target directory
			.deletingLastPathComponent() // Tests directory
		
		do {
			guard confirmDockerRunning() else {
				logger.critical("docker container not running")
				fatalError("pgtest docker container not running. See README.md.")
			}
			
			// since tests can run on multiple cores, lock this action
			try sqlFileQueue.sync {
				if !sqlFileCopied {
					// find sql files and copy to container
					let sqlUrl = projectUrl.appendingPathComponent("rc2root/rc2.sql")
					let testSql = projectUrl.appendingPathComponent("testData.pgsql")
					guard FileManager.default.fileExists(atPath: sqlUrl.path),
						FileManager.default.fileExists(atPath: testSql.path)
					else {
						fatalError("failed to find rc2.sql file for testing")
					}
					let dbCheckOutput = try runDocker(arguments: ["cp", sqlUrl.path, "appserver_test:/tmp/rc2.sql"])
					XCTAssertEqual(dbCheckOutput.count, 0)
					let testDataOutput = try runDocker(arguments: ["cp", testSql.path, "appserver_test:/tmp/testData.pgsql"])
					XCTAssertEqual(testDataOutput.count, 0)
					testDataURL = testSql
					sqlFileURL = sqlUrl
					sqlFileCopied = true
				}
			}
		} catch {
			fatalError("docker check failed")
		}

		// open database connection
		connection = Connection(host: "localhost", port: "5434", user: "rc2", password: "secret", dbname: "rc2", sslMode: .prefer)
		do {
			try connection.open()
			try reloadSQL()
			dao = Rc2DAO(connection: connection)
		} catch {
			XCTFail("failed to open database connection: \(error)")
		}
	}
	
	override func tearDown() {
		super.tearDown()
		_ = try! connection.execute(query: "drop owned by current user", parameters: [])
	}
	
	
	
	// MARK: - actual tests
	
	func testUserMethods() throws {
		// get user info
		let info = try helperGetUserInfo()
		// teest the bulk info
		XCTAssertEqual(info.projects.count, 2)
		let project = info.projects[0]
		XCTAssertEqual(info.workspaces.count, 2)
		let wspaces = info.workspaces[project.id]!
		let wspace = wspaces[0]
		XCTAssertTrue(wspace.name.starts(with: "wspace"))
		let files = info.files[wspace.id]!
		XCTAssertEqual(files.count, 3)
		
		//get same user by login
		let user2 = try dao.getUser(login: info.user.login)
		XCTAssertEqual(info.user, user2)
		
		// test via password. need set one. get second user
		let puserId: Int = try connection.getSingleRowValue(query: "select id from rcuser offset 1 limit 1")!
		let puser: User = try dao.getUser(id: puserId)!
		// set the password
		let newPassword = "foobar"
		try dao.changePassword(userId: puser.id, newPassword: newPassword)
		// verify that is now the password
		let puser2 = try dao.getUser(login: puser.login, password: newPassword)
		XCTAssertNotNil(puser2)
		XCTAssertEqual(puser.id, puser2!.id)
		XCTAssertEqual(puser.login, puser2!.login)
	}
	
	func testWorkspaceMethods() throws {
		// also test workspace functionality since we already have that data to compare to
		let info = try helperGetUserInfo()
		let project = info.projects[0]
		let wspaces = info.workspaces[project.id]!
		let wspace = wspaces[0]
		
		// verify getProject
		let fetchedProj = try dao.getProject(id: project.id)
		XCTAssertEqual(fetchedProj, project)
		let fetchedProjs = try dao.getProjects(ownedBy: info.user)
		XCTAssertEqual(Set(info.projects), Set(fetchedProjs))
		
		// verify getWorkspace works
		let fetchedWspace = try! dao.getWorkspace(id: wspace.id)
		XCTAssertNotNil(fetchedWspace)
		XCTAssertEqual(fetchedWspace, wspace)
		// getWorkspaces
		let fetchedSpaces = try dao.getWorkspaces(project: project)
		XCTAssertEqual(wspaces.count, fetchedSpaces.count)
		let doubleFetched = fetchedSpaces.first { $0.id == fetchedWspace!.id }
		XCTAssertEqual(fetchedWspace, doubleFetched)
		// verify no existing workspace
		let wsName = "json"
		XCTAssertNil(wspaces.first { $0.name == wsName })
		let newWspace = try dao.createWorkspace(project: project, name: wsName, insertingFiles: [sqlFileURL, testDataURL])
		XCTAssertEqual(newWspace.name, wsName)
		XCTAssertEqual(newWspace.projectId, project.id)
		// delete workspace. throws exception if it fails
		try dao.delete(workspaceId: newWspace.id)
		XCTAssertNil(try dao.getWorkspace(id: newWspace.id))
	}
	
	func testSessionRecord() throws {
		// pick a workspace
		let anId: Int? = try connection.getSingleRowValue(query: "select id from rcworkspace limit 1")
		guard let wspaceId = anId else { fatalError("failed to get a wspaceId") }
		// create session record
		let sid = try dao.createSessionRecord(wspaceId: wspaceId)
		guard let scount: Int = try connection.getSingleRowValue(query: "select count(*) from sessionrecord where id = \(sid) and enddate is null"), scount == 1
		else {
			fatalError("failed to verify sessionrecord was created")
		}
		// close it
		try dao.closeSessionRecord(sessionId: sid)
		let ccount: Int? = try connection.getSingleRowValue(query: "select count(*) from sessionrecord where id = \(sid) and enddate is not null")
		guard let count = ccount else { fatalError("failed to cast") }
		XCTAssertEqual(count, 1)
	}
	
	func testFiles() throws {
		let info = try helperGetUserInfo()
		let project = info.projects[0]
		let wspace = info.workspaces[project.id]![0]
		let files = info.files[wspace.id]!
		let file = files[0]
		
		// getFile
		let fetchedFile = try dao.getFile(id: file.id, userId: info.user.id)!
		XCTAssertEqual(fetchedFile, file)
		// getFiles
		let fetchedFiles = try dao.getFiles(workspace: wspace)
		XCTAssertEqual(Set(fetchedFiles), Set(files))
		// getFileData
		let dataLength: Int = try connection.getSingleRowValue(query: "select length(bindata) from rcfiledata where id = \(file.id)")!
		XCTAssertEqual(dataLength, file.fileSize)
		// rename
		let newName = "foobaz.R"
		let renamedFile = try dao.rename(fileId: file.id, version: file.version, newName: newName)
		XCTAssertEqual(renamedFile.name, newName)
		XCTAssertEqual(renamedFile.id, file.id)
		XCTAssertGreaterThan(renamedFile.version, file.version)
		// insert, update, getFileData, setFile(data:)
		let rawData = try Data(contentsOf: testDataURL)
		let insFile = try dao.insertFile(name: "foobar.R", wspaceId: wspace.id, bytes: rawData)
		XCTAssertEqual(insFile.name, "foobar.R")
		let fetchedData  = try dao.getFileData(fileId: insFile.id)
		XCTAssertEqual(fetchedData, rawData)
		let rawData2 = try Data(contentsOf: sqlFileURL)
		// set file data
		let updatedFile = try dao.setFile(data: rawData2, fileId: insFile.id, fileVersion: insFile.version)
		XCTAssertGreaterThan(updatedFile.version, insFile.version)
		XCTAssertEqual(updatedFile.name, insFile.name)
		XCTAssertEqual(updatedFile.fileSize, rawData2.count)
		// set file data wrong version
		XCTAssertThrowsError(try dao.setFile(data: rawData, fileId: updatedFile.id, fileVersion: 21))
		//delete
		try dao.delete(fileId: insFile.id) //throws on error)
		XCTAssertThrowsError(try dao.getFileData(fileId: insFile.id))
		let dupFile = try dao.duplicate(fileId: file.id, withName: "dupFile.R")
		let dupFile2 = try dao.getFile(id: dupFile.id, userId: info.user.id)!
		XCTAssertEqual(dupFile2.fileSize, dupFile.fileSize)
		XCTAssertEqual(dupFile2.name, "dupFile.R")
	}
	
	func testImages() throws {
		let info = try helperGetUserInfo()
		// requires a session exist
		let sessionId = try dao.createSessionRecord(wspaceId: info.user.id)
		// pretned testData is an image
		let imgData = try Data(contentsOf: testDataURL)
		let batchId = 11
		let query = "insert into sessionimage (sessionid, batchid, name, imgData) values ($1, $2, $3, $4) returning id"
		let params = [
			try QueryParameter(type: .int8, value: sessionId, connection: connection),
			try QueryParameter(type: .int8, value: batchId, connection: connection),
			try QueryParameter(type: .varchar, value: "imagefile.png", connection: connection),
			try QueryParameter(type: .bytea, value: imgData, connection: connection)
		]
		var imageIds = [Int]()
		for _ in 0..<3 {
			let results = try connection.execute(query: query, parameters: params)
			XCTAssert(results.wasSuccessful)
			XCTAssertEqual(results.rowsAffected, 1)
			XCTAssertEqual(results.rowCount, 1)
			XCTAssertEqual(results.columnCount, 1)
			let imageId: Int = try results.getValue(row: 0, column: 0)!
			imageIds.append(imageId)
		}
		//now get the images
		let images = try dao.getImages(imageIds: imageIds)
		XCTAssertEqual(images.count, 3)
		XCTAssertEqual(images[0].batchId, batchId)
	}
	
	// MARK: - helper methods
	
	func reloadSQL() throws {
		var args = ["exec", "appserver_test", "psql", "-U", "rc2", "rc2", "--file", "/tmp/rc2.sql"]
		_ = try connection.execute(query: "drop owned by current_user", parameters: [])
		_ = try runDocker(arguments: args)
		// generate test data
		args[args.count - 1] = "/tmp/testData.pgsql"
		_ = try runDocker(arguments: args)
	}
	
	func confirmDockerRunning() -> Bool {
		do {
		let dbCheckOutput = try runDocker(arguments: ["ps", "--format", "'{{.Names}}'", "--filter", "name=appserver_test"])
		return dbCheckOutput.contains("appserver_test")
		} catch {
			logger.critical("failed to run docker ps")
			return false
		}
	}
	
	/// Executes a docker command returns STDOUT
	///
	/// - Parameter arguments: the arguments to use
	/// - Returns: a string containg STDOUT
	/// - Throws: if docker command fails
	func runDocker(arguments: [String]) throws -> String {
		#if os(Linux)
			let defaultDockerPath = "/usr/bin/docker"
		#else
			let defaulDockerPath = "/usr/local/bin/docker"
		#endif
		if nil == dockerURL {
			let envPath = ProcessInfo.processInfo.environment["DOCKER_EXE"] ?? defaultDockerPath
			dockerURL = URL(fileURLWithPath: envPath)
		}
		let proc = Process()
		proc.executableURL = dockerURL
		proc.arguments = arguments
		let outPipe = Pipe()
		proc.standardOutput = outPipe
		do {
			try proc.run()
			proc.waitUntilExit()
			guard proc.terminationStatus == 0 else { 
				logger.error("docker exec returned \(proc.terminationStatus)")
				throw Rc2TestErrors.noneZeroExitStatus 
			}
			let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
			return String(decoding: outputData, as: UTF8.self)
		} catch {
			logger.critical("error '\(error)' trying to exec docker \(arguments.joined(separator: " "))")
			throw Rc2TestErrors.dockerCommandFailed
		}
	}
	
	func helperGetUserInfo() throws -> BulkUserInfo {
		let rUserId: Int? = try connection.getSingleRowValue(query: "select id from rcuser limit 1")
		guard let userId = rUserId else {
			XCTFail("null userid"); fatalError()
		}
		// get user
		guard let user = try dao.getUser(id: userId)
			else { XCTFail("failed to get user \(userId)"); fatalError() }
		return try dao.getUserInfo(user: user)
	}
	static var allTests = [
		("testUserMethods", testUserMethods),
		("testWorkspaceMethods", testWorkspaceMethods),
		("testSessionRecord", testSessionRecord),
		("testFiles", testFiles),
		("testImages", testImages),
	]
}
