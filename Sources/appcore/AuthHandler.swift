//
//  AuthHandler.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import KituraNet
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
	let rfcDateFormat = DateFormatter()


	override init(settings: AppSettings) {
		tokenDao = settings.dao.createTokenDAO()
		let secretData = settings.config.jwtHmacSecret.data(using: .utf8, allowLossyConversion: true)!
		jwtSigner = JWTSigner.hs512(key: secretData)
		jwtVerifier = JWTVerifier.hs512(key: secretData)
		rfcDateFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
		super.init(settings: settings)
	}
	
	override func addRoutes(router: Router) {
		let prefix = settings.config.urlPrefixToIgnore
		router.post("\(prefix)/login") { [weak self] request, response, next in
			self?.loginHandler(request: request, response: response, handler: next)
		}
		router.delete("\(prefix)/login") { [weak self] request, response, next in
			self?.logoutHandler(request: request, response: response, next: next)
		}
	}
	
	func loginHandler(request: RouterRequest, response: RouterResponse, handler: @escaping () -> Void)
	{
		do {
			let params = try request.read(as: LoginParams.self)
			logger.debug("login for \(params.login)")
			guard let user = try settings.dao.getUser(login: params.login, password: params.password)
			else {
				logger.warning("invalid login for \(params.login)")
				let err = SessionError.invalidLogin
				response.status(.unauthorized)
				try response.send(err).end()
				return
			}
			let token = try tokenDao.createToken(user: user)
			var jwt = JWT(claims: token)
			let signedJwt = try jwt.sign(using: jwtSigner) 
			if let ckname = settings.config.authCookieName {
				let secure = (request.urlURL.scheme?.lowercased() ?? "") == "https"
				let secureStr = secure ? "; Secure" : ""
				let cookiestr = "\(ckname)=\(signedJwt); HttpOnly; SameSite=Strict\(secureStr)"
				response.headers.append("Set-Cookie", value: cookiestr)
			}
			response.send(LoginResponse(token: signedJwt))
			handler()
		} catch {
			do {
				logger.warning("error processing login: \(error)")
				try handle(error: .invalidLogin, response: response, statusCode: .unprocessableEntity)
			} catch {
				logger.error("error handling an error")
				response.status(.internalServerError)
				do { try response.end() } catch { logger.critical("error handling error: \(error)") }
			}
		}
	}
	
	func logoutHandler(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void)
	{
		do {
			response.status(.accepted)
			let authHeader = request.headers[HTTPHeaders.authorization]
			let cdict = Dictionary(uniqueKeysWithValues: request.cookies.map {key,value in (value.name, value.value)})
			guard let token = settings.loginToken(from: authHeader, cookies: cdict) else {
				try response.end()
				return
			}
			try tokenDao.invalidate(token: token)
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
	public static let wspaceId = "Rc2-WorkspaceId"
}
