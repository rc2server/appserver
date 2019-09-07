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
		// get user id
		let rUserId: Int? = try connection.getSingleRowValue(query: "select id from rcuser limit 1")
		guard let userId = rUserId else {
			XCTFail("null userid"); return
		}
		// get user
		guard let user = try dao.getUser(id: userId)
			else { XCTFail("failed to get user \(userId)"); return }
		// get bulk info
		let info = try dao.getUserInfo(user: user)
		XCTAssertEqual(info.projects.count, 2)
		let project = info.projects[0]
		XCTAssertEqual(info.workspaces.count, 2)
		let wspaces = info.workspaces[project.id]!
		let wspace = wspaces[0]
		XCTAssertTrue(wspace.name.starts(with: "wspace"))
		let files = info.files[wspace.id]!
		XCTAssertEqual(files.count, 3)
		
		//get same user by login
		let user2 = try dao.getUser(login: user.login)
		XCTAssertEqual(user, user2)
	}
	
	
	
	// MARK: - helper methods
	
	func reloadSQL() throws {
		var args = ["exec", "appserver_test", "psql", "-U", "rc2", "rc2", "--file", "/tmp/rc2.sql"]
		let dropR = try connection.execute(query: "drop owned by current_user", parameters: [])
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
		if nil == dockerURL {
			let envPath = ProcessInfo.processInfo.environment["DOCKER_EXE"] ?? "/usr/local/bin/docker"
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
			guard proc.terminationStatus == 0 else { throw Rc2TestErrors.noneZeroExitStatus }
			let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
			return String(decoding: outputData, as: UTF8.self)
		} catch {
			logger.critical("error trying to exec docker \(arguments.joined(separator: " "))")
			throw Rc2TestErrors.dockerCommandFailed
		}
	}
	
	static var allTests = [
		("testUserMethods", testUserMethods),
	]
}
