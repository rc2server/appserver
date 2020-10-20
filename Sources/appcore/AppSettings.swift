//
//  AppSettings.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import servermodel
import Logging
import KituraContracts
import SwiftJWT

public class AppSettings: BodyEncoder, BodyDecoder {
	let logger = Logger(label: "AppSettings")
	/// URL for a directory that contains resources used by the application.
	public let dataDirURL: URL
	/// The data access object for retrieving objects from the database.
	public private(set) var dao: Rc2DAO!
	/// Constants read from "config.json" in `dataDirURL`.
	public let config: AppConfiguration
	/// the encoder used, implementation detail.
	private let encoder: JSONEncoder
	/// the decoder used, implementation detail.
	private let decoder: JSONDecoder
	let jwtSigner:  JWTSigner
	let jwtVerifier: JWTVerifier

	/// Create a JSONEncoder with the configuration used by the app
	///
	/// - Returns: a new JSONEncoder
	public static func createJSONEncoder() -> JSONEncoder {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .secondsSince1970
		encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
		return encoder
	}
	
	/// Creates a JSONDecoder with the configuration of the app
	///
	/// - Returns: a new JSONDecoder
	public static func createJSONDecoder() -> JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .secondsSince1970
		decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
		return decoder
	}
	
	private static func loadConfig(from data: Data, with decoder: JSONDecoder) throws -> AppConfiguration {
		return try decoder.decode(AppConfiguration.self, from: data)
	}
	
	/// Initializes from parameters and `config.json`
	/// Initializes from parameters and `config.json`
	///
	/// - Parameter dataDirURL: URL containing resources used by the application.
	/// - Parameter configData: JSON data for configuration. If nil, will read it from dataDirURL.
	/// - Parameter dao: The Data Access Object used to retrieve model objects from the database.
	init(dataDirURL inURL: URL, configData: Data? = nil) {
		logger.info("init called with \(inURL.path)")
		precondition(inURL.isFileURL && inURL.path.count > 2, "url = \(inURL.path)")
		self.dataDirURL = inURL
		decoder = AppSettings.createJSONDecoder()
		encoder = AppSettings.createJSONEncoder()
		
		let configUrl: URL
		do {
			let configFileName = ProcessInfo.processInfo.environment["RC2_CONFIG_FILE_NAME"] ?? "config.json"
			configUrl = inURL.appendingPathComponent(configFileName)
			let data = configData != nil ? configData! : try Data(contentsOf: configUrl)
			config = try AppSettings.loadConfig(from: data, with: decoder)
		} catch {
			fatalError("failed to load config file \(configUrl.absoluteString) \(error)")
		}

		let secretData = config.jwtHmacSecret.data(using: .utf8, allowLossyConversion: true)!
		jwtSigner = JWTSigner.hs512(key: secretData)
		jwtVerifier = JWTVerifier.hs512(key: secretData)
	}
	
	/// Parses an Authorization header (Bearer <token>) and extracts the LoginToken with userId
	///
	/// - Parameter string: The value of an Authorization header
	/// - Returns: the embedded LoginToken, or nil if there is an error
	public func loginToken(from string: String?) -> LoginToken? {
		guard let rawHeader = string else { return nil }
		//extract the bearer token
		let prefix = "Bearer "
		let tokenIndex = rawHeader.index(rawHeader.startIndex, offsetBy: prefix.count)
		let tokenStr = String(rawHeader[tokenIndex...])

		let verified = JWT<LoginToken>.verify(tokenStr, using: jwtVerifier)
		guard verified else { return nil }
		guard let token = try? JWT<LoginToken>(jwtString: tokenStr, verifier: jwtVerifier),
			dao.tokenDAO.validate(token: token.claims),
			dao.tokenDAO.validate(token: token.claims)
		else {
			logger.debug("failed to validate extracted token")
			return nil
		}
		return token.claims
	}
	
	func setDAO(newDao: Rc2DAO) {
		guard dao == nil else { return }
		dao = newDao
	}

	/// implementation for Kitura so we can configure the encoder
	public func encode<T : Encodable>(_ value: T) throws -> Data {
		return try encoder.encode(value)
	}
	
	/// implementation for Kitura so we can configure the decoder
	public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		return try decoder.decode(type, from:  data)
	}
}


/// Basic information used throughout the application. Meant to be read from config file.
public struct AppConfiguration: Decodable {
	/// The database host name to connect to. Defaults to "dbserver".
	public let dbHost: String
	/// The database port to connect to. Defaults to 5432.
	public let dbPort: UInt16
	/// The name of the user to connect as. Defaults to "rc2".
	public let dbUser: String
	/// The name of the database to use. Defaults to "rc2".
	public let dbName: String
	/// The password to connect to the database. Defaults to "rc2".
	public let dbPassword: String
	/// the number of times to try to connect before failing. Defaults to 3
	public let dbConnectAttemptCount: Int
	/// the number of seconds to wait between connection attempts. Defaults to 4
	public let dbConnectAttemptDelay: Int
	/// The host name of the compute engine. Defaults to "compute".
	public let computeHost: String
	/// The port of the compute engine. Defaults to 7714.
	public let computePort: UInt16
	/// Seconds to wait for a connection to the compute engine to open. Defaults to 4. -1 means no timeout.
	public let computeTimeout: Double
	/// The db host name to send to the compute server (which because of dns can be different)
	public let computeDbHost: String
	/// The db port to send to the compute server. Is a string because that's how compute engine works with it. Defaults to 5432
	public let computeDbPort: String
	/// The size of the read buffer for messages from the compute engine. Must be between 512 KB and 20 MB. Defaults to 1 MB. should be larger than maximumWebSocketFileSizeKB
	public let computeReadBufferSize: Int
	/// The largest amount of file data to return over the websocket. Anything higher should be fetched via REST. In KB. Defaults to 600.
	public let maximumWebSocketFileSizeKB: Int
	/// the secret used with HMAC encoding in the authentication process. defaults to some gibberish that should not be used since it it avaiable in the source code.
	public let jwtHmacSecret: String
	/// The initial log level. Defaults to info
//	public let initialLogLevel: LogLevel
	/// Path to store log files
	public let logfilePath: String
	/// URL prefix to ignore when parsing urls (e.g. "/v1" or "/dev")
	public let urlPrefixToIgnore: String
	/// Should the compute engine be launched via Kubernetes, or connected to via computeHost/computePort settings
	public let computeViaK8s: Bool
	/// Path where stencil templates for k8s are found. Defaults to "/rc2/k8s-templates"
	public let k8sStencilPath: String
	/// The Docker image to use for the compute pods
	public let computeImage: String
	/// How long a session be allowed to stay im memory without any users before it is reaped. in seconds. Defaults to 300.
	public let sessionReapDelay: Int
	/// How long to wait for compute pod to complete startup after confirmation message. Defaults to 2000 milliseconds
	public let computeStartupDelay: Int
	
	enum CodingKeys: String, CodingKey {
		case dbHost
		case dbPort
		case dbUser
		case dbName
		case dbPassword
		case dbConnectAttemptCount
		case dbConnectAttemptDelay
		case computeHost
		case computePort
		case computeTimeout
		case computeDbHost
		case computeDbPort
		case maximumWebSocketFileSizeKB
		case jwtHmacSecret
		case computeReadBufferSize
		case logFilePath
//		case initialLogLevel
		case urlPrefixToIgnore
		case computeViaK8s
		case k8sStencilPath
		case computeImage
		case sessionReapDelay
		case computeStartupDelay
	}
	
	/// Initializes from serialization.
	///
	/// - Parameter from: The decoder to deserialize from.
	public init(from cdecoder: Decoder) throws {
		let container = try cdecoder.container(keyedBy: CodingKeys.self)
		logfilePath = try container.decodeIfPresent(String.self, forKey: .logFilePath) ?? "/tmp/appserver.log"
		dbHost = try container.decodeIfPresent(String.self, forKey: .dbHost) ?? "dbserver"
		dbUser = try container.decodeIfPresent(String.self, forKey: .dbUser) ?? "rc2"
		dbName = try container.decodeIfPresent(String.self, forKey: .dbName) ?? "rc2"
		dbPassword = try container.decodeIfPresent(String.self, forKey: .dbPassword) ?? "rc2"
		dbPort = try container.decodeIfPresent(UInt16.self, forKey: .dbPort) ?? 5432
		dbConnectAttemptCount = try container.decodeIfPresent(Int.self, forKey: .dbConnectAttemptCount) ?? 3
		dbConnectAttemptDelay = try container.decodeIfPresent(Int.self, forKey: .dbConnectAttemptDelay) ?? 4
		computeHost = try container.decodeIfPresent(String.self, forKey: .computeHost) ?? "compute"
		computePort = try container.decodeIfPresent(UInt16.self, forKey: .computePort) ?? 7714
		computeTimeout = try container.decodeIfPresent(Double.self, forKey: .computeTimeout) ?? 4.0
		urlPrefixToIgnore = try container.decodeIfPresent(String.self, forKey: .urlPrefixToIgnore) ?? ""
		jwtHmacSecret = try container.decodeIfPresent(String.self, forKey: .jwtHmacSecret) ?? "dsgsg89sdfgs32"
		computeViaK8s = try container.decodeIfPresent(Bool.self, forKey: .computeViaK8s) ?? false
		k8sStencilPath = try container.decodeIfPresent(String.self, forKey: .k8sStencilPath) ?? "/rc2/k8s-templates"
		computeImage = try container.decodeIfPresent(String.self, forKey: .computeImage) ?? "docker.rc2.io/compute:latest"
		computeDbPort = try container.decodeIfPresent(String.self, forKey: .computeDbPort) ?? "5432"
		let cdb = try container.decodeIfPresent(String.self, forKey: .computeDbHost)
		computeDbHost = cdb == nil ? dbHost : cdb!
		computeStartupDelay = try container.decodeIfPresent(Int.self, forKey: .computeStartupDelay) ?? 2000
		// must be > 256 KB, less than 20 MB
		if let desiredBufSize = try container.decodeIfPresent(Int.self, forKey: .computeReadBufferSize),
			desiredBufSize > 256, desiredBufSize < 20 * 1024 * 1024 {
			computeReadBufferSize = desiredBufSize
		} else {
			computeReadBufferSize = 1024 * 1024
		}
		// default to 600 KB. Some kind of issues with sending messages larger than UInt16.max
		if let desiredSize = try container.decodeIfPresent(Int.self, forKey: .maximumWebSocketFileSizeKB),
			desiredSize <= 600, desiredSize > 0
		{
			maximumWebSocketFileSizeKB = desiredSize
		} else {
			maximumWebSocketFileSizeKB = 600
		}
		if let desiredReapTime = try container.decodeIfPresent(Int.self, forKey: .sessionReapDelay), desiredReapTime >= 0, desiredReapTime < 3600
		{
			sessionReapDelay = desiredReapTime
		} else {
			sessionReapDelay = 300
		}
//		if let levelStr = try container.decodeIfPresent(Int.self, forKey: .initialLogLevel), let level = LogLevel(rawValue: levelStr) {
//			initialLogLevel = level
//		} else {
//			initialLogLevel = .info
//		}
	}
}
