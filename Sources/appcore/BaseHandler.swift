//
//  BaseHandler.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import Rc2Model

let jsonMediaType = MediaType.json

class BaseHandler {
	let settings: AppSettings
	
	init(settings: AppSettings) {
		self.settings = settings
	}
	
	/// add routes that are handled. subclasses must override to be useful
	///
	/// - Parameter router: the router to add routes to
	func addRoutes(router: Router) {
	}
	
	func handle(status: HTTPStatusCode, content: String? = nil, response: RouterResponse) throws {
		response.status(status)
		response.send(content)
		try response.end()
	}
	
	/// handles an error by sending a response. Should be called by subclasses to report errors
	///
	/// - Parameters:
	///   - error: The error to report
	///   - response: The response to report the error to
	/// - Throws: any errors from response.send().end()
	func handle(error: SessionError, response: RouterResponse, statusCode: HTTPStatusCode = .notFound) throws {
		response.status(statusCode)
		response.headers.setType(jsonMediaType.description)
		try response.send(error).end()
	}

}
