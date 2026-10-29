import Foundation

public struct SimulatorSelection: Sendable {
    public let deviceType: String
    public let runtime: String

    public init(deviceType: String = "latest", runtime: String = "latest") {
        self.deviceType = deviceType
        self.runtime = runtime
    }
}

struct SimulatorCatalog: Decodable, Sendable {
    struct DeviceType: Decodable, Sendable {
        let identifier: String
        let name: String
        let productFamily: String?
        let modelIdentifier: String?
        let minRuntimeVersion: UInt64?
        let maxRuntimeVersion: UInt64?
    }

    struct Runtime: Decodable, Sendable {
        struct SupportedDevice: Decodable, Sendable { let identifier: String }
        let identifier: String
        let name: String
        let version: String
        let buildversion: String
        let isAvailable: Bool
        let supportedDeviceTypes: [SupportedDevice]?
    }

    struct Device: Decodable, Sendable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String?
    }

    let devicetypes: [DeviceType]
    let runtimes: [Runtime]
    let devices: [String: [Device]]

    func resolve(_ selection: SimulatorSelection) throws -> (DeviceType, Runtime) {
        if selection.deviceType != "latest", !devicetypes.contains(where: {
            $0.name == selection.deviceType || $0.identifier == selection.deviceType
        }) {
            throw OrchardError.message("Unknown Simulator device type: \(selection.deviceType).")
        }
        let runtimes = runtimes.filter {
            $0.isAvailable && $0.identifier.contains(".iOS-") &&
            (selection.runtime == "latest" || selection.runtime == $0.name || selection.runtime == $0.identifier)
        }.sorted {
            if $0.version != $1.version { return Self.numbers($1.version).lexicographicallyPrecedes(Self.numbers($0.version)) }
            return $1.buildversion.localizedStandardCompare($0.buildversion) == .orderedAscending
        }
        for runtime in runtimes {
            let compatible = devicetypes.filter { Self.supports($0, runtime: runtime) }
            if selection.deviceType != "latest" {
                if let device = compatible.first(where: { $0.name == selection.deviceType || $0.identifier == selection.deviceType }) {
                    return (device, runtime)
                }
            } else {
                // Hardware generation first, then prefer the regular Pro within
                // that generation. Never mistake an iPad/iPod for the latest phone.
                let phones = compatible.filter { $0.name.hasPrefix("iPhone ") }
                if let device = phones.sorted(by: { lhs, rhs in
                    let left = Self.numbers(lhs.modelIdentifier ?? "").first ?? 0
                    let right = Self.numbers(rhs.modelIdentifier ?? "").first ?? 0
                    if left != right { return left > right }
                    let leftPro = lhs.name.hasSuffix(" Pro"), rightPro = rhs.name.hasSuffix(" Pro")
                    if leftPro != rightPro { return leftPro }
                    if lhs.minRuntimeVersion != rhs.minRuntimeVersion {
                        return (lhs.minRuntimeVersion ?? 0) > (rhs.minRuntimeVersion ?? 0)
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
                }).first { return (device, runtime) }
            }
        }
        if runtimes.isEmpty, selection.runtime != "latest" {
            throw OrchardError.message("iOS Simulator runtime \(selection.runtime) is not installed and available. Existing devices have been preserved.")
        }
        if selection.deviceType != "latest" {
            let device = devicetypes.first { $0.name == selection.deviceType || $0.identifier == selection.deviceType }!
            let alternatives = self.runtimes.filter { $0.isAvailable && $0.identifier.contains(".iOS-") && Self.supports(device, runtime: $0) }
                .map(\.name).joined(separator: ", ")
            throw OrchardError.message("No installed, available iOS runtime confirms support for \(device.name) / \(selection.runtime). Compatible installed runtimes: \(alternatives.isEmpty ? "none" : alternatives). Existing devices have been preserved.")
        }
        throw OrchardError.message("No installed, available iOS Simulator configuration matches \(selection.deviceType) / \(selection.runtime).")
    }

    // simctl's runtime-specific support list takes precedence over the device's
    // broad min/max range: a special runtime may support only one phone family.
    private static func supports(_ device: DeviceType, runtime: Runtime) -> Bool {
        if let supported = runtime.supportedDeviceTypes {
            return supported.contains { $0.identifier == device.identifier }
        }
        guard let minimum = device.minRuntimeVersion, let maximum = device.maxRuntimeVersion else { return false }
        let version = numbers(runtime.version)
        guard !version.isEmpty else { return false }
        let encoded = UInt64((version[0] << 16) | ((version.dropFirst().first ?? 0) << 8) | (version.dropFirst(2).first ?? 0))
        return minimum <= encoded && encoded <= maximum
    }

    static func numbers(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
