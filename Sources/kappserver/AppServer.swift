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

enum Handlers: String {
	case info
}

public class App {
	public enum Errors: Error {
		case invalidDataDirectory
	}
	
	let router = Router()
	let logger = HeliumLogger()
	private var settings: AppSettings!
	private var dataDirURL: URL!
	private var dao: Rc2DAO!
	private var listenPort = 8088
	private var handlers: [Handlers : BaseHandler] = [:]
	
	public init() throws {
		LoggingSystem.bootstrap(logger.makeLogHandler)
	}
	
	public func postInit() throws {
		parseCommandLine()
		settings = AppSettings(dataDirURL: dataDirURL)
		// customize the json (d)encoders used
		router.encoders[.json] = { AppSettings.createJSONEncoder() }
		router.decoders[.json] = { AppSettings.createJSONDecoder() }
		// connect to database
		let connection = Connection(host: settings.config.dbHost, port: "\(settings.config.dbPort)", user: settings.config.dbUser, password: settings.config.dbPassword, dbname: settings.config.dbName, sslMode: .prefer)
		dao = Rc2DAO(connection: connection)
		settings.setDAO(newDao: dao)
		// InfoHandler
		let info = InfoHandler(settings: settings)
		handlers[.info] = info
		info.addRoutes(router: router)
		
	}
	
	public func run() throws {
		try postInit()
		Kitura.addHTTPServer(onPort: 3472, with: router)
		Kitura.run()
	}
	
	func parseCommandLine() {
		let cli = CommandLine()
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
				dirPath = ProcessInfo.processInfo.environment["RC2_DATA_DIR"]
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
