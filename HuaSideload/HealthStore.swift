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

/// One automatic stress measurement (about every 30 minutes while resting). score 1–99; level 1 relaxed (1–29),
/// 2 normal (30–59), 3 medium (60–79), 4 high (80–99). rri = mean beat interval in ms (one of the HRV values in the record).
struct StressReading: Codable, Hashable {
    var time: Int
    var score: Int
    var level: Int
    var rri: Double?
}

/// Heart rate variability of one night from beat-to-beat intervals: rmssd = mean of 5-minute RMSSD values (ms),
/// heartRate = mean, lowest = lowest 5-minute mean (bpm).
struct NightHRV: Codable, Hashable {
    var rmssd: Int
    var heartRate: Int
    var lowest: Int
    var beats: Int
}

struct HealthData: Codable {
    var samples: [Int: MinuteSample] = [:]   // key: unix minute start
    var sleep: [SleepSegment] = []
    var truSleep: [SleepSession] = []        // stage 3: night sessions from sleep_state.bin
    var stress: [StressReading] = []         // file type 0x10 (found with the PC relay, not in Gadgetbridge)
    var nightHRV: [Int: NightHRV] = [:]      // key: TruSleep night start; from the PPG beat times in sleep_data.bin
    var lastSync: Int?

    init() {}

    // decodeIfPresent everywhere, so files from older versions keep loading
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([Int: MinuteSample].self, forKey: .samples) ?? [:]
        sleep = try c.decodeIfPresent([SleepSegment].self, forKey: .sleep) ?? []
        truSleep = try c.decodeIfPresent([SleepSession].self, forKey: .truSleep) ?? []
        stress = try c.decodeIfPresent([StressReading].self, forKey: .stress) ?? []
        nightHRV = try c.decodeIfPresent([Int: NightHRV].self, forKey: .nightHRV) ?? [:]
        lastSync = try c.decodeIfPresent(Int.self, forKey: .lastSync)
    }
}

@MainActor
final class HealthStore: ObservableObject {
    static let shared = HealthStore()

    @Published private(set) var data = HealthData()
    @Published private(set) var status: String?
    @Published private(set) var syncing = false
    @Published private(set) var truSleepNote: String?
    private(set) var fileLog: [String] = []

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

    /// Next sync reaches back 30 days again (data already stored is kept and merged).
    func fullResync(_ session: HuaweiSession) async {
        data.lastSync = nil
        await sync(session)
    }

    func sync(_ session: HuaweiSession) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let now = Int(Date().timeIntervalSince1970)
        // first sync: last 30 days (the watch hands out whatever it still has); afterwards from the last sync
        let from = max((data.lastSync ?? 0) - 3600, now - 30 * 86400)
        var newMinutes = 0, newSleep = 0, newNights = 0
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

            status = L("Reading TruSleep…", "TruSleep okunuyor…")
            let files = SleepFiles(session: session)
            do {
                for night in try await files.truSleepSessions(from: from - 86400, to: now) {
                    if data.truSleep.contains(night) { continue }
                    // a night still in progress shows up again later with a later end: keep the longer one
                    let overlapping = data.truSleep.filter { $0.start < night.end && night.start < $0.end }
                    if overlapping.contains(where: { $0.minutes >= night.minutes }) { continue }
                    data.truSleep.removeAll { overlapping.contains($0) }
                    data.truSleep.append(night)
                    newNights += 1
                }
                data.truSleep.sort { $0.start < $1.start }
                truSleepNote = nil
            } catch {
                truSleepNote = "TruSleep: \(error)"
            }
            let missingHRV = data.truSleep.filter { data.nightHRV[$0.start] == nil && $0.end > now - 7 * 86400 }
            if let newest = missingHRV.last {
                status = L("Reading heart rate variability…", "Nabız değişkenliği okunuyor…")
                if let raw = try? await files.truSleepRawData(from: newest.start, to: newest.end) {
                    let beats = SleepFiles.beatTimes(raw)
                    for night in missingHRV {
                        if let hrv = SleepFiles.hrv(beats, from: night.start, to: night.end) { data.nightHRV[night.start] = hrv }
                    }
                }
            }
            status = L("Reading stress…", "Stres okunuyor…")
            let stressFrom = max((data.stress.last?.time ?? 0) + 1, now - 14 * 86400)
            if let readings = try? await files.stress(from: stressFrom, to: now) {
                let known = Set(data.stress.map(\.time))
                data.stress += readings.filter { !known.contains($0.time) }
                data.stress.sort { $0.time < $1.time }
            }
            fileLog = files.log
            // keep 90 days on the phone
            let cutoff = now - 90 * 86400
            data.samples = data.samples.filter { $0.key >= cutoff }
            data.sleep.removeAll { $0.start < cutoff }
            data.truSleep.removeAll { $0.start < cutoff }
            data.stress.removeAll { $0.time < cutoff }
            data.nightHRV = data.nightHRV.filter { $0.key >= cutoff }
            data.lastSync = now
            save()
            status = L("Synced: \(newMinutes) new minutes, \(newSleep) sleep segments, \(newNights) TruSleep nights.",
                       "Eşitlendi: \(newMinutes) yeni dakika, \(newSleep) uyku bölümü, \(newNights) TruSleep gecesi.")
                + (truSleepNote.map { "\n" + $0 } ?? "")
            if AppleHealth.shared.autoExport { await AppleHealth.shared.export(data) }
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

    /// Resting heart rate of the day: lowest 10-minute average of the readings (the watch measures every few minutes),
    /// ignoring windows with fewer than 3 readings. Huawei's own value is not available over this protocol.
    func restingHeartRate(for day: Date) -> Int? {
        let start = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970) - 6 * 3600   // includes the night
        let end = start + 30 * 3600
        let readings = data.samples.filter { $0.key >= start && $0.key < end }
            .compactMap { key, sample in sample.heartRate.flatMap { (30...200).contains($0) ? (key, $0) : nil } }
            .sorted { $0.0 < $1.0 }
        var best: Double?
        var j = 0
        for i in readings.indices {
            while readings[i].0 - readings[j].0 >= 600 { j += 1 }
            let window = readings[j...i]
            guard window.count >= 3 else { continue }
            let mean = Double(window.reduce(0) { $0 + $1.1 }) / Double(window.count)
            if best == nil || mean < best! { best = mean }
        }
        return best.map { Int($0.rounded()) }
    }

    /// Sleep segments between 18:00 the day before and 14:00 on `day`.
    func sleep(endingOn day: Date) -> [SleepSegment] {
        let morning = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970)
        return data.sleep.filter { $0.start >= morning - 6 * 3600 && $0.start < morning + 14 * 3600 }
    }

    // MARK: - Raw sleep export (for working out sleep phases)

    @Published private(set) var exportedFiles: [URL] = []

    private var exportDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sleep-export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stamp(_ night: SleepSession) -> String {
        Date(timeIntervalSince1970: TimeInterval(night.start))
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }

    /// Deletes all exported files on the phone (so every night is downloaded again).
    func clearExports() {
        try? FileManager.default.removeItem(at: exportDir)
        refreshExportedFiles()
        status = L("Exported files deleted.", "Dışa aktarılan dosyalar silindi.")
    }

    /// Nights already exported (files present).
    /// A night counts as exported once a buffer export reached past its end.
    func isExported(_ night: SleepSession) -> Bool {
        night.end <= UserDefaults.standard.integer(forKey: "export.coveredUntil")
    }

    /// All exported files, newest first.
    func refreshExportedFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)) ?? []
        exportedFiles = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Saves the watch's whole sleep buffer as it is: sleep_data (about one week of raw sensor data), sleep_state
    /// (30 days of sessions) and the stress file. One set of files per export; overlapping exports are fine, the
    /// research tools de-duplicate by timestamp. (Cutting the buffer into nights lost blocks of interrupted nights.)
    func exportNights(_ session: HuaweiSession) async {
        guard !syncing else { return }
        guard let newest = data.truSleep.last else {
            status = L("Sync first: no TruSleep night yet.", "Önce eşitle: henüz TruSleep gecesi yok.")
            return
        }
        syncing = true
        defer { syncing = false; refreshExportedFiles() }
        status = L("Downloading the sleep buffer… (about a minute)", "Uyku verisi indiriliyor…")
        let files = SleepFiles(session: session)
        let now = Int(Date().timeIntervalSince1970)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        do {
            // the exact window of a stored session is what the watch accepts; it answers with everything it has
            let raw = try await files.truSleepRawData(from: newest.start, to: newest.end)
            let state = try await files.truSleepStateRaw(from: now - 30 * 86400, to: now)
            try Data(raw).write(to: exportDir.appendingPathComponent("sleep_data_\(stamp).bin"))
            try Data(state).write(to: exportDir.appendingPathComponent("sleep_state_\(stamp).bin"))
            let covered = SleepFiles.dataTimeRange(raw)
            if let last = covered?.last {
                UserDefaults.standard.set(max(last, UserDefaults.standard.integer(forKey: "export.coveredUntil")), forKey: "export.coveredUntil")
            }
            let span = covered.map {
                Date(timeIntervalSince1970: TimeInterval($0.first)).formatted(date: .abbreviated, time: .shortened) + " – "
                    + Date(timeIntervalSince1970: TimeInterval($0.last)).formatted(date: .abbreviated, time: .shortened)
            } ?? "–"
            status = L("Exported the sleep buffer (\(raw.count / 1024) KB): \(span)", "Uyku verisi dışa aktarıldı (\(raw.count / 1024) KB): \(span)")
        } catch {
            status = L("Export failed: \(error)", "Dışa aktarma başarısız: \(error)") + "\n" + files.log.joined(separator: "\n")
        }
    }

    /// TruSleep sessions that end between 18:00 the day before and 14:00 on `day`.
    func truSleep(endingOn day: Date) -> [SleepSession] {
        let morning = Int(Calendar.current.startOfDay(for: day).timeIntervalSince1970)
        return data.truSleep.filter { $0.end >= morning - 6 * 3600 && $0.end < morning + 14 * 3600 }
    }

    /// Plain-text summary for the last `days` days (used by the Claude bridge in stage 4).
    func textSummary(days: Int = 7) -> String {
        let calendar = Calendar.current
        var lines: [String] = []
        for back in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let s = summary(for: day)
            let nights = truSleep(endingOn: day)
            let sleepMinutes = nights.isEmpty ? sleep(endingOn: day).reduce(0) { $0 + $1.minutes }
                                              : nights.reduce(0) { $0 + $1.minutes }
            let hr = s.heartRates.isEmpty ? "-" : "\(s.heartRates.min()!)–\(s.heartRates.max()!) (Ø \(s.heartRates.reduce(0, +) / s.heartRates.count))"
            let dayText = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            lines.append("\(dayText): \(s.steps) steps, \(s.calories / 1000) kcal, \(s.distance) m, HR \(hr), sleep \(sleepMinutes) min\(nights.isEmpty ? " (segments)" : " (TruSleep)")")
        }
        return lines.joined(separator: "\n")
    }
}
