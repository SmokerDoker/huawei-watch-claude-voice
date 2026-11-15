import Foundation

// Health sync stage 2: pulls the per-minute activity records (steps, calories, distance, heart rate, SpO2)
// and the sleep segments from the watch and keeps them on the iPhone.
// Protocol and decoding follow Gadgetbridge (FitnessData.MessageData.StepResponse / SleepResponse).

struct MinuteSample: Codable, Equatable {
    var steps: Int?
    var calories: Int?      // small calories (cal); 1000 = 1 kcal
    var distance: Int?      // metres
    var heartRate: Int?     // bpm
    var spo2: Int?          // %
}

struct SleepSegment: Codable, Hashable {
    var start: Int          // unix seconds
    var minutes: Int
    var type: Int           // raw watch type (seen on GT 3 Pro: 1 and 3)
}

struct HealthData: Codable {
    var samples: [Int: MinuteSample] = [:]   // key: unix minute start
    var sleep: [SleepSegment] = []
    var lastSync: Int?
}

@MainActor
final class HealthStore: ObservableObject {
    static let shared = HealthStore()

    @Published private(set) var data = HealthData()
    @Published private(set) var status: String?
    @Published private(set) var syncing = false

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("health.json")
    }()

    private init() {
        if let raw = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(HealthData.self, from: raw) {
            data = saved
        }
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Decoding

    /// Per-minute record: feature bitmap(s) followed by the values the bitmap announces.
    static func decodeMinute(_ bytes: [UInt8]) -> MinuteSample? {
        guard let first = bytes.first else { return nil }
        var i = 1
        var second: UInt8 = 0
        if first & 0x80 != 0 {
            guard bytes.count > i else { return nil }
            second = bytes[i]
            i += 1
        }
        var sample = MinuteSample()
        var bit: UInt8 = 1
        while bit < 0x80 {
            if first & bit != 0 {
                let value: Int
                if bit == 0x20 || bit == 0x40 {           // single-byte fields
                    guard bytes.count > i else { return nil }
                    value = Int(bytes[i]); i += 1
                } else {
                    guard bytes.count > i + 1 else { return nil }
                    value = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
                }
                switch bit {
                case 0x02: sample.steps = value
                case 0x04: sample.calories = value
                case 0x08: sample.distance = value
                case 0x40: sample.heartRate = value
                default: break
                }
            }
            bit <<= 1
        }
        var bit2: UInt8 = 1
        for _ in 0..<8 {
            if second & bit2 != 0 {
                guard bytes.count > i else { return nil }
                if bit2 == 0x01 { sample.spo2 = Int(bytes[i]) }
                i += 1
            }
            bit2 = bit2 &<< 1
        }
        return sample == MinuteSample() ? nil : sample
    }

    // MARK: - Sync

    func sync(_ session: HuaweiSession) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let now = Int(Date().timeIntervalSince1970)
        // first sync: last 7 days; afterwards from the last sync with one hour overlap
        let from = max((data.lastSync ?? 0) - 3600, now - 7 * 86400)
        var newMinutes = 0, newSleep = 0
        do {
            status = L("Reading activity…", "Aktivite okunuyor…")
            for block in try await records(session, count: HealthProbe.Command.stepCount,
                                           data: HealthProbe.Command.stepData, from: from, to: now) {
                guard let start = block.int(0x03) else { continue }
                for entry in HealthProbe.objects(block, 0x84) {
                    guard let offset = entry.int(0x05), let raw = entry.value(0x06),
                          let sample = Self.decodeMinute(raw) else { continue }
                    let key = start + offset * 60
                    if data.samples[key] != sample { newMinutes += 1 }
                    data.samples[key] = sample
                }
            }
            status = L("Reading sleep…", "Uyku okunuyor…")
            var segments = Set(data.sleep)
            for block in try await records(session, count: HealthProbe.Command.sleepCount,
                                           data: HealthProbe.Command.sleepData, from: from, to: now) {
                for entry in HealthProbe.objects(block, 0x83) {
                    guard let type = entry.int(0x04), let ts = entry.value(0x05), ts.count == 6 else { continue }
                    let start = ts[0..<4].reduce(0) { $0 << 8 | Int($1) }
                    let minutes = Int(ts[4]) << 8 | Int(ts[5])
                    if segments.insert(SleepSegment(start: start, minutes: minutes, type: type)).inserted { newSleep += 1 }
                }
            }
            data.sleep = segments.sorted { $0.start < $1.start }
            // keep 90 days on the phone
            let cutoff = now - 90 * 86400
            data.samples = data.samples.filter { $0.key >= cutoff }
            data.sleep.removeAll { $0.start < cutoff }
            data.lastSync = now
            save()
            status = L("Synced: \(newMinutes) new minutes, \(newSleep) sleep segments.",
                       "Eşitlendi: \(newMinutes) yeni dakika, \(newSleep) uyku bölümü.")
        } catch {
            save()
            status = L("Sync stopped: \(error)", "Eşitleme durdu: \(error)")
        }
    }

    /// Asks how many records lie in the range, then fetches them one by one (each answer is the 0x81 container).
    private func records(_ session: HuaweiSession, count countCommand: UInt8, data dataCommand: UInt8,
                         from: Int, to: Int) async throws -> [HuaweiTLV] {
        let range = HuaweiTLV().with(0x81).with(0x03, HealthProbe.be32(from)).with(0x04, HealthProbe.be32(to))
        let countPacket = try await session.request(HealthProbe.service, countCommand, range,
                                                    label: "Health count", timeout: 8, quiet: true)
        let count = HealthProbe.object(countPacket.tlv, 0x81)?.int(0x02) ?? 0
        var result: [HuaweiTLV] = []
        for index in 0..<count {
            let request = HuaweiTLV().with(0x81, HuaweiTLV().with(0x02, HealthProbe.be16(index)).serialize())
            let packet = try await session.request(HealthProbe.service, dataCommand, request,
                                                   label: "Health record", timeout: 8, quiet: true)
            if let container = HealthProbe.object(packet.tlv, 0x81) { result.append(container) }
        }
        return result
    }

    // MARK: - Summaries

    struct DaySummary {
        var steps = 0, calories = 0, distance = 0
        var heartRates: [Int] = []
        var spo2: [Int] = []
        var lastHeartRate: (time: Date, bpm: Int)?
    }

    func summary(for day: Date) -> DaySummary {
        let calendar = Calendar.current
        let start = Int(calendar.startOfDay(for: day).timeIntervalSince1970)
        let end = start + 86400
        var s = DaySummary()
        for (key, sample) in data.samples where key >= start && key < end {
            s.steps += sample.steps ?? 0
            s.calories += sample.calories ?? 0
            s.distance += sample.distance ?? 0
            if let hr = sample.heartRate, hr > 0 {
                s.heartRates.append(hr)
                if key >= Int(s.lastHeartRate?.time.timeIntervalSince1970 ?? 0) {
                    s.lastHeartRate = (Date(timeIntervalSince1970: TimeInterval(key)), hr)
                }
            }
            if let o = sample.spo2, o > 0 { s.spo2.append(o) }
        }
        return s
    }

    /// Sleep segments between 18:00 the day before and 14:00 on `day`.
    func sleep(endingOn day: Date) -> [SleepSegment] {
        let morning = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970)
        return data.sleep.filter { $0.start >= morning - 6 * 3600 && $0.start < morning + 14 * 3600 }
    }

    /// Plain-text summary for the last `days` days (used by the Claude bridge in stage 4).
    func textSummary(days: Int = 7) -> String {
        let calendar = Calendar.current
        var lines: [String] = []
        for back in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let s = summary(for: day)
            let sleepMinutes = sleep(endingOn: day).reduce(0) { $0 + $1.minutes }
            let hr = s.heartRates.isEmpty ? "-" : "\(s.heartRates.min()!)–\(s.heartRates.max()!) (Ø \(s.heartRates.reduce(0, +) / s.heartRates.count))"
            let dayText = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            lines.append("\(dayText): \(s.steps) steps, \(s.calories / 1000) kcal, \(s.distance) m, HR \(hr), sleep segments \(sleepMinutes) min")
        }
        return lines.joined(separator: "\n")
    }
}
