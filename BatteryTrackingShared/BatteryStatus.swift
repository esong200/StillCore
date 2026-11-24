import Foundation
import IOKit

enum BatteryStatusError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Battery information is unavailable."
        }
    }
}

struct BatteryStatus {
    var updateTime: Int?
    var rawCurrentCapacity: Int?
    var reportedCurrentCapacity: Int?
    var reportedMaxCapacity: Int?
    var remainingCapacity: Int?
    var fullChargeCapacity: Int?
    var currentCapacityMah: Int
    var maxCapacityMah: Int
    var isOnACPower: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    var powerSaveMode: Bool
    var chargerMaxWatts: Int? = nil
    var chargingWatts: Double? = nil

    static var isAvailable: Bool {
        let entry = openBatteryEntry()
        guard entry != IO_OBJECT_NULL else {
            return false
        }
        defer { IOObjectRelease(entry) }
        return boolProperty(entry: entry, key: "BatteryInstalled") == true
    }

    static func read() throws -> BatteryStatus {
        let entry = openBatteryEntry()
        guard entry != IO_OBJECT_NULL else {
            throw BatteryStatusError.unavailable
        }
        defer { IOObjectRelease(entry) }

        let rawCurrent = intProperty(entry: entry, key: "AppleRawCurrentCapacity")
        let rawMax = intProperty(entry: entry, key: "AppleRawMaxCapacity")
        let reportedCurrent = intProperty(entry: entry, key: "CurrentCapacity")
        let reportedMax = intProperty(entry: entry, key: "MaxCapacity")
        let batteryData = IORegistryEntryCreateCFProperty(
            entry, "BatteryData" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let remaining = batteryData?["RemainingCapacity"] as? Int
        let full = batteryData?["FullChargeCapacity"] as? Int
        let currentCapacity: Int
        let maxCapacity: Int
        if let rawCurrent, let rawMax, rawMax > 0 {
            currentCapacity = rawCurrent
            maxCapacity = rawMax
        } else if let remaining, let full, full > 0 {
            currentCapacity = remaining
            maxCapacity = full
        } else if let reportedCurrent, let reportedMax, reportedMax > 100 {
            // Older drivers can publish mAh directly in the top-level pair.
            currentCapacity = reportedCurrent
            maxCapacity = reportedMax
        } else {
            throw BatteryStatusError.unavailable
        }
        guard
            boolProperty(entry: entry, key: "BatteryInstalled") == true,
            let isOnACPower = boolProperty(entry: entry, key: "ExternalConnected"),
            let isCharging = boolProperty(entry: entry, key: "IsCharging"),
            let isFullyCharged = boolProperty(entry: entry, key: "FullyCharged")
        else {
            throw BatteryStatusError.unavailable
        }

        var chargerMaxWatts: Int?
        var chargingWatts: Double?
        if isOnACPower {
            let adapter = IORegistryEntryCreateCFProperty(
                entry, "AdapterDetails" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any]
            if let watts = adapter?["Watts"] as? Int, watts > 0 {
                chargerMaxWatts = watts
            }
            if let millivolts = intProperty(entry: entry, key: "Voltage"), millivolts > 0,
               let milliamps = signedCurrentProperty(entry: entry, key: "InstantAmperage")
                    ?? signedCurrentProperty(entry: entry, key: "Amperage") {
                // Keep the signed battery current even when IsCharging is false:
                // negative power is the shortfall being supplied by the battery.
                chargingWatts = Double(millivolts) * Double(milliamps) / 1_000_000
            }
        }

        return BatteryStatus(
            updateTime: intProperty(entry: entry, key: "UpdateTime"),
            rawCurrentCapacity: rawCurrent,
            reportedCurrentCapacity: reportedCurrent,
            reportedMaxCapacity: reportedMax,
            remainingCapacity: remaining,
            fullChargeCapacity: full,
            currentCapacityMah: currentCapacity,
            maxCapacityMah: maxCapacity,
            isOnACPower: isOnACPower,
            isCharging: isCharging,
            isFullyCharged: isFullyCharged,
            powerSaveMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            chargerMaxWatts: chargerMaxWatts,
            chargingWatts: chargingWatts
        )
    }

    /// Reads the live pack temperature independently of battery capacity reporting.
    static func readTemperatureCelsius() -> Float? {
        // Newer systems expose temperature on the pack; older systems use the battery.
        for serviceName in ["AppleSmartBatteryPack", "AppleSmartBattery"] {
            let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
            if entry != IO_OBJECT_NULL {
                defer { IOObjectRelease(entry) }
                let batteryData = IORegistryEntryCreateCFProperty(
                    entry, "BatteryData" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any]
                let raw = intProperty(entry: entry, key: "Temperature")
                    ?? batteryData?["Temperature"] as? Int
                    ?? batteryData?["VirtualTemperature"] as? Int
                if let raw, raw > 0, raw <= 10_000 {
                    // These registry values are in hundredths of a degree Celsius.
                    return Float(raw) / 100
                }
            }
        }
        return nil
    }

    private static func openBatteryEntry() -> io_registry_entry_t {
        var iterator = io_iterator_t()
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(iterator) }
        return IOIteratorNext(iterator)
    }

    private static func signedCurrentProperty(entry: io_registry_entry_t, key: String) -> Int? {
        if let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), CFGetTypeID(value) == CFNumberGetTypeID(),
           let number = value as? NSNumber {
            // Some drivers expose negative current as an unsigned 64-bit bit pattern.
            return number.intValue
        }
        return nil
    }

    private static func intProperty(entry: io_registry_entry_t, key: String) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return value as? Int
        }
        return nil
    }

    private static func boolProperty(entry: io_registry_entry_t, key: String) -> Bool? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        else {
            return nil
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return value as? Bool
        }
        return nil
    }
}
