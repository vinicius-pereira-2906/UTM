//
// Copyright © 2026 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if os(macOS)
import IOKit.ps

/// The Mac's internal battery as the guest should see it.
struct UTMHostBatteryState: Equatable {
    var isACOnline: Bool
    var isCharging: Bool
    var percent: Int
    /// Minutes until empty (discharging) or full (charging). Zero while the host is still estimating.
    var minutesRemaining: Int

    /// The current state, or nil on a Mac without an internal battery.
    static var current: UTMHostBatteryState? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0 else {
                continue
            }
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutesKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = description[minutesKey] as? Int ?? 0
            return UTMHostBatteryState(isACOnline: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                       isCharging: isCharging,
                                       percent: min(capacity * 100 / maxCapacity, 100),
                                       minutesRemaining: max(minutes, 0))
        }
        return nil
    }
}

/// Calls back on the main run loop whenever the host's power sources change.
final class UTMHostBatteryObserver {
    private var runLoopSource: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else {
                return
            }
            Unmanaged<UTMHostBatteryObserver>.fromOpaque(context).takeUnretainedValue().onChange()
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}

extension UTMQemuVirtualMachine {
    @MainActor func startHostBatterySync() async {
        guard config.isHostBatteryUsed else {
            return
        }
        hostBatteryObserver = UTMHostBatteryObserver { [weak self] in
            Task {
                await self?.pushHostBattery()
            }
        }
        await pushHostBattery()
    }
    
    @MainActor func stopHostBatterySync() {
        hostBatteryObserver = nil
        hostBatteryPushed = nil
        needsHostBatteryPush = false
    }
    
    /// Runs one push at a time: a change during a push makes it run again with the latest state.
    @MainActor private func pushHostBattery() async {
        guard !isPushingHostBattery else {
            needsHostBatteryPush = true
            return
        }
        isPushingHostBattery = true
        defer {
            isPushingHostBattery = false
        }
        repeat {
            needsHostBatteryPush = false
            await sendHostBatteryChanges()
        } while needsHostBatteryPush
    }
    
    @MainActor private func sendHostBatteryChanges() async {
        guard state == .started, let battery = UTMHostBatteryState.current, battery != hostBatteryPushed, let monitor = await monitor else {
            return
        }
        let previous = hostBatteryPushed
        hostBatteryPushed = battery
        // minutes-remaining goes last: the device derives the guest's rate from the final state
        var properties: [(String, String)] = []
        if previous?.isACOnline != battery.isACOnline {
            properties.append(("ac-online", String(battery.isACOnline)))
        }
        if previous?.isCharging != battery.isCharging {
            properties.append(("charging", String(battery.isCharging)))
        }
        if previous?.percent != battery.percent {
            properties.append(("percent", String(battery.percent)))
        }
        if previous?.minutesRemaining != battery.minutesRemaining {
            properties.append(("minutes-remaining", String(battery.minutesRemaining)))
        }
        do {
            for (property, value) in properties {
                // HMP reports failures in the returned text, not as an error
                let result = try await monitor.qomSetPath("/machine/peripheral/utm-battery", property: property, value: value)
                if result.hasPrefix("Error") {
                    logger.error("Cannot set host battery \(property): \(result)")
                }
            }
            logger.debug("Host battery \(battery)")
        } catch {
            logger.error("Error updating host battery: \(error)")
        }
    }
}
#endif
