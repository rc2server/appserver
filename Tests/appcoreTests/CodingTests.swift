

//
//  CodingTests.swift
//  appcoreTests
//
//  Created by Mark Lilback on 9/16/19.
//

import XCTest
import Foundation
import NIO
import NIOWebSocket
import WebSocketKit
import servermodel
@testable import appcore
@testable import Rc2Model
import SwiftyJSON

final class CodingTests: BaseTest, SessionConnectionDelegate {
  var pendingExpectation: XCTestExpectation?
  var waitingCount: Int = 0
  var messages = Queue<Data>()

  func connectionDataSent(data: Data) {
    messages.enqueue(data)
    waitingCount -= 1
    guard waitingCount <= 0 else { return }
    pendingExpectation?.fulfill()
    pendingExpectation = nil
  }

  func createExpectation(_ description: String, count: Int) -> XCTestExpectation {
    let expec = XCTestExpectation(description: description)
    waitingCount -= 1
    messages.removeAll()
    pendingExpectation = expec
    return expec
  }

	func testPreviewInited() throws {
		let settings = Self.app!.settings!
    let session = Self.session
    let scon = SessionConnection(connection: nil, user: Self.user!, settings: Self.app!.settings, logger: Self.logger)
    scon.delegate = self
    session?.added(connection: scon)
    let expec = createExpectation("open weboscket", count: 1)
    let fid = try settings.dao.getProjects(ownedBy: Self.user!).first!.id

  // Compute just sends the PreviewInited data, but encoding it sticks it as a dict in the outer json. need to extract and add the "msg" value
    let responseData = ComputeResponse.PreviewInited(previewId: 2, fileId: fid, errorCode: 0, updateIdentifier: "blah")
    let crsp = ComputeResponse.previewInited(responseData)
    var data = try Self.app!.settings.encode(crsp)
    var json = try SwiftyJSON.JSON(data: data)["previewInited"]
    json["msg"] = SwiftyJSON.JSON("previewInited")
    data = json.description.data(using: .utf8)!
    session!.handleCompute(data: data)
    wait(for: [expec], timeout: 3)
    XCTAssertEqual(messages.count, 1)
    let sessionResponse = try settings.decode(SessionResponse.PreviewInitedData.self, from: data)
    XCTAssertEqual(sessionResponse.previewId, responseData.previewId)
    XCTAssertEqual(sessionResponse.fileId, responseData.fileId)
    XCTAssertEqual(sessionResponse.updateIdentifier, responseData.updateIdentifier)
  }

	func testPreviewUpdated() throws {
		let settings = Self.app!.settings!
    let session = Self.session
    let scon = SessionConnection(connection: nil, user: Self.user!, settings: Self.app!.settings, logger: Self.logger)
    scon.delegate = self
    session?.added(connection: scon)
    let expec = createExpectation("buggy response", count: 1)

    let computeData = updateJson.data(using: .utf8)!
    session!.handleCompute(data: computeData)
    wait(for: [expec], timeout: 2)
    XCTAssertEqual(messages.count, 1)
    let sessionResponse = try settings.decode(SessionResponse.PreviewUpdateData.self, from: computeData)
    XCTAssertEqual(sessionResponse.chunkId, 4)
    XCTAssertEqual(sessionResponse.previewId, 1)
    XCTAssertEqual(sessionResponse.results, "some content")
  }

}

let updateJson = """
{
  "msg": "updatePreview",
  "chunkId": 4,
  "complete": false,
  "content": "some content",
  "msg": "previewUpdated",
  "previewId": 1,
  "updateIdentifier": ""
}
"""
