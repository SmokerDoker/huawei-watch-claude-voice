import Foundation
import HealthKit

// Writes the watch data into Apple Health: steps, distance, active energy, heart rate, SpO2 and the TruSleep
// nights (as "asleep", without phases). Every sample carries a sync identifier, so exporting again replaces
// instead of duplicating. Needs the HealthKit entitlement: install the "-health" IPA (see ANLEITUNG.md).
@MainActor
final class AppleHealth: ObservableObject {
    static let shared = AppleHealth()

    @Published private(set) var status: String?
    @Published private(set) var exporting = false
    @Published var autoExport = UserDefaults.standard.bool(forKey: "appleHealth.auto") {
        didSet { UserDefaults.standard.set(autoExport, forKey: "appleHealth.auto") }
    }
    private var exportedUntil: Int {
        get { UserDefaults.standard.integer(forKey: "appleHealth.exportedUntil") }
        set { UserDefaults.standard.set(newValue, forKey: "appleHealth.exportedUntil") }
    }

    private let store = HKHealthStore()
    private let steps = HKQuantityType(.stepCount)
    private let distance = HKQuantityType(.distanceWalkingRunning)
    private let energy = HKQuantityType(.activeEnergyBurned)
    private let heart = HKQuantityType(.heartRate)
    private let oxygen = HKQuantityType(.oxygenSaturation)
    private let sleep = HKCategoryType(.sleepAnalysis)

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Exports everything newer than the last export (all = from the beginning of the data on the phone).
    func export(_ data: HealthData, all: Bool = false) async {
        guard available else { status = L("Apple Health is not available on this device.", "Apple Sağlık bu cihazda yok."); return }
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            try await store.requestAuthorization(toShare: [steps, distance, energy, heart, oxygen, sleep], read: [])
        } catch {
            status = L("No Health access: \(error.localizedDescription) (installed the -health IPA?)",
                       "Sağlık erişimi yok: \(error.localizedDescription)")
            return
        }
        let since = all ? 0 : exportedUntil - 3600   // an hour of overlap: late records replace themselves
        var samples: [HKSample] = []
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for (minute, sample) in data.samples where minute >= since {
            let start = Date(timeIntervalSince1970: TimeInterval(minute)), end = start.addingTimeInterval(60)
            func add(_ type: HKQuantityType, _ quantity: HKQuantity, _ name: String) {
                samples.append(HKQuantitySample(type: type, quantity: quantity, start: start, end: end,
                                                metadata: Self.meta("\(name)-\(minute)")))
            }
            if let v = sample.steps, v > 0 { add(steps, HKQuantity(unit: .count(), doubleValue: Double(v)), "steps") }
            if let v = sample.distance, v > 0 { add(distance, HKQuantity(unit: .meter(), doubleValue: Double(v)), "distance") }
            if let v = sample.calories, v > 0 { add(energy, HKQuantity(unit: .smallCalorie(), doubleValue: Double(v)), "energy") }
            if let v = sample.heartRate, (25...240).contains(v) {
                samples.append(HKQuantitySample(type: heart, quantity: HKQuantity(unit: bpm, doubleValue: Double(v)),
                                                start: start, end: start, metadata: Self.meta("hr-\(minute)")))
            }
            if let v = sample.spo2, (70...100).contains(v) {
                samples.append(HKQuantitySample(type: oxygen, quantity: HKQuantity(unit: .percent(), doubleValue: Double(v) / 100),
                                                start: start, end: start, metadata: Self.meta("spo2-\(minute)")))
            }
        }
        for night in data.truSleep where night.end >= since {
            samples.append(HKCategorySample(type: sleep, value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(night.start)),
                                            end: Date(timeIntervalSince1970: TimeInterval(night.end)),
                                            metadata: Self.meta("sleep-\(night.start)")))
        }
        do {
            var index = 0
            while index < samples.count {
                let chunk = Array(samples[index..<min(index + 500, samples.count)])
                try await store.save(chunk)
                index += chunk.count
            }
            exportedUntil = data.samples.keys.max() ?? exportedUntil
            status = L("Apple Health: \(samples.count) values written.", "Apple Sağlık: \(samples.count) değer yazıldı.")
        } catch {
            status = L("Apple Health export failed: \(error.localizedDescription)", "Apple Sağlık aktarımı başarısız: \(error.localizedDescription)")
        }
    }

    private static func meta(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: "huasideload-" + id, HKMetadataKeySyncVersion: 1]
    }
}
