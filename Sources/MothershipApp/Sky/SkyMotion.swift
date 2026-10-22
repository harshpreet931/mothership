import AppKit
import BackdropKit
import IOKit.ps
import Observation

/// Settings → Appearance → Motion.
enum SkyMotion: String, CaseIterable, Sendable {
    case full, subtle, off

    var title: String {
        switch self {
        case .full: "Full"
        case .subtle: "Subtle"
        case .off: "Off"
        }
    }

    /// The saved setting. Subtle by default; the old "Animate sky" switch, when it was
    /// turned off, becomes Off.
    static func stored(in defaults: UserDefaults) -> SkyMotion {
        if let raw = defaults.string(forKey: PreferenceKey.skyMotion), let motion = SkyMotion(rawValue: raw) { return motion }
        if defaults.object(forKey: PreferenceKey.skyAnimates) as? Bool == false { return .off }
        return .subtle
    }
}

/// How much the backdrop moves, from the setting and what the Mac is doing.
enum MotionPolicy {
    /// - Off, Low Power Mode, or two minutes with Mothership in the background: still.
    /// - A theme gallery hover: full, so the preview shows the theme as it really moves.
    /// - On battery: Full eases to Subtle; Subtle (the default, already cheap) keeps moving,
    ///   so a laptop never shows a frozen sky out of the box.
    /// Hidden, minimized and occluded windows stop entirely (`SkyBackdropView`), and
    /// Reduce Motion shows a still frame whatever this says.
    static func level(setting: SkyMotion, onBattery: Bool, lowPower: Bool, idle: Bool, previewing: Bool) -> BackdropView.MotionLevel {
        if setting == .off || lowPower || idle { return .still }
        if previewing { return .full }
        let chosen: BackdropView.MotionLevel = setting == .full ? .full : .subtle
        return onBattery ? .subtle : chosen
    }

    /// Why the sky moves less than the setting asks right now, for Settings (nil: it doesn't).
    @MainActor
    static func reduction(setting: SkyMotion, conditions: MotionConditions) -> String? {
        guard setting != .off else { return nil }
        if SkyAccessibility.reduceMotion { return "Still now: Reduce Motion is on" }
        if conditions.lowPower { return "Still now: Low Power Mode is on" }
        if conditions.onBattery, setting == .full { return "Subtle now: on battery" }
        return nil
    }
}

/// What the Mac is doing that the backdrop's motion depends on: battery, Low Power Mode,
/// and whether Mothership has been in the background for a while.
///
/// `MOTHERSHIP_POWER=battery|lowpower|ac` (debug) pretends, to check the policy.
@MainActor
@Observable
final class MotionConditions {
    static let shared = MotionConditions()
    /// How long Mothership can sit in the background before the sky holds still.
    static let idleAfter: TimeInterval = 120

    private(set) var onBattery = false
    private(set) var lowPower = false
    /// Not frontmost for `idleAfter`; cleared as soon as it's active again.
    private(set) var idle = false

    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private let simulated = ProcessInfo.processInfo.environment["MOTHERSHIP_POWER"]

    func start() {
        guard !started else { return }
        started = true
        refreshPower()
        // Power source changes (plugging in, unplugging) arrive on the main run loop.
        if simulated == nil, let source = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionConditions.shared.refreshPower() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionConditions.shared.resignedActive() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MotionConditions.shared.becameActive() }
        })
        if !NSApp.isActive { resignedActive() }
    }

    fileprivate func refreshPower() {
        let battery: Bool, low: Bool
        switch simulated {
        case "battery": (battery, low) = (true, false)
        case "lowpower": (battery, low) = (true, true)
        case "ac": (battery, low) = (false, false)
        default: (battery, low) = (Self.isOnBattery, ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        if battery != onBattery { onBattery = battery }
        if low != lowPower { lowPower = low }
    }

    private func resignedActive() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleAfter, repeats: false) { _ in
            MainActor.assumeIsolated { MotionConditions.shared.becameIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func becameIdle() {
        idleTimer = nil
        if !NSApp.isActive, !idle { idle = true }
    }

    private func becameActive() {
        idleTimer?.invalidate()
        idleTimer = nil
        if idle { idle = false }
    }

    /// Whether the Mac is running on its battery (false on desktops and when plugged in).
    private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// IOKit's power source callback; it runs on the main run loop it was added to.
private func powerSourcesChanged(_: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { MotionConditions.shared.refreshPower() }
}
