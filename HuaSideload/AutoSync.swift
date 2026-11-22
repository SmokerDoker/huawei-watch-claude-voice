import BackgroundTasks
import Foundation

// Health sync without opening the app: when the watch (re)connects, and from an iOS background refresh task
// (iOS decides when; usually a few times a day while the phone is charging or idle). Only syncs when the last sync
// is older than `interval`, and only while the watch connection is paired.
enum AutoSync {
    static let taskId = "huasideload.health-sync"
    static let interval: TimeInterval = 2 * 3600

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            schedule()
            let work = Task { @MainActor in
                await runSync(reason: "background")
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor static func syncIfDue(reason: String) {
        Task { await runSync(reason: reason) }
    }

    @MainActor private static func runSync(reason: String) async {
        let store = HealthStore.shared
        // a background launch restores the Bluetooth connection first (WatchLink.reconnectLastWatch): give it a moment
        for _ in 0..<20 where !WatchLink.shared.isPaired && reason == "background" {
            try? await Task.sleep(for: .seconds(1))
        }
        let last = TimeInterval(store.data.lastSync ?? 0)
        guard WatchLink.shared.isPaired, !store.syncing, Date().timeIntervalSince1970 - last > interval else { return }
        await WatchLink.shared.syncHealth()
        UserDefaults.standard.set("\(reason) \(Date().formatted(date: .abbreviated, time: .shortened))", forKey: "autoSync.last")
    }
}
