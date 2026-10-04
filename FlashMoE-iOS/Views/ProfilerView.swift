/*
 * ProfilerView.swift — Engine telemetry
 *
 * SystemMetrics samples real-time resource use during inference:
 * memory (RSS + available), thermal state and CPU. TelemetrySheet is the
 * surface that presents it alongside the engine's own generation stats.
 *
 * All APIs are public (mach_task_info, os_proc_available_memory,
 * ProcessInfo.thermalState) — no entitlements needed.
 */

import SwiftUI
import Darwin.Mach

// MARK: - System Metrics Sampler

@Observable
final class SystemMetrics: @unchecked Sendable {
    private(set) var residentMemoryMB: Double = 0
    private(set) var availableMemoryMB: Double = 0
    private(set) var cpuUsagePercent: Double = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private var prevCPUTime: Double = 0
    private var prevSampleTime: CFAbsoluteTime = 0

    func sample() {
        residentMemoryMB = Self.getResidentMemory()
        availableMemoryMB = Self.getAvailableMemory()
        cpuUsagePercent = sampleCPU()
        thermalState = ProcessInfo.processInfo.thermalState
    }

    // MARK: - Memory

    private static func getResidentMemory() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    private static func getAvailableMemory() -> Double {
        #if os(iOS)
        // iOS: use os_proc_available_memory()
        return Double(os_proc_available_memory()) / (1024 * 1024)
        #elseif os(macOS)
        // macOS: estimate available memory using host_statistics64 and page counts
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var size: vm_size_t = 0
        let host = mach_host_self()

        // Get page size
        let kerrPage = host_page_size(host, &size)
        guard kerrPage == KERN_SUCCESS else { return 0 }

        // Fetch VM statistics
        let result: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // Consider free + inactive pages as "available"
        let freePages = UInt64(vmStats.free_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let speculativePages = UInt64(vmStats.speculative_count)

        let availableBytes = (freePages + inactivePages + speculativePages) * UInt64(size)
        return Double(availableBytes) / (1024 * 1024)
        #else
        // Other platforms: not available — return 0
        return 0
        #endif
    }

    // MARK: - CPU

    private func sampleCPU() -> Double {
        let now = CFAbsoluteTimeGetCurrent()
        let totalCPU = Self.getThreadCPUTime()

        defer {
            prevCPUTime = totalCPU
            prevSampleTime = now
        }

        guard prevSampleTime > 0 else { return 0 }
        let elapsed = now - prevSampleTime
        guard elapsed > 0 else { return 0 }

        let cpuDelta = totalCPU - prevCPUTime
        // Normalize to percentage (cpuDelta is in seconds of CPU time)
        return min((cpuDelta / elapsed) * 100.0, 999.0)
    }

    private static func getThreadCPUTime() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size))
        }

        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS {
                total += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
                total += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
            }
        }
        return total
    }
}

