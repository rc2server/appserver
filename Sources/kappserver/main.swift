import Foundation
import Kitura
import HeliumLogger
import Logging

public class App {
	let router = Router()
	let logger = HeliumLogger()
	
	public init() throws {
		LoggingSystem.bootstrap(logger.makeLogHandler)
	}
	
	public func postInit() throws {
	
	}
	
	public func run() throws {
		try postInit()
		Kitura.addHTTPServer(onPort: 3472, with: router)
		Kitura.run()
	}
}

do {
	let server = try App()
	try server.run()
} catch {
	print("error thrown running app: \(error)")
}

