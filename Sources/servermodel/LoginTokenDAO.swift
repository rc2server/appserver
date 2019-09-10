//
//  LoginTokenDAO.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation
import pgswift
import Rc2Model
import Logging
import SwiftJWT

/// Simple wrapper around contents stored in the authentication token
public struct LoginToken: Codable, Claims {
	public let id: Int
	public let userId: Int
	
	public init?(_ dict: [String: Any]) {
		guard let inId = dict["token"] as? Int, let inUser = dict["user"] as? Int else { return nil }
		id = inId
		userId = inUser
	}
	
	public init(_ inId: Int, _ inUser: Int)  {
		id = inId
		userId = inUser
	}
	
	public var contents: [String: Any] { return ["token": id, "user": userId] }
}

/// Wrapper for database actions related to login tokens
public final class LoginTokenDAO {
	private let pgdb: Connection
	
	/// create a DAO
	///
	/// - Parameter connection: the database to query
	public init(connection: Connection) {
		pgdb = connection
	}
	
	/// create a new login token for a user
	///
	/// - Parameter user: the user to create a token for
	/// - Returns: a new token
	/// - Throws: a .dbError if the sql command fails
	public func createToken(user: User) throws -> LoginToken {
		do {
			let result = try pgdb.execute(query: "insert into logintoken (userId) values ($1) returning id", parameters: [QueryParameter(type: .int8, value: user.id, connection: pgdb)])
			guard result.wasSuccessful, result.rowCount == 1 else { throw ModelError.dbError }
			guard let tokenId: Int = try result.getValue(row: 0, column: 0)
				else { throw ModelError.dbError }
			return LoginToken(tokenId, user.id)
		} catch {
			logger.error("failed to insert logintoken \(error)")
			throw ModelError.dbError
		}
	}
	
	/// checks the database to make sure a token is still valid
	///
	/// - Parameter token: the token to check
	/// - Returns: true if the token is still valid
	public func validate(token: LoginToken) -> Bool {
		do {
			let params: [QueryParameter] = [ try QueryParameter(type: .int8, value: token.id, connection: pgdb), try QueryParameter(type: .int8, value: token.userId, connection: pgdb) ]
			let result = try? pgdb.execute(query: "select * from logintoken where id = $1 and userId = $2 and valid = true", parameters: params)
			guard let res = result, res.wasSuccessful, res.rowCount == 1
				else { return false }
			return true
		} catch {
			logger.warning("validateLoginToken failed: \(error)")
			return false
		}
	}
	
	/// invalidate a token so it can't be used again
	///
	/// - Parameter token: the token to invalidate
	/// - Throws: errors from executing sql
	public func invalidate(token: LoginToken) throws {
		let query = "update logintoken set valid = false where id = $1 and userId = $2"
		let params: [QueryParameter] = [ try QueryParameter(type: .int8, value: token.id, connection: pgdb), try QueryParameter(type: .int8, value: token.userId, connection: pgdb) ]
		let results = try pgdb.execute(query: query, parameters: params)
		guard results.wasSuccessful else {
			logger.warning("failed to invalidate token: \(results.errorMessage)")
			throw ModelError.dbError
		}
	}
}
