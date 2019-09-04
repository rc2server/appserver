//
//  DBConnection.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation
import Dispatch
import pgswift

/// These protocols exist to hide FileChangeMomitor from any reference to PostgreSQL. This is necessary to allow unit testing, and decoupling is always a good thing. Subclassing doesn't work since everything in PostgreSQL is final.

public protocol DBNotification {
	var pid: Int { get }
	var channel: String { get }
	var payload: String? { get }
}

extension PGNotification: DBNotification {}

public protocol DBConnection {
	func execute(query: String, values: [QueryParameter]) throws -> PGResult
//	func execute(_ query: String, _ binds: [Bind]) throws -> Node
	func close() throws
	func makeListenDispatchSource(toChannel channel: String, queue: DispatchQueue, callback: @escaping (_ note: DBNotification?, _ err: Error?) -> Void) throws -> DispatchSourceRead
}

public struct MockDBNotification: DBNotification {
	public let pid: Int
	public let channel: String
	public let payload: String?
}

public class MockDBConnection: DBConnection {
	public enum MockDBError: String, Error {
		case unimplemented
	}
	public func execute(query: String, values: [QueryParameter]) throws -> PGResult
	{
		throw MockDBError.unimplemented
	}
	
	public func close() throws {
		throw MockDBError.unimplemented
	}
	
	public func makeListenDispatchSource(toChannel channel: String, queue: DispatchQueue, callback: @escaping (DBNotification?, Error?) -> Void) throws -> DispatchSourceRead
	{
		throw MockDBError.unimplemented
	}
}

extension Connection: DBConnection {
	public func execute(query: String, values: [QueryParameter] = []) throws -> PGResult {
		return try execute(query: query, values: values)
	}
	
	public func makeListenDispatchSource(toChannel channel: String, queue: DispatchQueue, callback: @escaping (_ note: DBNotification?, _ err: Error?) -> Void) throws -> DispatchSourceRead
	{
		let castCallback = callback as (DBNotification?, Error?) -> Void
		return try listen(toChannel: channel, queue: queue, callback: castCallback)
	}
}
