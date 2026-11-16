import Foundation

// Workout sync: summary of every workout (Workout service 0x17: count 0x07, totals 0x08) plus the GPS route
// ("<number>_gps.bin", file type 0x11 over the new file sync 0x2C). Protocol and GPS format from Gadgetbridge
// (packets/Workout.java, HuaweiGpsParser.java, HuaweiFileDownloadManager.java). Per-second data and pace are not read yet.

struct WorkoutPoint: Codable, Hashable {
    var time: Int
    var lat: Double
    var lon: Double
    var altitude: Double?
}

struct Workout: Codable, Identifiable, Hashable {
    var number: Int
    var start: Int
    var end: Int
    var type: Int
    var duration: Int?        // seconds of active time
    var distance: Int?        // metres
    var calories: Int?        // cal (1000 = 1 kcal)
    var steps: Int?
    var minHeartRate: Int?
    var maxHeartRate: Int?
    var elevationGain: Int?   // dm? as the watch reports it
    var route: [WorkoutPoint] = []
    var id: Int { start }

    var name: String {
        switch type {
        case 1: L("Run", "Koşu")
        case 2: L("Walk", "Yürüyüş")
        case 3: L("Ride", "Bisiklet")
        case 4: L("Mountain hike", "Dağ yürüyüşü")
        case 5: L("Indoor run", "Kapalı alan koşusu")
        case 6: L("Pool swim", "Havuz yüzme")
        case 7: L("Indoor ride", "Kapalı alan bisiklet")
        case 8: L("Open water swim", "Açık su yüzme")
        case 13: L("Indoor walk", "Kapalı alan yürüyüş")
        case 14: L("Hike", "Doğa yürüyüşü")
        case 21: L("Jump rope", "İp atlama")
        case 134: L("Elliptical", "Eliptik")
        case 135: L("Rowing machine", "Kürek makinesi")
        case 137: "Yoga"
        case 140: L("Strength", "Kuvvet")
        case 143: "HIIT"
        default: L("Workout \(type)", "Antrenman \(type)")
        }
    }
    var activeSeconds: Int { duration.map { $0 > 100_000 ? $0 / 1000 : $0 } ?? (end - start) }
}

@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    @Published private(set) var workouts: [Workout] = []
    @Published private(set) var status: String?
    @Published private(set) var syncing = false

    private let file = URL.documentsDirectory.appending(path: "workouts.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Workout].self, from: data) {
            workouts = saved
        }
    }

    private func save() {
        try? JSONEncoder().encode(workouts).write(to: file, options: .atomic)
    }

    func sync(_ session: HuaweiSession, all: Bool = false) async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false; save() }
        let now = Int(Date().timeIntervalSince1970)
        let from = all ? 1_654_819_200 : (workouts.map(\.end).max() ?? 1_654_819_200) + 1
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        do {
            status = L("Reading workouts…", "Antrenmanlar okunuyor…")
            let countTLV = HuaweiTLV().with(0x81, HuaweiTLV().with(0x03, be32(from)).with(0x04, be32(now)).serialize())
            let count = try await session.request(0x17, 0x07, countTLV, label: "Workout count")
            guard let container = count.tlv?.value(0x81).flatMap({ try? HuaweiTLV.parse($0) }) else {
                throw HuaweiAuthError.unexpected("workout count TLV")
            }
            // with no workouts the watch still sends one placeholder item: only the first `count` (tag 0x02) are real
            let total = container.int(0x02) ?? 0
            let numbers = HealthProbe.objects(container, 0x85).prefix(total).compactMap { $0.int(0x06) }.sorted()
            var added = 0
            for (index, number) in numbers.enumerated() {
                status = L("Workout \(index + 1) of \(numbers.count)…", "Antrenman \(index + 1)/\(numbers.count)…")
                let totals = try await session.request(0x17, 0x08, HuaweiTLV().with(0x81, HuaweiTLV().with(0x02, be16(number)).serialize()),
                                                       label: "Workout totals \(number)")
                guard let t = totals.tlv?.value(0x81).flatMap({ try? HuaweiTLV.parse($0) }),
                      let start = t.int(0x04), let end = t.int(0x05) else { continue }
                let hr = t.value(0x0C)
                var workout = Workout(number: number, start: start, end: end, type: t.int(0x14) ?? 0,
                                      duration: t.int(0x12) ?? t.int(0x09), distance: t.int(0x07), calories: t.int(0x06),
                                      steps: t.int(0x08),
                                      minHeartRate: hr.flatMap { $0.count >= 2 ? Int($0[0]) : nil },
                                      maxHeartRate: hr.flatMap { $0.count >= 2 ? Int($0[1]) : nil },
                                      elevationGain: t.int(0x0B))
                // GPS route (only outdoor workouts have one; an empty file is fine)
                if let gps = try? await SleepFiles(session: session).workoutGPS(number: number), !gps.isEmpty {
                    workout.route = Self.parseGPS(gps)
                }
                workouts.removeAll { $0.start == workout.start }
                workouts.append(workout)
                added += 1
            }
            workouts.sort { $0.start > $1.start }
            status = L("Workouts: \(added) new, \(workouts.count) in total.", "Antrenman: \(added) yeni, toplam \(workouts.count).")
        } catch {
            status = L("Workout sync stopped: \(error)", "Antrenman eşitleme durdu: \(error)")
        }
    }

    /// HuaweiGpsParser.parseHuaweiGps: header with the start point, then deltas in metres (float) per point.
    static func parseGPS(_ data: [UInt8]) -> [WorkoutPoint] {
        var i = 0x20
        func u8() -> UInt8 { defer { i += 1 }; return data[i] }
        func i16() -> Int { defer { i += 2 }; return Int(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)) }
        func u32() -> UInt32 { defer { i += 4 }; return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[i + $1]) << (8 * $1) } }
        func f32() -> Double { Double(Float(bitPattern: u32())) }
        func f64() -> Double {
            defer { i += 8 }
            return Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[i + $1]) << (8 * $1) })
        }
        guard data.count > 70 else { return [] }
        let fileType = u8()
        let altitude = fileType & 0x03 == 0x03
        var time = Int(Int32(bitPattern: u32()))
        let lonStart = f64() * 0.017453292519943
        let latStart = f64() * 0.017453292519943
        if altitude { _ = f64() }
        i = altitude ? 70 : 62
        var lat = 0.0, lon = 0.0
        var points: [WorkoutPoint] = []
        let size = altitude ? 19 : 15
        while data.count - i > size {
            let dt = i16(); _ = i16()
            lon += f32(); lat += f32()
            i += 3
            time += dt
            var point = WorkoutPoint(time: time,
                                     lat: (lat / 6383807.0 + latStart) / 0.017453292519943,
                                     lon: (lon / 6383807.0 / cos(latStart) + lonStart) / 0.017453292519943)
            if altitude { point.altitude = Double(i16()); _ = i16() }
            if abs(point.lat) <= 90, abs(point.lon) <= 180 { points.append(point) }
        }
        return points
    }

    /// GPX for sharing (Strava, Komoot, …).
    func gpx(_ workout: Workout) -> URL? {
        guard !workout.route.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="HuaSideload" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(workout.name)</name><trkseg>

        """
        for p in workout.route {
            xml += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            if let a = p.altitude { xml += "<ele>\(a)</ele>" }
            xml += "<time>\(iso.string(from: Date(timeIntervalSince1970: TimeInterval(p.time))))</time></trkpt>\n"
        }
        xml += "</trkseg></trk></gpx>\n"
        let url = FileManager.default.temporaryDirectory.appending(path: "workout-\(workout.start).gpx")
        try? Data(xml.utf8).write(to: url)
        return url
    }
}
