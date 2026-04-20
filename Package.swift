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
        )
    ],
    targets: [
        .target(
            name: "ScloudHTTPDNS",
            path: "Sources/ScloudHttpDNS"
        )
    ]
)
