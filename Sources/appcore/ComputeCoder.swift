//
//  ComputeCoder.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation
import Dispatch
import Rc2Model
import servermodel
import Logging

/// object to transform data send/received from the compute engine
class ComputeCoder {
	let logger = Logger(label: "rc2.computeCoder")
	private let clientDataKey = "clientData"
	// MARK: - properties
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()
	private var nextQueryId: Int = 1
	private var transactionIds = [String: Int]()
	private var queryIds = [Int: String]()
	private let queue = DispatchQueue(label: "ComputeCommand Queue")
	
	// MARK: - initialization
	/// creates an object that generates the for commands to send to the compute engine
	/// create own decoder because client->app json might be different than app->compute json
	init() {
		encoder.dateEncodingStrategy = .millisecondsSince1970
		encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
		decoder.dateDecodingStrategy = .millisecondsSince1970
		decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
	}
	
	// MARK: - request methods
	/// Create the data to request a variable's value
	///
	/// - Parameter name: The name of the variable to get
	/// - Returns: data to send to compute server
	func getVariable(name: String, contextId: Int?, clientIdentifier: String? = nil) throws -> Data {
		let obj = GetVariableCommand(name: name, contextId: contextId, clientIdentifier: clientIdentifier)
		return try encoder.encode(obj)
	}
	
	/// Creates the data to request creation of a new environment
	func createEnvironment(transactionId: String, parentId: Int) throws -> Data {
		return try encoder.encode(CreateEnvironmentCommamnd(parentId: parentId, transactionId: transactionId))
	}
	
	/// Returns the message data to clear the specified environment
	///
	/// - Parameter id: the id of the environment
	func clearEnvironment(id: Int) throws -> Data {
		try encoder.encode(ClearEnvironmentCommand(contextId: id))
	}
	/// Create the data to request help for a topic
	///
	/// - Parameter topic: The help topic to query
	/// - Returns: data to send to compute server
	func help(topic: String) throws -> Data {
		return try encoder.encode(GenericCommand(msg: "help", argument: topic))
	}
	
	/// Create the data to save the environment
	///
	/// - Returns: data to send to compute server
	func saveEnvironment() throws -> Data {
		try encoder.encode(GenericCommand(msg: "saveEnv", argument: ""))
	}
	
	/// Create the data to execute a query
	///
	/// - Parameter transactionId: The unique transactionId
	/// - Parameter query: The query to execute
	/// - Returns: data to send to compute server
	func executeScript(transactionId: String, script: String) throws -> Data {
		try encoder.encode(ExecuteQuery(queryId: createQueryId(transactionId), script: script))
	}
	
	/// Create the data to execute a file
	///
	/// - Parameter transactionId: The unique transactionId
	/// - Parameter fileId: The id of the file to execute
	/// - Returns: data to send to compute server
	func executeFile(transactionId: String, fileId: Int, fileVersion: Int) throws -> Data {
		try encoder.encode(ExecuteFile(fileId: fileId, fileVersion: fileVersion, queryId: createQueryId(transactionId)))
	}
	
	/// Create the data to toggle variable watching
	///
	/// - Parameter enable: Should variables be watched
	/// - Returns: data to send to compute server
	func toggleVariableWatch(enable: Bool, contextId: Int?) throws -> Data {
		try encoder.encode(ToggleVariables(watch: enable, contextId: contextId))
	}
	
	/// Create the data to close the connection gracefully
	///
	/// - Returns: data to send to compute server
	func close() throws -> Data {
		try encoder.encode(GenericCommand(msg: "close", argument: ""))
	}
	
	/// Create the data to request a list of variables and their values
	///
	/// - Parameter deltaOnly: Should it return only changed values, or all values
	/// - Returns: data to send to compute server
	func listVariables(deltaOnly: Bool, contextId: Int?) throws -> Data {
		try encoder.encode(ListVariableCommand(delta: deltaOnly, contextId: contextId))
	}
	
	/// Create the data to open a connection to the compute server
	///
	/// - Parameter wspaceId: id of the workspace to use
	/// - Parameter sessionid: id of the session record to use for this session
	/// - Parameter dbhost: The hostname for the database server
	/// - Parameter dbport: The port for the database server. String is format compute server requires.
	/// - Parameter dbuser: The username to log into the database with
	/// - Parameter dbname: The name of the database to connect to
	/// - Parameter dbpassword: The password the compute server uses for the database
	/// - Returns: data to send to compute server
	func openConnection(wspaceId: Int, sessionId: Int, dbhost: String, dbPort: String = "5432", dbuser: String, dbname: String, dbpassword: String?) throws -> Data {
		let msg = OpenCommand(wspaceId: wspaceId, sessionRecId: sessionId, dbhost: dbhost, dbport: dbPort, dbuser: dbuser, dbname: dbname, dbpassword: dbpassword)
		return try encoder.encode(msg)
	}
	
	// MARK: - response handling
	
	func parseResponse(data: Data) throws -> ComputeResponse {
		do {
			let json = try JSON(data: data)
			guard let msg = json["msg"].string
				else { throw ComputeError.invalidInput }
			let queryId = json["queryId"].int
			let transId = queryIds[queryId ?? -1] // trans/query ids are always positive, avoid nil check
			let response = try ComputeResponse(messageType: msg, jsonData: data, decoder: decoder)
			switch response {
			case .execComplete(let resp):
				guard let transId = transId else { throw ComputeError.requiredFieldMissing }
				return .execComplete(resp.withTransaction(transId))
			case .results(let resp):
				guard let transId = transId else { throw ComputeError.requiredFieldMissing }
				return .results(resp.withTransaction(transId))
			case .showOutput(let resp):
				guard let transId = transId else { throw ComputeError.requiredFieldMissing }
				return .showOutput(resp.withTransaction(transId))
			default:
				return response
			}
		} catch let error where error is ComputeError {
			throw error
		} catch {
			logger.warning("parseResponse threw error \(error);json=\(String(data: data, encoding: .utf8) ?? "")")
			throw error
		}
	}
	
	// MARK: - internal methods
	
	
	private func createQueryId(_ transactionId: String) -> Int {
		var qid: Int = 0
		queue.sync {
			qid = nextQueryId
			self.nextQueryId = nextQueryId + 1
			transactionIds[transactionId] = qid
			queryIds[qid] = transactionId
		}
		return qid
	}
	
	// For internal usage to lookup a transactionId
	func queryId(for transId: String) -> Int? {
		transactionIds[transId]
	}
	
	// MARK: - private structs for command serialization
	struct OpenCommand: Codable {
		let msg = "open"
		let argument = ""
		let wspaceId: Int
		let sessionRecId: Int
		let apiVersion: Int = 1
		let dbhost: String
		let dbport: String
		let dbuser: String
		let dbname: String
		let dbpassword: String?
	}
	
	private struct GenericCommand: Encodable {
		let msg: String
		let argument: String
	}
	
	private struct ClearEnvironmentCommand: Encodable {
		let msg = "clearEnvironment"
		let argument = ""
		let contextId: Int
	}
	
	private struct GetVariableCommand: Encodable {
		static let clientIdentKey = "clientIdent"
		let msg = "getVariable"
		let argument: String
		let clientData: [String: String]?
		let contextId: Int?
		
		init(name: String, contextId: Int?, clientIdentifier: String? = nil) {
			argument = name
			self.contextId = contextId
			if let cident = clientIdentifier {
				clientData = [GetVariableCommand.clientIdentKey: cident]
			} else {
				clientData = nil
			}
		}
	}
	
	private struct ListVariableCommand: Encodable {
		let msg = "listVariables"
		let argument = ""
		let contextId: Int?
		let delta: Bool
		
		init(delta: Bool, contextId: Int?) {
			self.delta = delta
			self.contextId = contextId
		}
	}
	
	private struct ToggleVariables: Encodable {
		let msg = "toggleVariableWatch"
		let argument = ""
		let watch: Bool
		let contextId: Int?
		
		init(watch: Bool, contextId: Int?) {
			self.watch = watch
			self.contextId = contextId
		}
	}
	
	private struct ExecuteFile: Encodable {
		let msg = "execFile"
		let startTime = Int(Date().timeIntervalSince1970).description
		let argument: String
		let queryId: Int
		let clientData: [String: String]
		
		init(fileId: Int, fileVersion: Int, queryId: Int) {
			argument = "\(fileId)"
			self.queryId = queryId
			var cdata = [String: String]()
			cdata["fileId"] = String(fileId)
			cdata["fileVersion"] = String(fileVersion)
			clientData = cdata
		}
	}
	
	struct ExecuteQuery: Codable {
		let msg = "execScript"
		let queryId: Int
		let argument: String
		let startTime = Int(Date().timeIntervalSince1970).description
		
		init(queryId: Int, script: String) {
			self.queryId = queryId
			self.argument = script
		}
	}
	
	struct CreateEnvironmentCommamnd: Codable {
		let msg = "createEnviornment"
		let argument: String
		let parentId: Int
		
		init(parentId: Int, transactionId: String) {
			self.parentId = parentId
			self.argument = transactionId
		}
	}
}
