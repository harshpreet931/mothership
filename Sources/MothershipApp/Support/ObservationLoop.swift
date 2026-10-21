import Observation

/// Re-runs `body` whenever any `@Observable` property it read changes, on the main actor.
/// AppKit views use it to follow the model without SwiftUI.
@MainActor
final class ObservationLoop {
    private var active = true
    private var scheduled = false
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() {
        active = false
    }

    private func run() {
        guard active else { return }
        scheduled = false
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // Coalesce a burst of changes into one pass.
                guard let self, !self.scheduled else { return }
                self.scheduled = true
                self.run()
            }
        }
    }
}
