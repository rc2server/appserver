//
//  ComputeError.swift
//  kappserver
//
//  Created by Mark Lilback on 9/13/19.
//

import Foundation

public enum ComputeError: Error {
	/// messsage didn't have the correct header
	case invalidHeader
	/// failed to connect to the compute engine server, assume can't retry connection
	case failedToConnect
	/// an error happened reading/parsing the raw data received over the network. Should be very rare, unless hack attempt.
	case failedToReadMessage
	/// failed to write data to network. Should be very rare.
	case failedToWrite
	/// asked to send data of length zero
	case sendingEmptyMessage
	/// a required field was missing from the server. Should never happen. Input was ignored
	case requiredFieldMissing
	/// the input passed to the coder was not in the propper format
	case invalidInput
	/// failed because not connected
	case notConnected
	/// Kubernetes failed to launch too many times
	case tooManyCrashes
	/// Network layer error
	case network
	/// some other type of error
	case unknown
}
