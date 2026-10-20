import Foundation
import IOKit.ps

/// What the Mac's power looks like right now: on battery or not, Low Power Mode, and heat.
/// macOS tells Unwine when any of these change, so nothing here polls.
@MainActor
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private(set) var thermal: ProcessInfo.ThermalState = .nominal

    /// True when games should save battery: on battery, in Low Power Mode, or while the Mac is hot.
    var savesBattery: Bool { onBattery || lowPowerMode || thermal == .serious || thermal == .critical }

    /// A short reason for the UI, or nil when nothing asks to save battery.
    var reason: String? {
        if lowPowerMode { return "Low Power Mode is on" }
        if onBattery { return "Your Mac is on battery" }
        if thermal == .serious || thermal == .critical { return "Your Mac is hot" }
        return nil
    }

    private var source: CFRunLoopSource?
    private var handlers: [@MainActor () -> Void] = []

    private init() {
        read()
        // Power source: plugged in, unplugged, UPS. The callback runs on the main run loop.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<PowerState>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.read() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
        // Low Power Mode and heat. Both notifications can arrive on any queue.
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PowerState.shared.read() }
            }
        }
    }

    /// Runs `handler` on the main actor each time `savesBattery` flips.
    func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

    private func read() {
        let before = savesBattery
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        onBattery = type == kIOPSBatteryPowerValue
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        if savesBattery != before { for h in handlers { h() } }
    }
}
