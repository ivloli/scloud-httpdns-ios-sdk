// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScloudHTTPDNS",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "ScloudHTTPDNS",
            targets: ["ScloudHTTPDNS"]
        ),
        .executable(
            name: "ScloudHTTPDNSDemo",
            targets: ["ScloudHTTPDNSDemo"]
        )
    ],
    targets: [
        .target(
            name: "ScloudHTTPDNS",
            path: "Sources/ScloudHttpDNS"
        ),
        .executableTarget(
            name: "ScloudHTTPDNSDemo",
            dependencies: [
                .target(name: "ScloudHTTPDNS")
            ],
            path: "Sources/ScloudHTTPDNSDemo"
        )
    ]
)
