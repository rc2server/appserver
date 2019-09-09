//
//  InfoHandler.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import Rc2Model
import servermodel

class InfoHandler: BaseHandler {
	
	override func addRoutes(router: Router) {
		router.all("/info") { [weak self] request, response, next in
			guard let user = request.user else {
				try self?.handle(error: .invalidRequest, response: response)
				return
			}
			let bulkInfo = try self?.settings.dao.getUserInfo(user: user)
			try response.send(bulkInfo).end()
		}
	}
}
