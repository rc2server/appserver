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

public class AppSettings: BodyEncoder, BodyDecoder {
	let logger = Logger(label: "AppSettings")
	/// settings for this application
	private var settings: AppSettings!
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
	init(dataDirURL: URL, configData: Data? = nil) {
		logger.info("settings inited with: \(dataDirURL.absoluteString)")
		self.dataDirURL = dataDirURL
		decoder = AppSettings.createJSONDecoder()
		encoder = AppSettings.createJSONEncoder()
		
		var configUrl: URL!
		do {
			configUrl = dataDirURL.appendingPathComponent("config.json")
			let data = configData != nil ? configData! : try Data(contentsOf: configUrl)
			config = try AppSettings.loadConfig(from: data, with: decoder)
		} catch {
			fatalError("failed to load config file \(configUrl.absoluteString) \(error)")
		}
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
	/// The host name of the compute engine. Defaults to "compute".
	public let computeHost: String
	/// The port of the compute engine. Defaults to 7714.
	public let computePort: UInt16
	/// Seconds to wait for a connection to the compute engine to open. Defaults to 4. -1 means no timeout.
	public let computeTimeout: Double
	/// The db host name to send to the compute server (which because of dns can be different)
	public let computeDbHost: String
	/// The largest amount of file data to return over the websocket. Anything higher should be fetched via REST. In KB
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
		case computeHost
		case computePort
		case computeTimeout
		case computeDbHost
		case maximumWebSocketFileSizeKB
		case jwtHmacSecret
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
		dbPort = try container.decodeIfPresent(UInt16.self, forKey: .dbPort) ?? 8432
		computeHost = try container.decodeIfPresent(String.self, forKey: .computeHost) ?? "compute"
		computePort = try container.decodeIfPresent(UInt16.self, forKey: .computePort) ?? 7714
		computeTimeout = try container.decodeIfPresent(Double.self, forKey: .computeTimeout) ?? 4.0
		urlPrefixToIgnore = try container.decodeIfPresent(String.self, forKey: .urlPrefixToIgnore) ?? ""
		jwtHmacSecret = try container.decodeIfPresent(String.self, forKey: .jwtHmacSecret) ?? "dsgsg89sdfgs32"
		computeViaK8s = try container.decodeIfPresent(Bool.self, forKey: .computeViaK8s) ?? false
		k8sStencilPath = try container.decodeIfPresent(String.self, forKey: .k8sStencilPath) ?? "/rc2/k8s-templates"
		computeImage = try container.decodeIfPresent(String.self, forKey: .computeImage) ?? "docker.rc2.io/compute:latest"
		let cdb = try container.decodeIfPresent(String.self, forKey: .computeDbHost)
		computeDbHost = cdb == nil ? dbHost : cdb!
		computeStartupDelay = try container.decodeIfPresent(Int.self, forKey: .computeStartupDelay) ?? 2000
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
