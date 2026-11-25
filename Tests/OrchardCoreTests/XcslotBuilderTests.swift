import Foundation
@testable import OrchardCore
import XCTest

final class XcslotBuilderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("XcslotBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeExecutable(named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testDisabledByZero() throws {
        let bin = directory.appendingPathComponent("bin")
        _ = try makeExecutable(named: "xcslot", in: bin)
        XCTAssertNil(XcslotBuilder.locate(
            environment: ["ORCHARD_XCSLOT": "0", "PATH": bin.path],
            fallbackDirectories: [bin.path]
        ))
    }

    func testExplicitAbsolutePath() throws {
        let tool = try makeExecutable(named: "custom-xcslot", in: directory)
        XCTAssertEqual(
            XcslotBuilder.locate(environment: ["ORCHARD_XCSLOT": tool.path], fallbackDirectories: [])?.path,
            tool.path
        )
        XCTAssertNil(XcslotBuilder.locate(
            environment: ["ORCHARD_XCSLOT": directory.appendingPathComponent("missing").path],
            fallbackDirectories: []
        ))
    }

    func testSearchesPathThenFallbackDirectories() throws {
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let fallback = directory.appendingPathComponent("fallback")
        let inSecond = try makeExecutable(named: "xcslot", in: second)
        let inFallback = try makeExecutable(named: "xcslot", in: fallback)

        XCTAssertEqual(
            XcslotBuilder.locate(
                environment: ["PATH": "\(first.path):\(second.path)"],
                fallbackDirectories: [fallback.path]
            )?.path,
            inSecond.path
        )
        XCTAssertEqual(
            XcslotBuilder.locate(environment: ["PATH": first.path], fallbackDirectories: [fallback.path])?.path,
            inFallback.path
        )
        XCTAssertNil(XcslotBuilder.locate(environment: ["PATH": first.path], fallbackDirectories: []))
    }

    func testIgnoresNonExecutableFile() throws {
        let bin = directory.appendingPathComponent("bin")
        let tool = try makeExecutable(named: "xcslot", in: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)
        XCTAssertNil(XcslotBuilder.locate(environment: ["PATH": bin.path], fallbackDirectories: []))
    }

    func testArgumentsPutProductsOptionBeforeXcodebuildArguments() {
        let builder = XcslotBuilder(
            executableURL: URL(fileURLWithPath: "/bin/xcslot"),
            productsRoot: URL(fileURLWithPath: "/tmp/products")
        )
        let project = XcodeProject(
            rootURL: URL(fileURLWithPath: "/tmp/repo"),
            fileURL: URL(fileURLWithPath: "/tmp/repo/App.xcodeproj"),
            kind: .project
        )
        let destination = XcodeDestination(id: "UDID-1", name: "iPhone", runtime: "iOS 26", kind: .simulator)

        let arguments = builder.arguments(project: project, scheme: "App", destination: destination)

        XCTAssertEqual(arguments, [
            "xcodebuild", "--products-to", builder.productsDirectory(for: destination).path,
            "-project", "/tmp/repo/App.xcodeproj",
            "-scheme", "App",
            "-destination", "platform=iOS Simulator,id=UDID-1",
            "build"
        ])
        XCTAssertFalse(arguments.contains("-clonedSourcePackagesDirPath"))
    }

    func testPrunesOnlyStaleProductsOfOtherDestinations() throws {
        let builder = XcslotBuilder(executableURL: URL(fileURLWithPath: "/bin/xcslot"), productsRoot: directory)
        let current = XcodeDestination(id: "current", name: "a", runtime: "", kind: .simulator)
        let stale = builder.productsDirectory(for: XcodeDestination(id: "stale", name: "b", runtime: "", kind: .simulator))
        let fresh = builder.productsDirectory(for: XcodeDestination(id: "fresh", name: "c", runtime: "", kind: .simulator))
        let own = builder.productsDirectory(for: current)
        let old = Date().addingTimeInterval(-8 * 86400)
        for folder in [stale, fresh, own] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: own.path)

        builder.pruneStaleProducts(keeping: current)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    func testProductsDirectoryIsKeyedByDestination() {
        let builder = XcslotBuilder(
            executableURL: URL(fileURLWithPath: "/bin/xcslot"),
            productsRoot: URL(fileURLWithPath: "/tmp/products")
        )
        let a = XcodeDestination(id: "A", name: "a", runtime: "", kind: .simulator)
        let b = XcodeDestination(id: "B", name: "b", runtime: "", kind: .simulator)

        XCTAssertEqual(builder.productsDirectory(for: a), builder.productsDirectory(for: a))
        XCTAssertNotEqual(builder.productsDirectory(for: a), builder.productsDirectory(for: b))
        XCTAssertEqual(builder.productsDirectory(for: a).deletingLastPathComponent().path, "/tmp/products")
    }

    func testMapsAppIntoProductsDirectory() {
        let settings = XcodeBuildSettings(entries: [[
            "BUILD_DIR": "/slot/DerivedData/Build/Products",
            "TARGET_BUILD_DIR": "/slot/DerivedData/Build/Products/Debug-iphonesimulator",
            "WRAPPER_NAME": "App.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "example.app"
        ]])

        let app = settings.runnableApp(inProducts: URL(fileURLWithPath: "/cache/products/key"))

        XCTAssertEqual(app?.appURL.path, "/cache/products/key/Debug-iphonesimulator/App.app")
        XCTAssertEqual(app?.bundleIdentifier, "example.app")
    }

    func testMappingRejectsTargetOutsideBuildDirectory() {
        let settings = XcodeBuildSettings(entries: [[
            "BUILD_DIR": "/slot/DerivedData/Build/Products",
            "TARGET_BUILD_DIR": "/elsewhere/Debug-iphonesimulator",
            "WRAPPER_NAME": "App.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "example.app"
        ]])

        XCTAssertNil(settings.runnableApp(inProducts: URL(fileURLWithPath: "/cache/products/key")))
    }

    func testMappingRequiresBuildDirectory() {
        let settings = XcodeBuildSettings(entries: [[
            "TARGET_BUILD_DIR": "/slot/Debug-iphonesimulator",
            "WRAPPER_NAME": "App.app",
            "PRODUCT_BUNDLE_IDENTIFIER": "example.app"
        ]])

        XCTAssertNil(settings.runnableApp(inProducts: URL(fileURLWithPath: "/cache/products/key")))
    }
}
