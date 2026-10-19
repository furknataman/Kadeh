//
//  SystemSensors.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Darwin
import Foundation
import IOKit

/// The global performance overlay switch from the Settings window.
public enum PerformanceOverlay {
    public static let defaultsKey = "performanceOverlay"

    /// Read from the app's preferences domain by name rather than through
    /// `UserDefaults.standard`, because WhiskyCmd has no bundle identifier of
    /// its own and its standard domain is not the app's.
    public static var isEnabled: Bool {
        CFPreferencesCopyAppValue(defaultsKey as CFString, Bundle.whiskyBundleIdentifier as CFString) as? Bool ?? false
    }
}

/// One refresh of the overlay's system panel. `nil` means the value could not be
/// read; ``line`` drops it, and anything outside a physically plausible range,
/// so a bad read never reaches the screen.
public struct SystemSnapshot: Sendable {
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var cpuUsage: Double?
    var gpuUsage: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var fanSpeeds: [Double] = []

    /// The panel's single row, e.g. `CPU 67° 23% · GPU 70° 79% · RAM 34/64 GB · Fan 1356`.
    public var line: String {
        var parts: [String] = []
        for (label, temperature, usage) in [("CPU", cpuTemperature, cpuUsage), ("GPU", gpuTemperature, gpuUsage)] {
            let values = [temperature.flatMap(Self.temperature), usage.flatMap(Self.percent)].compactMap { $0 }
            if !values.isEmpty { parts.append(([label] + values).joined(separator: " ")) }
        }
        if let used = memoryUsed, let total = memoryTotal, total > 0, used <= total {
            let gigabytes = { (bytes: UInt64) in Int((Double(bytes) / 1_073_741_824).rounded()) }
            parts.append("RAM \(gigabytes(used))/\(gigabytes(total)) GB")
        }
        let fans = fanSpeeds.filter { (0 ... 10000).contains($0) }.map { String(Int($0.rounded())) }
        if !fans.isEmpty { parts.append("Fan " + fans.joined(separator: "/")) }
        return parts.joined(separator: " · ")
    }

    static func temperature(_ celsius: Double) -> String? {
        (1 ... 125).contains(celsius) ? "\(Int(celsius.rounded()))°" : nil
    }

    static func percent(_ value: Double) -> String? {
        (0 ... 100).contains(value) ? "\(Int(value.rounded()))%" : nil
    }
}

/// Reads the overlay's system metrics on Apple Silicon: temperatures and fans
/// from the SMC, GPU load from the IOAccelerator, CPU and memory from Mach.
///
/// Create one and call ``sample()`` about once a second from a single thread;
/// CPU usage is the difference between two calls, so the first sample has none.
public final class SystemSensors {
    private var smc: io_connect_t = 0
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var fanKeys: [String] = []
    private var previousTicks: (busy: UInt64, total: UInt64)?
    /// One send right for the whole process: each `mach_host_self()` call
    /// adds a reference that is never given back.
    private static let host = mach_host_self()

    public init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &smc) == KERN_SUCCESS else {
            smc = 0
            return
        }
        let keys = Self.temperatureKeys(chip: Self.chipGeneration())
        cpuKeys = keys.cpu.filter(isFloatKey)
        gpuKeys = keys.gpu.filter(isFloatKey)
        let fanCount = Int(read("FNum", size: 1)?.first ?? 0)
        fanKeys = (0 ..< fanCount).map { "F\($0)Ac" }.filter(isFloatKey)
    }

    deinit {
        if smc != 0 { IOServiceClose(smc) }
    }

    public func sample() -> SystemSnapshot {
        SystemSnapshot(
            cpuTemperature: average(cpuKeys) ?? Self.dieTemperature(),
            gpuTemperature: average(gpuKeys),
            cpuUsage: cpuUsage(),
            gpuUsage: Self.gpuUsage(),
            memoryUsed: Self.memoryUsed(),
            memoryTotal: Foundation.ProcessInfo.processInfo.physicalMemory,
            fanSpeeds: fanKeys.compactMap(readFloat)
        )
    }

    // MARK: - SMC

    /// Per-core temperature keys by Apple Silicon generation, as published by
    /// the open-source Stats app. Keys a machine lacks are dropped at init.
    static func temperatureKeys(chip: Int) -> (cpu: [String], gpu: [String]) {
        switch chip {
        case 1:
            (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
             ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        case 2:
            (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
             ["Tg0f", "Tg0j"])
        case 3:
            (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
              "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
             ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
        default:
            (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
             ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        }
    }

    /// The `N` of "Apple MN ...", or 0 when the brand string has none.
    private static func chipGeneration() -> Int {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let match = String(decoding: brand.prefix { $0 != 0 }, as: UTF8.self).firstMatch(of: /Apple M(\d+)/)
        return match.flatMap { Int($0.1) } ?? 0
    }

    private func average(_ keys: [String]) -> Double? {
        let values = keys.compactMap(readFloat).filter { (1 ... 125).contains($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // `SMCKeyData_t` is 80 bytes; the offsets below are the fields used here.
    private func call(_ key: String, command: UInt8, size: UInt32 = 0) -> [UInt8]? {
        guard smc != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: 80)
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        withUnsafeBytes(of: code.littleEndian) { input.replaceSubrange(0 ..< 4, with: $0) }
        withUnsafeBytes(of: size.littleEndian) { input.replaceSubrange(28 ..< 32, with: $0) }
        input[42] = command
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let result = IOConnectCallStructMethod(smc, 2, input, input.count, &output, &outputSize)
        return result == KERN_SUCCESS && output[40] == 0 ? output : nil
    }

    private func read(_ key: String, size: UInt32) -> [UInt8]? {
        call(key, command: 5, size: size).map { Array($0[48 ..< 48 + Int(size)]) }
    }

    private func isFloatKey(_ key: String) -> Bool {
        guard let info = call(key, command: 9) else { return false }
        let size = info[28 ..< 32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return size == 4 && Array(info[32 ..< 36]) == Array("flt ".utf8.reversed())
    }

    private func readFloat(_ key: String) -> Double? {
        read(key, size: 4).map { bytes in
            Double(Float(bitPattern: bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
    }

    // MARK: - IOHIDEventSystemClient

    /// Average SoC die temperature from the private HID event system, the
    /// fallback for chips whose SMC core keys are not in ``temperatureKeys(chip:)``.
    static func dieTemperature() -> Double? {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
        typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        func symbol<T>(_ name: String, _: T.Type) -> T? { dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", FloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // Apple vendor page, temperature sensor usage; event type 15 is temperature.
        _ = setMatching(client, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let values = services.compactMap { service -> Double? in
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard name.hasPrefix("PMU tdie") || name.contains("ACC MTR"),
                  let event = copyEvent(service, 15, 0, 0)?.takeRetainedValue()
            else { return nil }
            return floatValue(event, 15 << 16)
        }.filter { (1 ... 125).contains($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Load

    private func cpuUsage() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Self.host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
            == KERN_SUCCESS, let info else { return nil }
        defer {
            let bytes = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), bytes)
        }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0 ..< Int(cpuCount) {
            let ticks = { (state: Int32) in UInt64(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int(state)])) }
            busy += ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            total += ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE) + ticks(CPU_STATE_IDLE)
        }
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total, busy >= previous.busy else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total) * 100
    }

    private static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, nil, 0)?
                .takeRetainedValue() as? [String: Any]
            if let utilization = stats?["Device Utilization %"] as? NSNumber {
                return utilization.doubleValue
            }
        }
        return nil
    }

    /// What Activity Monitor calls Memory Used: app memory, wired and compressed.
    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let pages = max(appPages, 0) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return UInt64(pages) * UInt64(getpagesize())
    }
}
