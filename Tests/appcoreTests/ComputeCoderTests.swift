import XCTest
@testable import appcore
import Rc2Model

class ComputeCoderTests: XCTestCase {
	var coder: ComputeCoder!
	var decoder: JSONDecoder!
	
	struct JsonResponse: Codable {
		let msg: String
		let argument: String?
		let clientData: [String: String]?
		let watch: Bool?
		let delta: Bool?
	}
	
	override func setUp() {
		coder = ComputeCoder()
		decoder = JSONDecoder()
	}
	
	// MARK: - request tests
	func testCoderGetVariable() {
		let data = try! coder.getVariable(name: "foo123", contextId: nil, clientIdentifier: "foo")
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "getVariable")
		XCTAssertEqual(json.argument, "foo123")
		XCTAssertEqual(json.clientData?["clientIdent"], "foo")
	}
	
	func testCoderHelp() {
		let data = try! coder.help(topic: "rnorm")
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "help")
		XCTAssertEqual(json.argument, "rnorm")
	}
	
	func testCoderSaveEnvironment() {
		let data = try! coder.saveEnvironment()
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "saveEnv")
	}
	
	func testCoderExecuteScript() {
		let encoder = AppSettings.createJSONEncoder()
		let params = SessionCommand.ExecuteParams(sourceCode: "2*2", environmentId: 101)
		let cmd = SessionCommand.execute(params)
		let	ser = try! encoder.encode(cmd)
		let dser = try! decoder.decode(SessionCommand.self, from: ser)
		XCTAssertNotNil(dser)

//		let tid = "foo1"
//		let script = "rnorm(20)"
//		let data = try! coder.executeScript(transactionId: tid, script: script)
//		print("json=\(String(data: data, encoding: .utf8)!)")
//		let mds =
//		"""
//		{"msg": "execScript", "argument": "2*2", "queryId": 123, "startTime": "343" }
//		"""
//		let md = mds.data(using: .utf8)!
//		let json = try! decoder.decode(SessionCommand.self, from: md)
//		XCTAssertEqual(json.msg, "execScript")
//		XCTAssertEqual(json.argument, script)
	}
	
	func testCoderExecuteFile() {
		let fileId = 23
		let tid = "foo2"
		let data = try! coder.executeFile(transactionId: tid, fileId: fileId, fileVersion: 2)
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "execFile")
		XCTAssertEqual(json.clientData?["fileId"], String(fileId))
	}
	
	func testCoderToggleWatch() {
		let data = try! coder.toggleVariableWatch(enable: true, contextId: nil)
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "toggleVariableWatch")
		XCTAssertEqual(json.argument, "")
		XCTAssertEqual(json.watch, true)
	}
	
	func testCoderClose() {
		let data = try! coder.close()
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "close")
		XCTAssertEqual(json.argument, "")
	}
	
	func testCoderListVariables() {
		let data = try! coder.listVariables(deltaOnly: true, contextId: nil)
		let json = try! decoder.decode(JsonResponse.self, from: data)
		XCTAssertEqual(json.msg, "listVariables")
		XCTAssertEqual(json.argument, "")
		XCTAssertEqual(json.delta, true)
	}
	
	func testCoderOpen() {
		let wspaceId = 101
		let sessionId = 22012
		let dbHost = "dbserver"
		let dbUser = "rc2"
		let dbName = "rc2d"
		let data = try! coder.openConnection(wspaceId: wspaceId, sessionId: sessionId, dbhost: dbHost, dbuser: dbUser, dbname: dbName, dbpassword: "rc2")
		let response = try! decoder.decode(ComputeCoder.OpenCommand.self, from: data)
		XCTAssertEqual(response.msg, "open")
		XCTAssertEqual(response.wspaceId, wspaceId)
		XCTAssertEqual(response.sessionRecId, sessionId)
		XCTAssertEqual(response.dbhost, dbHost)
		XCTAssertEqual(response.dbuser, dbUser)
		XCTAssertEqual(response.dbname, dbName)
	}
	
	// MARK: - Response tests
	func testCoderOpenSuccess() {
		let openJson = """
	{"msg": "openresponse", "success": true }
"""
		let openRsp = try! coder.parseResponse(data: openJson.data(using: .utf8)!)
		guard case let ComputeResponse.open(openData) = openRsp else {
			XCTFail("invalid open response")
			return
		}
		XCTAssertEqual(openData.success, true)
	}
	
	func testCoderOpenFailure() {
		let json = """
		{"msg": "openresponse", "success": false, "errorMessage": "test error" }
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.open(openData) = resp else {
			XCTFail("invalid open response")
			return
		}
		XCTAssertEqual(openData.success, false)
		XCTAssertEqual(openData.errorMessage, "test error")
	}
	
	func testCoderOpenMalformed() {
		let json = """
		{"msg": "openresponse", "succe4ss": false }
		"""
		do {
			_ = try coder.parseResponse(data: json.data(using: .utf8)!)
		} catch let error where error is DecodingError {
			// do nothing because expected this type of error
		} catch {
			XCTFail("unexpected error with malfored error \(error)")
		}
	}
	
	func testCoderHelpSuccess() {
		let json = """
		{"msg": "help", "topic": "print", "paths": [ "/foo", "/bar" ] }
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.help(helpData) = resp
			else { XCTFail("invalid help response"); return }
		XCTAssertEqual(helpData.topic, "print")
		XCTAssertEqual(helpData.paths.count, 2)
		XCTAssertEqual(helpData.paths[0], "/foo")
		XCTAssertEqual(helpData.paths[1], "/bar")
	}
	
	func testCoderHelpMalformed() {
		let json = """
		{"msg": "help", "topic": "print" }
		"""
		// paths is required
		XCTAssertThrowsError(try coder.parseResponse(data: json.data(using: .utf8)!))
	}
	
	func testCoderErrorSuccess() {
		let json = "{ \"msg\": \"error\", \"errorCode\": 101, \"errorDetails\": \"foobar\"} }"
		let jdata = json.data(using: .utf8)!
		let resp = try! coder.parseResponse(data: jdata)
		guard case let ComputeResponse.error(err) = resp
		//guard case let ComputeResponse.error(errrsp) = resp
			else { XCTFail("invalid error response"); return }
		// above doesn't work without err being there. but it is not used. We just do a dummy use of it to fix this
		print("got \(err)")
		
		// FIXME: error responses have changed, but don't know what the json looks like. need to figure it out.
		// XCTAssertEqual(errrsp.errorCode, SessionErrorCode.unknownFile)
		//	XCTAssertEqual(errrsp.details, "foobar")
	}
	
	func testCoderErrorMalformed() {
		let json = """
		{"msg": "error", "Code": 123, "errorDetails": "foobar"}
		"""
		XCTAssertThrowsError(try coder.parseResponse(data: json.data(using: .utf8)!))
	}
	
	func testCoderBasicExecFile() {
		let qid = queryId(for: "foo1")
		let json = """
		{ "msg": "execComplete", "transId": "foo1", "queryId": \(qid), "expectShowOutput": true, "clientData": { "fileId": "33" }, "startTime": "", "imgBatch": 22, "images": [ 111, 222 ] }
		"""
		// expect
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.execComplete(execData) = resp
			else { XCTFail("failed to parse exec complete"); return }
		XCTAssertEqual(execData.transId, "foo1")
		XCTAssertEqual(execData.expectShowOutput, true)
		XCTAssertEqual(execData.batchNumber, 22)
		XCTAssertEqual(execData.images?.count, 2)
		XCTAssertEqual(execData.images?[0], 111)
		XCTAssertEqual(execData.images?[1], 222)
	}
	
	func testCoderResults() {
		let qid = queryId(for: "foo2")
		let json = """
		{ "msg": "results", "is_error": false, "string": "R output", "queryId": \(qid) }
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.results(results) = resp
			else { XCTFail("failed to get results"); return }
		XCTAssertEqual(results.isError, false)
		XCTAssertEqual(results.transId, "foo2")
		XCTAssertEqual(results.string, "R output")
	}
	
	func testCoderShowOutput() {
		let qid = queryId(for: "foo3")
		let json = """
		{ "msg": "showoutput", "fileId": 22, "fileVersion": 1, "fileName" : "foobar.pdf", "queryId": \(qid) }
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.showOutput(results) = resp
			else { XCTFail("failed to show output"); return }
		XCTAssertEqual(results.fileId, 22)
		XCTAssertEqual(results.transId, "foo3")
		XCTAssertEqual(results.fileVersion, 1)
		XCTAssertEqual(results.fileName, "foobar.pdf")
	}
	
	//	func testVariableDelta() {
	//		let json = """
	//		{
	//		  "clientData": {},
	//		  "delta": true,
	//		  "msg": "variableupdate",
	//		  "variables": {
	//			"assigned": {
	//			  "x": {
	//				"class": "numeric vector",
	//				"length": 1,
	//				"name": "x",
	//				"primitive": true,
	//				"type": "d",
	//				"value": [
	//				  34.0
	//				]
	//			  }
	//			},
	//			"removed": []
	//		  }
	//		}
	//		"""
	//		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
	//		guard case let ComputeCoder.Response.variables(results) = resp
	//			else { XCTFail("failed to parse delta variables"); return }
	//		XCTAssertEqual(results.delta, false)
	//		XCTAssertEqual(results.variables.count, 1)
	//		XCTAssertEqual(results.removed.count, 0)
	//	}
	// TODO: add tests for variableValue and variables when those responses are properly handled
	
	func testCoderVariableUpdate() {
		let json = """
		{"clientData":{},"delta":false, "msg":"variableupdate", "variables":{"headless":{"class":"matrix", "length":8,"name":"headless", "ncol":2,"nrow":4,"primitive":false, "type":"i","value":[1,2,3,4,5,6,7,8]}, "sampleMatrix":{"class":"matrix", "dimnames":[["x","y","z","a"],["foo","bar"]], "length":8,"name":"sampleMatrix","ncol":2,"nrow":4 ,"primitive":false,"type":"i","value":[1,2,3,4,5,6,7,8]}}}
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.variableUpdate(varData) = resp
			else { XCTFail("failed to parse variable update"); return }
		XCTAssertNotNil(varData.variables)
		XCTAssertEqual(varData.variables.count, 2)
		XCTAssertNil(varData.variables["headless"]!.matrixData!.rowNames)
		XCTAssertEqual(varData.variables["sampleMatrix"]?.name, "sampleMatrix")
	}
	
	func testCoderVariableDelta() {
		let json = """
		{
			"clientData": {},
			"delta": true,
			"msg": "variableupdate",
			"variablesAdded": {
				"x": {
					"class": "numeric vector",
					"length": 1,
					"name": "x",
					"primitive": true,
					"type": "d",
					"value": [44.0]
				}
			},
				"variables": {},
				"variablesRemoved": ["foo"]
		}
		"""
		let resp = try! coder.parseResponse(data: json.data(using: .utf8)!)
		guard case let ComputeResponse.variableUpdate(varData) = resp
			else { XCTFail("failed to parse variable update"); return }
		XCTAssertNotNil(varData.added)
		XCTAssertEqual(varData.added.count, 1)
		let theVar = varData.added["x"]
		XCTAssertEqual(theVar?.name, "x")
	}
	
	func testCoderDataFrameParser() {
		let json = """
		{"clientData":{},"delta":false,"msg":"variableupdate","variables":{"cdf":
		{"class":"data.frame","type":"data.frame",  "columns":[{"name":"c1","type":"b","values":[false,true,null,null,true,false]},{"name":"c2","type":"d","values":[3.14,null,"NaN",21.0,"Inf","-Inf"]},{"name":"c3","type":"s","values":["Aladdin",null,"NA","Mario","Mark","Alex"]},{"name":"c4","type":"i","values":[1,2,3,null,5,null]}],"name":"cdf","ncol":4,"nrow":6,"row.names":["1","2","3","4","5","6"],"summary":"JSONSerialization barfs on a real R summary text with control characters"}
		}}
		"""
		let jsonData = json.data(using: .utf8)!
		let resp = try! coder.parseResponse(data: jsonData)
		guard case let ComputeResponse.variableUpdate(varData) = resp
			else { XCTFail("failed to parse df variable update"); return }
		XCTAssertNotNil(varData.variables)
		XCTAssertEqual(varData.variables.count, 1)
		guard let dvar = varData.variables["cdf"] else { XCTFail("failed to get df variable"); return }
		guard case let .dataFrame(dfd) = dvar.type else { XCTFail("failed to extract dataframedata"); return }
		XCTAssertEqual(dfd.columns.count, 4)
	}
	
	// MARK: - helper methods
	private func queryId(for transId: String) -> Int {
		let reqData = try! coder.executeScript(transactionId: transId, script: "rnorm(20)")
		let response = try! decoder.decode(ComputeCoder.ExecuteQuery.self, from: reqData)
		return response.queryId
	}
}
