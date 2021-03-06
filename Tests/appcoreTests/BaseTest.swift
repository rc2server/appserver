//
//  BaseTest.swift
//  appcoreTests
//
//  Created by Mark Lilback on 9/16/19.
//

import XCTest
import Foundation
import Kitura
import KituraNet
import SwiftJWT
import Rc2Model
import servermodel
import Logging
import WebSocketKit
import NIO
@testable import appcore

class BaseTest: XCTestCase {
	static let logger = Logger(label: "rc2appserver unit test")
	static let testPort = 8888
	static let app: App? = try? App(["-p", "8888"])
	static var authHeader: String!
	static let evGroup: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
	
	private static let initOnce: () = {
		guard let app = app else {
			XCTFail("failed to initialize app")
			return
		}
		do {
			try app.postInit()
			let router = app.router

			let httpServer = Kitura.addHTTPServer(onPort: testPort, with: router)
			try httpServer.setEventLoopGroup(evGroup)
			Kitura.start()
			user = try app.dao.getUser(login: "login2")
			guard let myUser = user else { fatalError("failed to find user") }
			userInfo = try app.dao.getUserInfo(user: myUser)
			guard let myInfo = userInfo else { fatalError("failed to find user info") }
			let token = try app.dao.tokenDAO.createToken(user: myUser)
			var jwt = JWT(claims: token)
			let signedJwt = try jwt.sign(using: app.settings.jwtSigner)
			BaseTest.authHeader = "Bearer \(signedJwt)"
		} catch {
			XCTFail("failed to create server: \(error)")
		}
	}()
	
	static var user: User?
	static var userInfo: BulkUserInfo?
	static var session: Session? = {
		let project = userInfo!.projects.first!
		let wspace = userInfo!.workspaces[project.id]!.first!
		let aSession = TestSession(workspace: wspace, settings: app!.settings)
		// TODO: add fake connection to get responses
		return aSession
	}()
	
	override func setUp() {
		BaseTest.initOnce
	}
	
	func performRequest(_ method: String, path: String,  expectation: XCTestExpectation,
						headers: [String: String]? = nil,
						requestModifier: ((ClientRequest) -> Void)? = nil,
						callback: @escaping (ClientResponse) -> Void) {
		var allHeaders = [String: String]()
		if  let headers = headers {
			for  (headerName, headerValue) in headers {
				allHeaders[headerName] = headerValue
			}
		}
		if allHeaders["Content-Type"] == nil {
			allHeaders["Content-Type"] = "text/plain"
		}
		let options: [ClientRequest.Options] =
			[.method(method), .hostname("localhost"), .port(Int16(BaseTest.testPort)), .path(path), .headers(allHeaders)]
		let req = HTTP.request(options) { response in
			guard let response = response else {
				XCTFail("response object is nil")
				expectation.fulfill()
				return
			}
			callback(response)
			expectation.fulfill()
		}
		if let requestModifier = requestModifier {
			requestModifier(req)
		}
		req.end()
	}
}

class TestSession: Session {
	override func createWorker(k8sServer: K8sServer? = nil) throws {
		// do nothing since there is no worker
	}
}