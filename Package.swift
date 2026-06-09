// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hopkey",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Автообновление через appcast + EdDSA-подпись (см. build.sh, release.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        // Чистое ядро: парсер тикетов + настройки. Без UI, поэтому легко тестируется.
        .target(
            name: "HopkeyCore"
        ),
        // GUI-приложение в строке меню.
        .executableTarget(
            name: "Hopkey",
            dependencies: [
                "HopkeyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(
            name: "HopkeyCoreTests",
            dependencies: ["HopkeyCore"]
        ),
    ]
)
