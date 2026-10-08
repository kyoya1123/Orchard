import Foundation
@testable import OrchardCore
import XCTest

final class SimulatorBaseTests: XCTestCase, @unchecked Sendable {
    func testRealSubprocessCompletesWithoutRunLoopDeadlock() async throws {
        let path = try await SimulatorProcess.run(tool: "--find", arguments: ["simctl"], timeout: 10)
        XCTAssertTrue(path.hasSuffix("/simctl"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    func testStoppedBaseBundleCheckFailsClosed() throws {
        let (_, _, root) = try fixture()
        XCTAssertThrowsError(try SimulatorBaseService.hasNoAppBundles(in: root))
        let apps = root.appendingPathComponent("data/Containers/Bundle/Application")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        XCTAssertTrue(try SimulatorBaseService.hasNoAppBundles(in: root))
        try Data("bundle".utf8).write(to: apps.appendingPathComponent("unexpected-file"))
        XCTAssertFalse(try SimulatorBaseService.hasNoAppBundles(in: root))
    }

    private func fixture() throws -> (SimulatorBaseService, SimulatorFixture, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrchardBaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fake = SimulatorFixture()
        let service = SimulatorBaseService(root: root, destinationSet: root.appendingPathComponent("default"),
            command: { tool, arguments, _ in try await fake.run(tool, arguments) })
        return (service, fake, root)
    }

    func testLatestUsesAvailableCompatibleRuntimeAndNewestPro() async throws {
        let catalog = try JSONDecoder().decode(SimulatorCatalog.self, from: Data(await SimulatorFixture().catalog().utf8))
        let (device, runtime) = try catalog.resolve(.init())
        XCTAssertEqual(device.name, "iPhone 18 Pro")
        XCTAssertEqual(runtime.version, "27.0")
        let (oldDevice, oldRuntime) = try catalog.resolve(.init(runtime: "iOS 26.5"))
        XCTAssertEqual(oldDevice.name, "iPhone 17 Pro")
        XCTAssertEqual(oldRuntime.version, "26.5")
        XCTAssertThrowsError(try catalog.resolve(.init(deviceType: "iPhone 18 Pro", runtime: "iOS 26.5")))
        XCTAssertThrowsError(try catalog.resolve(.init(runtime: "iOS 28.0")))
    }

    func testNewBaseOnlyBootsAndShutsDownBeforeCloning() async throws {
        let (service, fake, _) = try fixture()
        let result = try await service.prepare(name: "feature-one")
        XCTAssertEqual(result.deviceType, "iPhone 18 Pro")
        XCTAssertFalse(result.reused)
        let calls = await fake.calls
        let verbs = calls.filter { $0.first == "simctl" }.map { $0[3] }
        XCTAssertEqual(verbs.filter { ["create", "boot", "bootstatus", "shutdown", "clone"].contains($0) },
                       ["create", "boot", "bootstatus", "shutdown", "clone"])
        XCTAssertFalse(verbs.contains("install"))
        XCTAssertFalse(verbs.contains("spawn"))
        let cloned = await fake.defaultDevices
        XCTAssertEqual(cloned.count, 1)
        XCTAssertEqual(cloned.first?["name"], "feature-one")
    }

    func testRepeatedPrepareReusesBaseAndBranch() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare(name: "feature-one")
        let second = try await service.prepare(name: "feature-one")
        XCTAssertEqual(first.udid, second.udid)
        XCTAssertEqual(first.baseUDID, second.baseUDID)
        XCTAssertTrue(second.reused)
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.contains("create") }.count, 1)
        XCTAssertEqual(calls.filter { $0.contains("clone") }.count, 1)
    }

    func testXcodeUpdateReplacesBaseAfterSuccessfulClone() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare(name: "one")
        await fake.setXcode("Xcode 27.1 build newer")
        let second = try await service.prepare(name: "two")
        XCTAssertNotEqual(first.baseUDID, second.baseUDID)
        let calls = await fake.calls
        let deleteIndex = try XCTUnwrap(calls.firstIndex { $0.contains("delete") && $0.contains(first.baseUDID) })
        let cloneIndex = try XCTUnwrap(calls.lastIndex { $0.contains("clone") })
        XCTAssertGreaterThan(deleteIndex, cloneIndex)
        let branches = await fake.defaultDevices
        XCTAssertEqual(branches.count, 2)
    }

    func testRuntimeBuildUpdateAlsoInvalidatesBase() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare()
        await fake.setRuntimeBuild("24A999")
        let second = try await service.prepare()
        XCTAssertNotEqual(first.udid, second.udid)
        let devices = await fake.privateDevices
        XCTAssertEqual(devices.count, 1)
    }

    func testFailedBootRetainsPreviousBaseAndAllBranchDevices() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare(name: "one")
        await fake.setXcode("new Xcode")
        await fake.setFailure("bootstatus")
        do { _ = try await service.prepare(name: "two"); XCTFail("Should fail") } catch {}
        let devices = await fake.privateDevices
        XCTAssertTrue(devices.contains { $0["udid"] == first.baseUDID })
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains("delete") })
        XCTAssertEqual(calls.filter { $0.contains("clone") }.count, 1)
    }

    func testFailedCloneKeepsOldBase() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare(name: "one")
        await fake.setXcode("new Xcode")
        await fake.setFailure("clone")
        do { _ = try await service.prepare(name: "two"); XCTFail("Should fail") } catch {}
        let devices = await fake.privateDevices
        XCTAssertTrue(devices.contains { $0["udid"] == first.baseUDID })
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains("delete") })
    }

    func testBootedOldBaseIsNotStoppedOrDeleted() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare()
        await fake.setState(first.udid, "Booted")
        await fake.resetCalls()
        let second = try await service.prepare()
        XCTAssertNotEqual(first.udid, second.udid)
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { ($0.contains("shutdown") || $0.contains("delete")) && $0.contains(first.udid) })
    }

    func testBaseWithUserAppIsNeitherClonedNorDeleted() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare()
        try await fake.addUserApp(first.udid)
        await fake.resetCalls()
        let second = try await service.prepare(name: "new-branch")
        XCTAssertNotEqual(first.udid, second.baseUDID)
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { ($0.contains("clone") || $0.contains("delete")) && $0.contains(first.udid) })
    }

    func testUnregisteredOrRenamedDevicesArePreserved() async throws {
        let (service, fake, _) = try fixture()
        let first = try await service.prepare()
        await fake.rename(first.udid, "My valuable simulator")
        await fake.addUnregisteredDevice()
        await fake.setXcode("new Xcode")
        _ = try await service.prepare()
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains("delete") })
        let devices = await fake.privateDevices
        XCTAssertEqual(devices.count, 3)
    }

    func testExistingBootedBranchIsReusedWithoutMutation() async throws {
        let (service, fake, _) = try fixture()
        let id = await fake.addExistingBranch(name: "existing", state: "Booted")
        let result = try await service.prepare(name: "existing")
        XCTAssertEqual(result.udid, id)
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains(id) })
    }

    func testDuplicateBranchesFailBeforeAnyBaseCreation() async throws {
        let (service, fake, _) = try fixture()
        _ = await fake.addExistingBranch(name: "duplicate", state: "Shutdown")
        _ = await fake.addExistingBranch(name: "duplicate", state: "Shutdown")
        do { _ = try await service.prepare(name: "duplicate"); XCTFail("Should fail") } catch {}
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains("create") })
    }

    func testConcurrentRequestsCreateOneBaseAndOneBranch() async throws {
        let (service, fake, _) = try fixture()
        async let first = service.prepare(name: "same")
        async let second = service.prepare(name: "same")
        let results = try await [first, second]
        XCTAssertEqual(results[0].udid, results[1].udid)
        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.contains("create") }.count, 1)
        XCTAssertEqual(calls.filter { $0.contains("clone") }.count, 1)
    }

    func testCorruptRegistryFailsClosed() async throws {
        let (service, fake, root) = try fixture()
        try Data("not json".utf8).write(to: root.appendingPathComponent("manifest.json"))
        do { _ = try await service.prepare(); XCTFail("Should fail") } catch {}
        let calls = await fake.calls
        XCTAssertFalse(calls.contains { $0.contains("create") || $0.contains("delete") })
    }
}

private actor SimulatorFixture {
    var calls: [[String]] = []
    var privateDevices: [[String: String]] = []
    var defaultDevices: [[String: String]] = []
    var xcode = "Xcode 27.0 build 27A266a"
    var runtimeBuild = "24A434"
    var failure: String?
    var userApps: Set<String> = []
    var privateSet: String?

    func setXcode(_ value: String) { xcode = value }
    func setRuntimeBuild(_ value: String) { runtimeBuild = value }
    func setFailure(_ value: String) { failure = value }
    func resetCalls() { calls = [] }
    func addUserApp(_ id: String) throws {
        userApps.insert(id)
        let path = URL(fileURLWithPath: privateSet!).appendingPathComponent(id)
            .appendingPathComponent("data/Containers/Bundle/Application/UserApp.app")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    func setState(_ id: String, _ state: String) {
        if let i = privateDevices.firstIndex(where: { $0["udid"] == id }) { privateDevices[i]["state"] = state }
    }
    func rename(_ id: String, _ name: String) {
        if let i = privateDevices.firstIndex(where: { $0["udid"] == id }) { privateDevices[i]["name"] = name }
    }
    func addUnregisteredDevice() { privateDevices.append(device("Unmanaged", state: "Shutdown")) }
    func addExistingBranch(name: String, state: String) -> String {
        let item = device(name, state: state)
        defaultDevices.append(item)
        return item["udid"]!
    }

    private func device(_ name: String, state: String) -> [String: String] {
        ["udid": UUID().uuidString, "name": name, "state": state, "deviceTypeIdentifier": "type18"]
    }
    private func encoded(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func devicesJSON(_ devices: [[String: String]]) -> [[String: Any]] {
        devices.map { ($0 as [String: Any]).merging(["isAvailable": true]) { _, new in new } }
    }
    func catalog() throws -> String {
        try encoded([
            "devicetypes": [
                ["name": "iPhone 18 Pro Max", "identifier": "type18max", "modelIdentifier": "iPhone19,3"],
                ["name": "iPhone 17 Pro", "identifier": "type17", "modelIdentifier": "iPhone18,1"],
                ["name": "iPhone 18 Pro", "identifier": "type18", "modelIdentifier": "iPhone19,2"],
                ["name": "iPad Pro", "identifier": "ipad", "modelIdentifier": "iPad99,1"]
            ],
            "runtimes": [
                ["name": "iOS 28.0", "identifier": "com.apple.iOS-28-0", "version": "28.0", "buildversion": "25A1", "isAvailable": false],
                ["name": "iOS 26.5", "identifier": "com.apple.iOS-26-5", "version": "26.5", "buildversion": "23F1", "isAvailable": true,
                 "supportedDeviceTypes": [["identifier": "type17"]]],
                ["name": "iOS 27.0", "identifier": "com.apple.iOS-27-0", "version": "27.0", "buildversion": runtimeBuild, "isAvailable": true,
                 "supportedDeviceTypes": [["identifier": "type18"], ["identifier": "type18max"], ["identifier": "type17"], ["identifier": "ipad"]]]
            ],
            "devices": ["com.apple.iOS-27-0": devicesJSON(defaultDevices)]
        ])
    }

    func run(_ tool: String, _ arguments: [String]) throws -> String {
        calls.append([tool] + arguments)
        if tool == "xcodebuild" { return xcode }
        if tool == "--find" { return "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl" }
        guard tool == "simctl", arguments.count >= 3, arguments[0] == "--set" else {
            throw OrchardError.message("Unexpected command")
        }
        let args = Array(arguments.dropFirst(2))
        if args[0] == failure { throw OrchardError.message("Injected \(args[0]) failure") }
        switch args[0] {
        case "list":
            if args == ["list", "-j"] { return try catalog() }
            return try encoded(["devices": ["com.apple.iOS-27-0": devicesJSON(privateDevices)]])
        case "create":
            let new = device(args[1], state: "Shutdown")
            privateDevices.append(new)
            privateSet = arguments[1]
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: arguments[1])
                .appendingPathComponent(new["udid"]!).appendingPathComponent("data/Containers"), withIntermediateDirectories: true)
            return new["udid"]!
        case "boot": setState(args[1], "Booted")
        case "bootstatus": break
        case "shutdown": setState(args[1], "Shutdown")
        case "listapps":
            if privateDevices.first(where: { $0["udid"] == args[1] })?["state"] != "Booted" {
                throw OrchardError.message("Unable to lookup in current state: Shutdown")
            }
            let appType = userApps.contains(args[1]) ? "User" : "System"
            let data = try PropertyListSerialization.data(fromPropertyList: ["app": ["ApplicationType": appType]], format: .xml, options: 0)
            return String(decoding: data, as: UTF8.self)
        case "clone":
            let new = device(args[2], state: "Shutdown")
            defaultDevices.append(new)
            return new["udid"]!
        case "delete":
            guard arguments[1].hasSuffix("/devices") else { throw OrchardError.message("Tried to delete default device!") }
            privateDevices.removeAll { $0["udid"] == args[1] }
        default: throw OrchardError.message("Unexpected command \(args)")
        }
        return ""
    }
}
