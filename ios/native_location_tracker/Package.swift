// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "native_location_tracker",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(
            name: "native-location-tracker",
            targets: ["native_location_tracker"]
        )
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "native_location_tracker",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
