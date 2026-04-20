// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AlicloudHTTPDNS",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "AlicloudHTTPDNS",
            targets: ["AlicloudHTTPDNS"]
        )
    ],
    targets: [
        .target(
            name: "AlicloudHTTPDNS",
            path: "Sources/ScloudHttpDNS"
        )
    ]
)
