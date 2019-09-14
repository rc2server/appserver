// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kappserver",
	platforms: [
		.macOS(.v10_13)
	],
    dependencies: [
    	.package(path: "../appmodel2"),
        .package(url: "https://github.com/IBM-Swift/Kitura", from: "2.7.0"),
        .package(url: "https://github.com/IBM-Swift/Kitura-WebSocket.git", from: "2.1.2"),
		.package(url: "https://github.com/IBM-Swift/Swift-JWT.git", from: "3.5.3"),
		.package(url: "https://github.com/IBM-Swift/BlueSocket.git", from: "1.0.0"),
		.package(url: "https://github.com/rc2server/CommandLine.git", from: "3.0.0"),
		.package(url: "https://github.com/apple/swift-log.git", from: "1.1.1"),
		.package(url: "https://github.com/IBM-Swift/HeliumLogger.git", from: "1.9.0"),
		.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
		.package(url: "https://github.com/IBM-Swift/FileKit.git", from: "0.0.2"),
		.package(url: "https://github.com/Thomvis/BrightFutures.git", from: "8.0.1"),
        .package(path: "../pgswift"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "kappserver",
			dependencies: ["servermodel", "Kitura", "Kitura-WebSocket", "Rc2Model", "pgswift", "HeliumLogger", "Logging", "CommandLine", "SwiftJWT", "ZIPFoundation", "FileKit", "Socket", "BrightFutures"]),
        .target(
        	name: "servermodel",
        	dependencies: ["Rc2Model", "pgswift", "Logging", "SwiftJWT"]),
        .testTarget(
            name: "kappserverTests",
            dependencies: ["kappserver", "servermodelTests"]),
		.testTarget(
			name: "servermodelTests",
			dependencies: ["servermodel"]),
    ]
)
