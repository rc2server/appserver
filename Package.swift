// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kappserver",
	platforms: [
		.macOS(.v10_14)
	],
    dependencies: [
		.package(name: "Rc2Model", url: "https://github.com/rc2server/appmodelSwift.git", from: "0.2.6"),
        .package(url: "https://github.com/Kitura/Kitura.git", from: "2.9.0"),
        .package(name: "KituraWebSocket", url: "https://github.com/Kitura/Kitura-WebSocket-NIO.git", from: "2.1.200"),
		.package(name: "SwiftJWT", url: "https://github.com/Kitura/Swift-JWT.git", from: "3.5.3"),
		.package(name: "Socket", url: "https://github.com/Kitura/BlueSocket.git", from: "1.0.0"),
		.package(url: "https://github.com/rc2server/CommandLine.git", from: "3.0.1"),
		.package(name: "swift-log", url: "https://github.com/apple/swift-log.git", from: "1.1.1"),
		.package(url: "https://github.com/Kitura/HeliumLogger.git", from: "1.9.2"),
		.package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.1"),
		.package(url: "https://github.com/Kitura/FileKit.git", from: "0.0.2"),
        .package(url: "https://github.com/mlilback/pgswift.git", from: "0.1.0"),
		.package(url: "https://github.com/Thomvis/BrightFutures.git", from: "8.0.1"),
		.package(url: "https://github.com/ianpartridge/swift-backtrace.git", from: "1.1.1"),
		.package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
		.package(url: "https://github.com/mlilback/SwiftyJSON.git", .branch("master"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "kappserver",
			dependencies: [
				"appcore", 
				.product(name: "Backtrace", package: "swift-backtrace")]),
		.target(
			name: "appcore",
			dependencies: ["servermodel", "Kitura", 
			.product(name: "Kitura-WebSocket", package: "KituraWebSocket"),
			 "Rc2Model", "pgswift", "HeliumLogger", 
			 .product(name: "Logging", package: "swift-log"), 
			 "CommandLine", "SwiftJWT", "Zip", "FileKit", "Socket", "BrightFutures"]),
        .target(
        	name: "servermodel",
        	dependencies: ["Rc2Model", "pgswift", 
			 .product(name: "Logging", package: "swift-log"), "SwiftJWT"]),
        .testTarget(
            name: "kappserverTests",
            dependencies: ["kappserver"]),
        .testTarget(
            name: "appcoreTests",
            dependencies: ["appcore", "SwiftyJSON",
			.product(name: "WebSocketKit", package: "websocket-kit")],
			resources: [.copy("Resources")]
			),
		.testTarget(
			name: "servermodelTests",
			dependencies: ["servermodel"]
		)
	]
)
