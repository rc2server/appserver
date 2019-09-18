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
	let heLogger = HeliumLogger()
	let logger = Logger(label: "rc2.app")
	internal private(set) var settings: AppSettings!
	private var dataDirURL: URL!
	internal private(set) var dao: Rc2DAO!
	private var listenPort = 8088
	private var handlers: [Handlers : BaseHandler] = [:]
	private var sessionService: SessionService!
	private var clArgs: [String]
	
	public init(_ args: [String]? = nil) throws {
		LoggingSystem.bootstrap(heLogger.makeLogHandler)
		if let rargs = args {
			clArgs = rargs
		} else {
			clArgs = ProcessInfo.processInfo.arguments
		}
	}
	
	public func postInit() throws {
		parseCommandLine()
		settings = AppSettings(dataDirURL: dataDirURL)
		// customize the json (d)encoders used
		router.encoders[.json] = { AppSettings.createJSONEncoder() }
		router.decoders[.json] = { AppSettings.createJSONDecoder() }
		// connect to database
		let connection = Connection(host: settings.config.dbHost, port: "\(settings.config.dbPort)", user: settings.config.dbUser, password: settings.config.dbPassword, dbname: settings.config.dbName, sslMode: .prefer)
		try connection.open()
		dao = Rc2DAO(connection: connection)
		settings.setDAO(newDao: dao)
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
		sessionService = SessionService(settings: settings, logger: logger)
		WebSocket.register(service:sessionService,  onPath: "\(settings.config.urlPrefixToIgnore)/ws/:wsId")
		WebSocket.register(service:sessionService,  onPath: "\(settings.config.urlPrefixToIgnore)/ws")
	}
	
	public func run() throws {
		do {
			try postInit()
			Kitura.addHTTPServer(onPort: listenPort, with: router)
			logger.info("listening on \(listenPort)")
			Kitura.run(exitOnFailure: false)
			print("finished running")
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
			dataDirURL = URL(fileURLWithPath: actualPath)
			guard dataDirURL.hasDirectoryPath else { throw Errors.invalidDataDirectory }
			if let pvalue = portOption.value { listenPort = pvalue }
		} catch {
			cli.printUsage(error)
			exit(EX_USAGE)
		}
		
	}
}
