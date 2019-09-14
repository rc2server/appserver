//
//  AuthMiddleware.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import Logging
import servermodel
import SwiftJWT

class AuthMiddleware: RouterMiddleware {
	let logger = Logger(label: "rc2.AuthMiddleware")
	private let settings: AppSettings
	let jwtSigner:  JWTSigner
	let jwtVerifier: JWTVerifier
	let tokenDao: LoginTokenDAO!

	init(settings: AppSettings) {
		self.settings = settings
		tokenDao = settings.dao.createTokenDAO()
		let secretData = settings.config.jwtHmacSecret.data(using: .utf8, allowLossyConversion: true)!
		jwtSigner = JWTSigner.hs512(key: secretData)
		jwtVerifier = JWTVerifier.hs512(key: secretData)
	}
	
	func handle(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		if request.parsedURL.path ?? "" == "/login" {
			next()
			return
		}
		do {
			logger.info("filtering \(request.urlURL.path)")
			guard let tokenStr = HTTPHeaders.extractAuthToken(request: request) else {
				try handleUnauthorized(response: response)
				return
			}
			let verified = JWT<LoginToken>.verify(tokenStr, using: jwtVerifier)
			guard verified else { try handleUnauthorized(response: response); return }
			let newToken = try JWT<LoginToken>(jwtString: tokenStr, verifier: jwtVerifier)
			guard tokenDao.validate(token: newToken.claims)
				else { try handleUnauthorized(response: response); return }
			let user = try settings.dao.getUser(id: newToken.claims.userId)
			request.user = user
			next()
			return
		} catch ModelError.notFound {
			logger.info("failed to find user from token")
		} catch {
			logger.info("unknown error : \(error)")
		}
		do {
			try handleUnauthorized(response: response)
		} catch {
			logger.critical("error handeling error: \(error)")
		}
	}
	
	func handleUnauthorized(response: RouterResponse) throws {
		response.status(.unauthorized)
		try response.end()
	}
}
