import AppKit
import CoreLocation
import Observation

/// Where the sun is for the sky: recomputed every 60 s from the clock and approximate
/// coordinates (or the Mac's location, when the user turns that on).
///
/// `MOTHERSHIP_SKY_TIME=HH:MM` (debug) pins the time of day.
@MainActor
@Observable
final class SkyClock {
    private(set) var sun: SunPosition
    /// "Animate sky" (Settings → Appearance). Reduce Motion and Low Power still win.
    var animates: Bool = PreferenceStore.defaults.object(forKey: PreferenceKey.skyAnimates) as? Bool ?? true {
        didSet { PreferenceStore.defaults.set(animates, forKey: PreferenceKey.skyAnimates) }
    }
    /// "Use my location": off by default; the time zone is a good enough guess.
    var usesLocation: Bool = PreferenceStore.defaults.bool(forKey: PreferenceKey.skyUsesLocation) {
        didSet {
            PreferenceStore.defaults.set(usesLocation, forKey: PreferenceKey.skyUsesLocation)
            updateLocator()
        }
    }
    /// Nil until CoreLocation answers (or when it can't).
    private(set) var locationNote: String?

    @ObservationIgnored private var fixedTime: (hour: Int, minute: Int)?
    @ObservationIgnored private var coordinates = ApproximateLocation.current()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var locator: SkyLocator?

    init() {
        let location = ApproximateLocation.current()
        sun = SunPosition.at(Date(), latitude: location.latitude, longitude: location.longitude)
    }

    /// Debug: "HH:MM" pins the time of day (today's date, local time zone).
    func pinTime(_ text: String) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0 ..< 24).contains(parts[0]), (0 ..< 60).contains(parts[1]) else { return }
        fixedTime = (parts[0], parts[1])
        refresh()
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateLocator()
    }

    func refresh() {
        let fresh = SunPosition.at(now, latitude: coordinates.latitude, longitude: coordinates.longitude)
        if fresh != sun { sun = fresh }
    }

    private var now: Date { pinnedDate ?? Date() }

    /// The pinned time of day (debug), so Home's clock and greeting match the sky.
    var pinnedDate: Date? {
        guard let fixedTime else { return nil }
        return Calendar.current.date(bySettingHour: fixedTime.hour, minute: fixedTime.minute, second: 0, of: Date())
    }

    private func updateLocator() {
        guard timer != nil else { return }
        if usesLocation {
            if locator == nil {
                locator = SkyLocator { [weak self] result in
                    self?.received(result)
                }
            }
            locator?.request()
        } else {
            locator = nil
            locationNote = nil
            coordinates = ApproximateLocation.current()
            refresh()
        }
    }

    private func received(_ result: SkyLocator.Result) {
        switch result {
        case .located(let latitude, let longitude):
            coordinates = (latitude, longitude)
            locationNote = nil
            refresh()
        case .unavailable(let reason):
            locationNote = reason
        }
    }
}

/// One-shot CoreLocation lookup. Coordinates stay in memory; nothing is saved.
@MainActor
final class SkyLocator: NSObject, CLLocationManagerDelegate {
    enum Result: Sendable {
        case located(latitude: Double, longitude: Double)
        case unavailable(String)
    }

    private let manager = CLLocationManager()
    private let onResult: (Result) -> Void

    init(onResult: @escaping (Result) -> Void) {
        self.onResult = onResult
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: onResult(.unavailable("Location is off for Mothership in System Settings"))
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .authorized, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.onResult(.unavailable("Location is off for Mothership in System Settings"))
            default: break
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude, longitude = coordinate.longitude
        MainActor.assumeIsolated { self.onResult(.located(latitude: latitude, longitude: longitude)) }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError _: any Error) {
        MainActor.assumeIsolated { self.onResult(.unavailable("Couldn't find this Mac's location")) }
    }
}
