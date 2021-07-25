//
//  AppServer.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import HeliumLogger
import Logging
import servermodel
import pgswift
import CommandLine
import FileKit
import KituraWebSocket
import NIO

enum Handlers: String {
	case info
	case auth
	case model
	case file
}

public class App {
	public enum Errors: Error {
		case invalidDataDirectory
	}
	
	let router = Router(mergeParameters: false, enableWelcomePage: false)
	let heLogger: HeliumLogger
	let logger: Logger
	internal private(set) var settings: AppSettings!
	private var dataDirURL: URL!
	internal private(set) var dao: Rc2DAO!
	private var listenPort = 8088
	private var handlers: [Handlers : BaseHandler] = [:]
	private var sessionService: SessionService!
	private var clArgs: [String]
	
	public init(_ args: [String]? = nil) throws {
		heLogger = HeliumLogger()
		heLogger.dateFormat = "HH:mm:ss.SSS"
		heLogger.format = "[(%date)] [(%type)] [(%file):(%line)] (%msg)"
//		LoggingSystem.bootstrap(heLogger.makeLogHandler)
		if let rargs = args {
			clArgs = rargs
		} else {
			clArgs = ProcessInfo.processInfo.arguments
		}
		logger = Logger(label: "rc2.app")
		logger.info("logging initialized")
	}

	private func connectToDB() -> Bool {
		do {
			logger.info("connecting to db \(settings.config.dbUser)@\(settings.config.dbHost):\(settings.config.dbPort)")
			let connection = Connection(host: settings.config.dbHost, port: "\(settings.config.dbPort)", user: settings.config.dbUser, password: settings.config.dbPassword, dbname: settings.config.dbName, sslMode: .prefer)
			try connection.open()
			dao = Rc2DAO(connection: connection)
			settings.setDAO(newDao: dao)
			return true
		} catch {
			logger.info("db connection failed: \(error)")
			return false
		}
	}

	public func postInit() throws {
		parseCommandLine()
		logger.debug("parsed cmd line")
		settings = AppSettings(dataDirURL: dataDirURL)
		// customize the json (d)encoders used
		router.encoders[.json] = { AppSettings.createJSONEncoder() }
		router.decoders[.json] = { AppSettings.createJSONDecoder() }
		// connect to database
		for i in 0..<settings.config.dbConnectAttemptCount {
			logger.debug("attempting connection \(i)")
			if connectToDB() {
				logger.debug("connection opened")
				break
			}
			sleep(UInt32(settings.config.dbConnectAttemptDelay))
		}
		guard dao != nil else { fatalError("failed to connect to db ") }
		if settings.config.enableCors {
			let cors = MyCorsHandler(logger: logger, origin: settings.config.corsOrigin)
			router.all(middleware: cors)
		}
		// auth middleware
		let mware = AuthMiddleware(settings: settings)
		router.all(middleware: [mware])
		// InfoHandler
		let info = InfoHandler(settings: settings)
		handlers[.info] = info
		info.addRoutes(router: router)
		// auth handler
		let auth = AuthHandler(settings: settings)
		handlers[.auth] = auth
		auth.addRoutes(router: router)
		// model handler
		let model = ModelHandler(settings: settings)
		handlers[.model] = model
		model.addRoutes(router: router)
		// file handler
		let files = FileHandler(settings: settings)
		handlers[.file] = files
		files.addRoutes(router: router)
		// websocket
		sessionService = SessionService(settings: settings, logger: logger, minimumReapTime: TimeInterval(settings.config.sessionReapDelay))
		WebSocket.register(service:sessionService,  onPath: "\(settings.config.urlPrefixToIgnore)/ws")
	}
	
	public func run() throws {
		do {
			let handler =  {
				self.logger.info("caught signal")
				print("caught signal")
				Kitura.stop()
			}
			let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main);
			src.setEventHandler(handler: handler)
			src.resume()
			let src2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main);
			src2.setEventHandler(handler: handler)
			src2.resume()
			try postInit()
			logger.info("listening on \(listenPort)")
			settings.set(nioGroup: Kitura.addHTTPServer(onPort: listenPort, with: router).eventLoopGroup)
			Kitura.run(exitOnFailure: true)
			logger.critical("Kitura.run exited")
		} catch {
			fatalError("error running: \(error)")
		}
	}
	
	func parseCommandLine() {
		let cli = CommandLine(arguments: clArgs)
		let dataDir = StringOption(shortFlag: "D", longFlag: "datadir", helpMessage: "Specify path to directory with data files")
		cli.addOption(dataDir)
		let portOption = IntOption(shortFlag: "p", helpMessage: "Port to listen to (defaults to 8088)")
		cli.addOption(portOption)
		do {
			try cli.parse()
			var dirPath: String?
			if dataDir.wasSet {
				dirPath = dataDir.value!
			} else {
				dirPath = FileKit.projectFolder
				if dirPath == nil {
					dirPath = ProcessInfo.processInfo.environment["RC2_DATA_DIR"]
				}
			}
			guard let actualPath = dirPath else { throw Errors.invalidDataDirectory }
			self.dataDirURL = URL(fileURLWithPath: actualPath)
			guard self.dataDirURL != nil, self.dataDirURL.hasDirectoryPath else { throw Errors.invalidDataDirectory }
			if let pvalue = portOption.value { listenPort = pvalue }
		} catch {
			cli.printUsage(error)
			exit(EX_USAGE)
		}
		
	}

	class MyCorsHandler: RouterMiddleware {
		private let logger: Logger
		private let origin: String

		init(logger: Logger, origin: String?) {
			self.logger = logger
			self.origin = origin ?? "http://localhost:9080"
		}
		func handle(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
			response.headers["Access-Control-Allow-Origin"] = origin
			response.headers["Access-Control-Allow-Methods"] = "OPTIONS, GET, POST, PUT, DELETE, HEAD"
			response.headers["Access-Control-Request-Headers"] = "Content-Type, Accept, Origin, Authorization"
			response.headers["Access-Control-Allow-Credentials"] = "true"
			next()
		}
	}
}
