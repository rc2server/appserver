//
//  PathTests.swift
//  appcoreTests
//
//  Created by Mark Lilback on 9/16/19.
//

import XCTest
import Foundation
import Kitura
import KituraNet
@testable import appcore
@testable import Rc2Model

final class PathTests: BaseTest {
	func testInfoRoute() throws {
/*		let expect = self.expectation(description: "get info")
		let headers: [String : String] = [HTTPHeaders.authorization: BaseTest.authHeader]
		performRequest("get", path: "/info", expectation: expect, headers: headers) { response in
			XCTAssertEqual(response.statusCode, HTTPStatusCode.OK, "request failed")
			var data = Data()
			var info: BulkUserInfo?
			do {
				let _ = try response.readAllData(into: &data)
			XCTAssertNoThrow(info = try PathTests.app?.settings.decode(BulkUserInfo.self, from: data))
			XCTAssertEqual(BaseTest.user?.id, info?.user.id)
			} catch {
				XCTFail()
			}
		}
		waitForExpectations(timeout: 1, handler: nil)
*/	}

	static var allTests = [
		("testInfoRoute", testInfoRoute),
	]
	

}
