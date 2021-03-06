//
//  ComputeResponse.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation
import Rc2Model
import servermodel
import Logging

fileprivate let logger = Logger(label: "rc2.ComputeResponse")

/// responses that can be returned by the comppute engine
public enum ComputeResponse: Equatable, Codable {

	case open(Open)
	case help(Help)
	case variableValue(VariableValue)
	case variableUpdate(VariableUpdate)
	case error(Error)
	case results(Results)
	case showOutput(ShowOutput)
	case execComplete(ExecComplete)
	case envCreated(EnvCreated)
	case previewInited(PreviewInited)
	case previewUpdated(PreviewUpdated)
	case previewUpdateStarted(PreviewUpdateStartedData)

	private enum CodingKeys: String, CodingKey {
		case open
		case help
		case variableValue
		case variableUpdate
		case error
		case results
		case showOutput
		case execComplete
		case envCreated
		case previewInited
		case previewUpdated
		case previewUpdateStarted
	}

	init(messageType: String, jsonData: Data, decoder: JSONDecoder) throws {
		do {
			switch messageType {
			case "openresponse":
				let rsp = try decoder.decode(Open.self, from: jsonData)
				self = .open(rsp)
			case "execComplete":
				let rsp = try decoder.decode(ExecComplete.self, from: jsonData)
				self = .execComplete(rsp)
			case "results":
				let rsp = try decoder.decode(Results.self, from: jsonData)
				self = .results(rsp)
			case "showoutput":
				let rsp = try decoder.decode(ShowOutput.self, from: jsonData)
				self = .showOutput(rsp)
			case "variableupdate":
				self = .variableUpdate(try VariableUpdate(json: try JSON(data: jsonData)))
			case "variablevalue":
				self = .variableValue(try VariableValue(json: try JSON(data: jsonData)))
			case "help":
				let rsp = try decoder.decode(Help.self, from: jsonData)
				self = .help(rsp)
			case "error":
				let rsp = try decoder.decode(Error.self, from: jsonData)
				self = .error(rsp)
			case "envCreated":
				let rsp = try decoder.decode(EnvCreated.self, from: jsonData)
				self = .envCreated(rsp)
			case "previewInited":
				let rsp = try decoder.decode(PreviewInited.self, from: jsonData)
				self = .previewInited(rsp)
			case "previewUpdateStarted":
				let rsp = try decoder.decode(PreviewUpdateStartedData.self, from: jsonData)
				self = .previewUpdateStarted(rsp)
			case "previewUpdated":
				let rsp = try decoder.decode(PreviewUpdated.self, from: jsonData)
				self = .previewUpdated(rsp)
			default:
				logger.warning("unknown msg: \(messageType)")
				throw ComputeError.invalidInput
			}
		} catch let error where error is ComputeError {
			throw error
		} catch {
			logger.warning("error parsing compute response: \(error)")
			throw error
		}
	}

	/// implementation of Decodable
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let params = try? container.decode(Open.self, forKey: .open) {
			self = .open(params)
		} else if let params = try? container.decode(Help.self, forKey: .help) {
			self = .help(params)
		} else if let params = try? container.decode(VariableValue.self, forKey: .variableValue) {
			self = .variableValue(params)
		} else if let params = try? container.decode(VariableUpdate.self, forKey: .variableUpdate) {
			self = .variableUpdate(params)
		} else if let params = try? container.decode(Error.self, forKey: .error) {
			self = .error(params)
		} else if let params = try? container.decode(Results.self, forKey: .results) {
			self = .results(params)
		} else if let params = try? container.decode(ShowOutput.self, forKey: .showOutput) {
			self = .showOutput(params)
		} else if let params = try? container.decode(ExecComplete.self, forKey: .execComplete) {
			self = .execComplete(params)
		} else if let params = try? container.decode(EnvCreated.self, forKey: .envCreated) {
			self = .envCreated(params)
		} else if let params = try? container.decode(PreviewInited.self, forKey: .previewInited) {
			self = .previewInited(params)
		} else if let params = try? container.decode(PreviewUpdated.self, forKey: .previewUpdated) {
			self = .previewUpdated(params)
		} else if let params = try? container.decode(PreviewUpdateStartedData.self, forKey: .previewUpdateStarted) {
			self = .previewUpdateStarted(params)
		} else {
			logger.warning("failed to parse a SessionCommand")
			throw SessionError.decoding("failed to parse session command")
		}
	}
	
	/// implementation of Encodable
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
			case .open(let params):
				try container.encode(params, forKey: .open)
			case .help(let params):
				try container.encode(params, forKey: .help)
			case .variableValue(let params):
				try container.encode(params, forKey: .variableValue)
			case .variableUpdate(let params):
				try container.encode(params, forKey: .variableUpdate)
			case .error(let params):
				try container.encode(params, forKey: .error)
			case .results(let params):
				try container.encode(params, forKey: .results)
			case .showOutput(let params):
				try container.encode(params, forKey: .showOutput)
			case .execComplete(let params):
				try container.encode(params, forKey: .execComplete)
			case .envCreated(let params):
				try container.encode(params, forKey: .envCreated)
			case .previewInited(let params):
				try container.encode(params, forKey: .previewInited)
			case .previewUpdated(let params):
				try container.encode(params, forKey: .previewUpdated);
		case .previewUpdateStarted(let params):
			try container.encode(params, forKey: .previewUpdateStarted)
		}
	}

	/// response from an open message
	public struct Open: Codable, Hashable {
		/// was the connection opened
		let success: Bool
		/// if didn't succede, the error that happened
		let errorMessage: String?
	}

	/// response from a help messsage
	public struct Help: Codable, Hashable {
		/// the topic the request was about
		let topic: String
		/// an array of relative paths to matcdhing R html docuemntation
		let paths: [String]
	}

	/// response from a get variable command
	public struct VariableValue: Codable, Equatable {
		/// name of the variable
		let name: String
		/// the value as an object
		let value: Variable
		/// the environment the value came from
		let contextId: Int?
		/// the start if one was passed in the request, otherwise an empty string
		let startTime: String
		/// any client data that was passed in the request
		let clientData: [String : String]?
		/// the clientId that was passed in the GetVariable command via clientData
		let clientId: String?

		// initializer that converts the [String : Any] dictionary to a variable
		init(json: JSON) throws {
			let dname = json["name"].string
			guard dname != nil else { 
				logger.warning("received VariableValue without a name")
				throw ComputeError.invalidInput 
			}
			name = dname!
			startTime = json["startTime"].string ?? ""
			clientData = json["clientData"].dictionary?.mapValues { $0.string ?? "" }
			contextId = json["contextId"].int
			clientId = clientData?["clientIdent"]?.string

			guard json["value"].dictionary != nil else { throw ComputeError.invalidInput }
			value = try Variable.makeFromLegacy(json: json["value"], logger: logger)
		}
	}

	/// response frpm a list variables command, also sent when there are changes if the client is watching for changes
	public struct VariableUpdate: Codable, Equatable {
		/// if true, only added and removed will be valid. Otherwise, variables will be valid
		let delta: Bool
		/// the variables
		let variables: [String:Variable]
		/// any variables added when returning delta changes
		let added: [String:Variable]
		/// array of names of variables that were reomved
		let removed: [String]
		/// the id of the environment the variables are from
		let environmentId: Int?
		/// any client data that was passed in the request. nil for automatic updates
		let clientData: [String : String]?
		
		enum CodingKeys: String, CodingKey {
			case variables
			case delta
			case clientData
			case added = "variablesAdded"
			case removed = "variablesRemoved"
			case environmentId = "contextId"
		}
		
		// initializer that converts the [String : Any] dictionaries to [String : Variable] which JSON Serialization won't due for legacy json
		init(json: JSON) throws {
			let dval = json["delta"].bool
			guard dval != nil else { logger.warning("VariableUpdate without delta value"); throw ComputeError.invalidInput }
			delta = dval!
			environmentId = json["contextId"].int
			clientData = json["clientData"].dictionary?.mapValues { $0.string ?? "" }
			removed = json["variablesRemoved"].array?.map { $0.string ?? "" } ?? []
			let vars = json["variables"].dictionary ?? [:]
			if vars.count > 0 {
				variables = try vars.mapValues {  try Variable.makeFromLegacy(json: $0, logger: logger) }
			} else {
				variables = [:]
			}
			let addedDict = json["variablesAdded"].dictionary ?? [:]
			added = try addedDict.mapValues { try Variable.makeFromLegacy(json: $0, logger: logger) }
		}
	}

	/// response when an error occurred
	public struct Error: Codable, Equatable {
		/// the error code
		let error: Int

		/// details of the error, for logging not display to user
		let details: String
		/// queryId if one accompanied the request
		let queryId: Int?
		/// local transactionId
		let transId: String?
		
		enum CodingKeys: String, CodingKey {
			case error = "errorCode"
			case details = "errorDetails"
			case queryId
			case transId
		}
		
		func withTransactionId(_ transId: String) -> Error {
			return Error(error: error, details: details, queryId: queryId, transId: transId)
		}
	}

	/// any output that came to stdout or stderr
	public struct Results: Codable, Hashable {
		/// the output
		let string: String
		/// was the message to stderr or stdout
		let isError: Bool
		/// a queryId if one was included with the query
		let queryId: Int?
		/// local transactionId
		let transId: String?

		enum CodingKeys: String, CodingKey {
			case string
			case isError = "is_error"
			case queryId
			case transId
		}
		
		/// returns a clone of self with the transactionId added
		func withTransaction(_ transId: String) -> Results {
			return Results(string: string, isError: isError, queryId: queryId, transId: transId)
		}
	}
	
	/// sent when a query generated a file that should be displayed to the user (e.g. html, pdf)
	public struct ShowOutput: Codable, Hashable {
		/// the id of the file in the database
		let fileId: Int
		/// the name of the file
		let fileName: String
		/// the version of the file as saved to the database
		let fileVersion: Int
		/// the queryId of
		let queryId: Int
		/// local transactionId
		let transId: String?
		
		/// returns a clone of self with the transactionId added
		func withTransaction(_ transId: String) -> ShowOutput {
			return ShowOutput(fileId: fileId, fileName: fileName, fileVersion: fileVersion, queryId: queryId, transId: transId)
		}
	}

	public struct ExecComplete: Codable, Hashable {
		let expectShowOutput: Bool
		let queryId: Int
		let startTime: String?
		let images: [Int]?
		let batchNumber: Int?
		let clientData: [String:String]?
		let transId: String?
		
		enum CodingKeys: String, CodingKey {
			case expectShowOutput
			case queryId
			case startTime
			case images
			case batchNumber = "imgBatch"
			case clientData
			case transId
		}
		
		/// returns a clone of self with the transactionId added
		func withTransaction(_ transId: String) -> ExecComplete {
			return ExecComplete(expectShowOutput: expectShowOutput, queryId: queryId, startTime: startTime, images: images, batchNumber: batchNumber, clientData: clientData, transId: transId)
		}
	}
	
	public struct EnvCreated: Codable, Hashable {
		let contextId: Int
		let transactionId: String
	}
	
	public struct PreviewInited: Codable, Hashable {
		public let previewId: Int
		public let fileId: Int
		public let errorCode: Int
		public let updateIdentifier: String
	}
	
	public struct PreviewUpdateStartedData: Codable, Hashable {
		public let previewId: Int
		public let updateIdentifier: String
		public let activeChunks: [Int]
	}

	public struct PreviewUpdated: Codable, Hashable , Equatable{
		public let previewId: Int
		public let chunkId: Int
		public let updateComplete: Bool
		public let updateIdentifier: String
		public let results: String
		
		enum CodingKeys: String, CodingKey {
			case previewId
			case chunkId
			case updateComplete = "complete"
			case updateIdentifier
			case results = "content"
		}

		public init(previewId: Int, chunkId: Int, results: String, updateIdentifier: String = "", updateComplete: Bool) {
			self.previewId = previewId
			self.chunkId = chunkId
			self.results = results
			self.updateIdentifier = updateIdentifier
			self.updateComplete = updateComplete
		}
	}
	
}

