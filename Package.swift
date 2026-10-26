// swift-tools-version:6.0
import PackageDescription

let sherpaLibs = [
    "sherpa-onnx-c-api", "sherpa-onnx-core", "sherpa-onnx-fstfar", "sherpa-onnx-fst",
    "sherpa-onnx-kaldifst-core", "kaldi-decoder-core", "kaldi-native-fbank-core",
    "kissfft-float", "ssentencepiece_core", "onnxruntime",
]

let package = Package(
    name: "Unazc",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),
        // whisper.cpp release xcframework (see scripts/fetch-deps.sh); embedded by build-app.sh.
        .binaryTarget(name: "whisper", path: "vendor/whisper.xcframework"),
        .target(
            name: "UnazcObjC", path: "Sources/UnazcObjC",
            // Without this ARC leaks strong locals when an exception leaves an @try scope.
            cSettings: [.unsafeFlags(["-fobjc-arc-exceptions"])],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .executableTarget(
            name: "Unazc",
            dependencies: ["CSherpaOnnx", "UnazcObjC", "whisper"],
            path: "Sources/Unazc",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Lvendor/sherpa-onnx/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
            ] + sherpaLibs.map { .linkedLibrary($0) }
        ),
        // Logic that needs no microphone, keyboard or model: `swift test`.
        .testTarget(
            name: "UnazcTests",
            dependencies: ["Unazc"],
            path: "Tests/UnazcTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
