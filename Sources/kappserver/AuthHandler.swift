//
//  AuthHandler.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import servermodel
import Rc2Model
import Logging
import SwiftJWT

// FIXME: remove ! casts

class AuthHandler: BaseHandler {
	let logger = Logger(label: "rc2.appserver.AuthHandler")
	let tokenDao: LoginTokenDAO
	let jwtSigner:  JWTSigner
	let jwtVerifier: JWTVerifier

	override init(settings: AppSettings) {
		tokenDao = settings.dao.createTokenDAO()
		let secretData = settings.config.jwtHmacSecret.data(using: .utf8, allowLossyConversion: true)!
		jwtSigner = JWTSigner.hs512(key: secretData)
		jwtVerifier = JWTVerifier.hs512(key: secretData)
		super.init(settings: settings)
	}
	
	override func addRoutes(router: Router) {
		router.post("/login") { [weak self] request, response, next in
			self?.loginHandler(request: request, response: response, handler: next)
		}
		router.delete("/login") { [weak self] request, response, next in
			self?.logoutHandler(request: request, response: response, next: next)
		}
	}
	
	func loginHandler(request: RouterRequest, response: RouterResponse, handler: @escaping () -> Void)
	{
		do {
			logger.info("login called")
			let params = try request.read(as: LoginParams.self)
			logger.info("login for \(params.login)")
			guard let user = try settings.dao.getUser(login: params.login, password: params.password)
			else {
				logger.info("invalid login for \(params.login)")
				response.status(.unauthorized)
				try response.send("invalid login or password").end()
				return
			}
			let token = try tokenDao.createToken(user: user)
			var jwt = JWT(claims: token)
			let signedJwt = try jwt.sign(using: jwtSigner)
			response.send(LoginResponse(token: signedJwt))
			handler()
		} catch {
			do {
				try handle(error: .unknown, response: response)
			} catch {
				logger.error("error handling an error")
				response.status(.internalServerError)
				do { try response.end() } catch { logger.critical("error handling error: \(error)") }
			}
		}
	}
	
	func logoutHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)
	{
		var user: User?
		do {
			response.status(.accepted)
			guard let tokenStr = HTTPHeaders.extractAuthToken(request: request) else {
				try response.end()
				return
			}
			let verified = JWT<LoginToken>.verify(tokenStr, using: jwtVerifier)
			guard verified else {
				try response.end()
				return
			}
			let newToken = try JWT<LoginToken>(jwtString: tokenStr, verifier: jwtVerifier)
			user = try settings.dao.getUser(id: newToken.claims.userId)
			guard  user != nil else {
				try response.end()
				return
			}
			logger.debug("logout for \(user?.login ?? "unknown")")
			
			try tokenDao.invalidate(token: newToken.claims)

			response.status(.accepted)
			try response.end()
		} catch {
			logger.warning("error in logout: \(error)")
			next()
		}
	}
	
	struct LoginParams: Codable {
		let login: String
		let password: String
	}
	
	struct LoginResponse: Codable {
		let token: String
	}
}

/// static constants and functions for working with HTTP headers
public struct HTTPHeaders {
	/// Authorization header
	public static let authorization = "Authorization"

	/// Parses authorization header and returns the token found there
	///
	/// - Parameter request: the request with the authorization header
	/// - Returns: the token, or nil if not found
	public static func extractAuthToken(request: RouterRequest) -> String? {
		guard let rawHeader = request.headers[HTTPHeaders.authorization] else { return nil }
		//extract the bearer token
		let prefix = "Bearer "
		let tokenIndex = rawHeader.index(rawHeader.startIndex, offsetBy: prefix.count)
		let token = String(rawHeader[tokenIndex...])
		return token
	}
}
