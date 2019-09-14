//
//  ComputeResponse.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation
import Rc2Model

/// responses that can be returned by the comppute engine
public enum ComputeResponse: Equatable {

	case open(Open)
	case help(Help)
	case variableValue(VariableValue)
	case variableUpdate(VariableUpdate)
	case error(Error)
	case results(Results)
	case showOutput(ShowOutput)
	case execComplete(ExecComplete)
	
	init(messageType: String, jsonData: Data, decoder: JSONDecoder) throws {
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
			let rsp = try decoder.decode(VariableUpdate.self, from: jsonData)
			self = .variableUpdate(rsp)
		case "variablevalue":
			let rsp = try decoder.decode(VariableValue.self, from: jsonData)
			self = .variableValue(rsp)
		case "help":
			let rsp = try decoder.decode(Help.self, from: jsonData)
			self = .help(rsp)
		case "error":
			let rsp = try decoder.decode(Error.self, from: jsonData)
			self = .error(rsp)
		default:
			throw ComputeError.invalidInput
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
		/// the start if one was passed in the request, otherwise an empty string
		let startTime: String
		/// any client data that was passed in the request
		let clientData: [String : String]?
	}

	/// response frpm a list variables command, also sent when there are changes if the client is watching for changes
	public struct VariableUpdate: Decodable, Equatable {
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
	}

	/// response when an error occured
	public struct Error: Codable, Hashable {
		/// the error code
		let code: Int
		/// details of the error, for logging not display to user
		let details: String
		/// queryId if one accompanied the request
		let queryId: Int?
		/// local transactionId
		let transId: String?
		
		enum CodingKeys: String, CodingKey {
			case code = "errorCode"
			case details = "errorDetails"
			case queryId
			case transId
		}
		
		func withTransactionId(_ transId: String) -> Error {
			return Error(code: code, details: details, queryId: queryId, transId: transId)
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

	public struct ExecComplete: Decodable, Hashable {
		let expectShowOutput: Bool
		let queryId: Int
		let startTime: String
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
}
