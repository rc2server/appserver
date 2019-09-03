import Foundation
import Kitura

public class App {
	let router = Router()
	
	public init() throws {
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

