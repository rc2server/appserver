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
@testable import appcore

class BaseTest: XCTestCase {
	static let testPort = 8888
	static let app: App? = try? App(["-p", "8888"])
	static var authHeader: String!
	
	private static let initOnce: () = {
		guard let app = app else {
			XCTFail("failed to initialize app")
			return
		}
		do {
			try app.postInit()
			let router = app.router
			Kitura.addHTTPServer(onPort: testPort, with: router)
			Kitura.start()
			user = try app.dao.getUser(id: 101)
			let token = try app.dao.tokenDAO.createToken(user: user!)
			var jwt = JWT(claims: token)
			let signedJwt = try jwt.sign(using: app.settings.jwtSigner)
			authHeader = "Bearer \(signedJwt)"
		} catch {
			XCTFail("failed to create server")
		}
	}()
	
	static var user: User?
	
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
		}
		if let requestModifier = requestModifier {
			requestModifier(req)
		}
		req.end()
	}
}
