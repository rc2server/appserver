// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "kappserver",
    dependencies: [
    	.package(path: "../appmodel2"),
        .package(url: "https://github.com/IBM-Swift/Kitura", from: "2.7.0"),
        .package(url: "https://github.com/IBM-Swift/Kitura-WebSocket.git", from: "2.1.2"),
        .package(path: "../pgswift"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "kappserver",
            dependencies: ["Kitura", "Kitura-WebSocket", "Rc2Model", "pgswift"]),
//        .target(
//        	name: "servermodel",
//        	dependencies: ["Rc2Model"]),
        .testTarget(
            name: "kappserverTests",
            dependencies: ["kappserver"]),
    ]
)
