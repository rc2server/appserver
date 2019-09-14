//
//  ComputeError.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation

public enum ComputeError: Error {
	case invalidHeader
	/// failed to connect to the monolithic server, assume can't retry connection
	case failedToConnect
	case failedToReadMessage
	case failedToWrite
	case invalidFormat
	/// the input passed to the coder was not in the propper format
	case invalidInput
	case notConnected
	case tooManyCrashes
	case unknown
}
