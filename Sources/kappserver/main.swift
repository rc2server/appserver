import appcore

do {
	let server = try App()
	try server.run()
} catch {
	print("error thrown running app: \(error)")
}

