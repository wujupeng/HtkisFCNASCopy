// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResumeSMBCopy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ResumeSMBCopyCore", targets: ["ResumeSMBCopyCore"]),
        .executable(name: "resume-smb-copy", targets: ["ResumeSMBCopy"])
    ],
    targets: [
        .target(name: "ResumeSMBCopyCore"),
        .executableTarget(
            name: "ResumeSMBCopy",
            dependencies: ["ResumeSMBCopyCore"]
        ),
        .testTarget(
            name: "ResumeSMBCopyCoreTests",
            dependencies: ["ResumeSMBCopyCore"]
        )
    ]
)
