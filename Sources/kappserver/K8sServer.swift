//
//  K8sServer.swift
//  kappserver
//
//  Created by Mark Lilback on 9/11/19.
//

import Foundation
import BrightFutures

enum K8sError: Error {
	case connectionFailed
	case invalidResponse
	case impossibleSituation
	case invalidConfiguration
}

class K8sServer {
//	private let token: String
	private let config: AppConfiguration
	
	init(config: AppConfiguration) throws {
		self.config = config
	}
	
	/// Fires off a job to kubernetes to start a compute instance for the specified workspace
	/// - Parameter wspaceId: the id of the workspace the compute engine will be using
	/// - Parameter sessionId: the unique, per-session id this compute instance is for
	/// - Returns: future is always true if no error happend
	/// FIXME: need to delay return value until the compute container is running and accepting connections
	func launchCompute(wspaceId: Int, sessionId: Int) -> Future<Bool, K8sError> {
		// TODO: really implement
		return Future<Bool, K8sError>(value: false, delay: .seconds(2))
	}
}
