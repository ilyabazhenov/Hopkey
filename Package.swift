// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hopkey",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Чистое ядро: парсер тикетов + настройки. Без UI, поэтому легко тестируется.
        .target(
            name: "HopkeyCore"
        ),
        // GUI-приложение в строке меню.
        .executableTarget(
            name: "Hopkey",
            dependencies: ["HopkeyCore"]
        ),
        .testTarget(
            name: "HopkeyCoreTests",
            dependencies: ["HopkeyCore"]
        ),
    ]
)
