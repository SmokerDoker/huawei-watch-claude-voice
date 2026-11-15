import Foundation

// Stage 1 of the health sync: asks the watch which fitness data it hands out and shows the raw answers.
// Commands follow Gadgetbridge (devices/huawei/packets/FitnessData.java, service 0x07):
//   0x03 totals today · 0x0A/0x0B step records count/data · 0x0C/0x0D sleep records count/data
// Nothing is written to the watch; reading these records does not delete them.
@MainActor
enum HealthProbe {
    static let service: UInt8 = 0x07
    enum Command {
        static let totals: UInt8 = 0x03
        static let stepCount: UInt8 = 0x0A
        static let stepData: UInt8 = 0x0B
        static let sleepCount: UInt8 = 0x0C
        static let sleepData: UInt8 = 0x0D
    }

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func be16(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// Nested TLV under `tag`, if the value parses as TLV.
    static func object(_ tlv: HuaweiTLV?, _ tag: UInt8) -> HuaweiTLV? {
        guard let bytes = tlv?.value(tag) else { return nil }
        return try? HuaweiTLV.parse(bytes)
    }

    static func objects(_ tlv: HuaweiTLV?, _ tag: UInt8) -> [HuaweiTLV] {
        (tlv?.items ?? []).filter { $0.tag == tag }.compactMap { try? HuaweiTLV.parse($0.value) }
    }

    static func run(_ session: HuaweiSession, watchInfo: [String]) async -> String {
        var out: [String] = ["=== HuaSideload health diagnostics ===",
                             "Date: \(ISO8601DateFormatter().string(from: Date()))"]
        out += watchInfo.map { "Watch: \($0)" }

        func ask(_ command: UInt8, _ tlv: HuaweiTLV, _ label: String) async -> HuaweiTLV? {
            do {
                let packet = try await session.request(service, command, tlv, label: "Health: \(label)", timeout: 8)
                guard let response = packet.tlv else {
                    out.append("\(label): answer without TLV")
                    return nil
                }
                out.append("\(label) raw: \(response.description)")
                if let code = response.int(0x7F), code != HuaweiPacket.resultSuccess {
                    out.append("\(label): watch error code \(String(format: "0x%X", code))")
                }
                return response
            } catch {
                out.append("\(label): \(error)")
                return nil
            }
        }

        // 1. Totals for today
        if let totals = await ask(Command.totals, HuaweiTLV().with(0x01), "Totals today") {
            var steps = 0, calories = 0, distance = 0
            for entry in objects(object(totals, 0x81), 0x83) {
                steps += entry.int(0x05) ?? 0
                calories += entry.int(0x06) ?? 0
                distance += entry.int(0x07) ?? 0
            }
            out.append("→ steps \(steps), calories \(calories), distance \(distance) m")
        }

        let now = Int(Date().timeIntervalSince1970)

        // 2. Step records of the last 24 h, 3. sleep records of the last 48 h
        for (name, countCommand, dataCommand, hours) in [("Steps", Command.stepCount, Command.stepData, 24),
                                                        ("Sleep", Command.sleepCount, Command.sleepData, 48)] {
            let range = HuaweiTLV().with(0x81).with(0x03, be32(now - hours * 3600)).with(0x04, be32(now))
            guard let countReply = await ask(countCommand, range, "\(name) count (\(hours) h)") else { continue }
            let count = object(countReply, 0x81)?.int(0x02) ?? 0
            out.append("→ \(name.lowercased()) records: \(count)")
            for index in 0..<min(count, 3) {
                let request = HuaweiTLV().with(0x81, HuaweiTLV().with(0x02, be16(index)).serialize())
                guard let data = await ask(dataCommand, request, "\(name) record \(index)") else { continue }
                if name == "Sleep" {
                    for entry in objects(object(data, 0x81), 0x83) {
                        out.append("  sleep type \(entry.int(0x04) ?? -1) at \(entry.value(0x05)?.hexCompact ?? "?")")
                    }
                } else if let container = object(data, 0x81) {
                    let start = container.int(0x03).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    out.append("  block start \(start.map { ISO8601DateFormatter().string(from: $0) } ?? "?"), "
                               + "\(objects(container, 0x84).count) sub-records")
                }
            }
        }
        // 4. TruSleep file (stage 3)
        let files = SleepFiles(session: session)
        do {
            let nights = try await files.truSleepSessions(from: now - 3 * 86400, to: now)
            out += files.log.map { "TruSleep: \($0)" }
            let formatter = ISO8601DateFormatter()
            for night in nights {
                out.append("  night \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(night.start)))) – "
                           + "\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(night.end)))) (\(night.minutes) min)")
            }
        } catch {
            out += files.log.map { "TruSleep: \($0)" }
            out.append("TruSleep: \(error)")
        }
        out.append("=== end ===")
        return out.joined(separator: "\n")
    }
}
