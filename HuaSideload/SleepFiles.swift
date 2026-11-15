import Foundation

// Health sync stage 3: TruSleep. With TruSleep on, the watch keeps the night's sleep in files
// (sleep_state.bin: start/end of each sleep session, sleep_data.bin: raw sensor data).
// Download follows Gadgetbridge's HuaweiFileDownloadManager, both variants:
//   new sync, service 0x2C: init 0x01 → info 0x03 → block request 0x04 → data 0x05 (pushed) → done 0x06
//   old sync, service 0x0A: init 0x01 → parameters 0x02 → info 0x03 → block request 0x04 → data 0x05 → done 0x06
// The GT 3 Pro (pre-HarmonyOS 5) gives no sleep stages, only session start/end (as in Gadgetbridge).

struct SleepSession: Codable, Hashable {
    var start: Int      // unix seconds
    var end: Int
    var minutes: Int { max(0, (end - start) / 60) }
}

enum SleepFilesError: Error, CustomStringConvertible {
    case badAnswer(String)
    case timeout(Int, Int)
    var description: String {
        switch self {
        case .badAnswer(let what): return "unexpected answer (\(what))"
        case .timeout(let got, let want): return "file data stopped at \(got)/\(want) bytes"
        }
    }
}

@MainActor
final class SleepFiles {
    private let session: HuaweiSession
    private var received: [UInt8] = []
    private var target = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var waiterID = UUID()
    private var oldSync = false
    private(set) var log: [String] = []

    init(session: HuaweiSession) { self.session = session }

    // MARK: - Public

    /// TruSleep sessions between `from` and `to` (unix seconds).
    func truSleepSessions(from: Int, to: Int) async throws -> [SleepSession] {
        Self.parseState(try await truSleepStateRaw(from: from, to: to))
    }

    func truSleepStateRaw(from: Int, to: Int) async throws -> [UInt8] {
        let bytes = try await download(name: "sleep_state.bin", newType: 0x0E, from: from, to: to)
        log.append("sleep_state.bin: \(bytes.count) bytes")
        return bytes
    }

    /// Raw TruSleep sensor data (accelerometer per minute, PPG beats) between `from` and `to`, for offline analysis.
    func truSleepRawData(from: Int, to: Int) async throws -> [UInt8] {
        let bytes = try await download(name: "sleep_data.bin", newType: 0x0F, from: from, to: to)
        log.append("sleep_data.bin: \(bytes.count) bytes")
        return bytes
    }

    /// 16-byte records, little endian: start, end, 3 unknown bytes, 5 padding bytes.
    static func parseState(_ bytes: [UInt8]) -> [SleepSession] {
        func le32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        var result: [SleepSession] = []
        var i = 0
        while bytes.count - i >= 16 {
            let start = le32(i), end = le32(i + 4)
            if start > 1_500_000_000, end > start, end - start < 24 * 3600 {
                result.append(SleepSession(start: start, end: end))
            }
            i += 16
        }
        return result
    }

    // MARK: - Download

    private func download(name: String, newType: UInt8, from: Int, to: Int) async throws -> [UInt8] {
        let newSync = await supportsNewSync()
        log.append("file sync: \(newSync.map { $0 ? "new (0x2C)" : "old (0x0A)" } ?? "unknown, trying new (0x2C)")")
        session.onFileBlock = { [weak self] packet in self?.handleBlock(packet) }
        defer { session.onFileBlock = nil }
        if newSync == false {
            return try await downloadOld(name: name, from: from, to: to)
        }
        do {
            return try await downloadNew(name: name, type: newType, from: from, to: to)
        } catch {
            guard newSync == nil else { throw error }
            log.append("new sync failed (\(error)), trying old")
            return try await downloadOld(name: name, from: from, to: to)
        }
    }

    /// DeviceConfig 0x01/0x31 "setting related", tag 2 bit 1 = TruSleep new sync.
    private func supportsNewSync() async -> Bool? {
        let tlv = HuaweiTLV().with(0x01).with(0x02).with(0x03).with(0x04).with(0x05).with(0x06)
        guard let packet = try? await session.request(0x01, 0x31, tlv, label: "File support", timeout: 6, quiet: true),
              let flags = packet.tlv?.value(0x02)?.first else { return nil }
        log.append(String(format: "file support flags 0x%02X", flags))
        return flags & 0x02 != 0
    }

    private func downloadNew(name: String, type: UInt8, from: Int, to: Int) async throws -> [UInt8] {
        oldSync = false
        let initTLV = HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, [type])
            .with(0x05, HealthProbe.be32(from)).with(0x06, HealthProbe.be32(to))
        let initReply = try await session.request(0x2C, 0x01, initTLV, label: "File init", timeout: 10, quiet: true)
        guard let reply = initReply.tlv, let fileId = reply.value(0x03)?.first else {
            throw SleepFilesError.badAnswer("init: \(initReply.tlv?.description ?? initReply.body.hexCompact)")
        }
        let size = reply.int(0x04) ?? 0
        log.append("new sync: file id \(fileId), \(size) bytes")
        guard size > 0 else {
            session.send(0x2C, 0x06, HuaweiTLV().with(0x01, [fileId]).with(0x02, [1]))
            return []
        }
        let infoTLV = HuaweiTLV().with(0x01, [fileId]).with(0x02).with(0x03).with(0x04).with(0x05)
        let info = try await session.request(0x2C, 0x03, infoTLV, label: "File info", timeout: 10, quiet: true)
        let maxBlock = max(info.tlv?.int(0x04) ?? 0, 1024)
        let timeout = max(info.tlv?.int(0x02) ?? 0, 10)
        let noEncrypt = (info.tlv?.value(0x05)?.first ?? 0) != 0
        received = []
        try await fetchBlocks(size: size, maxBlock: maxBlock, idle: timeout) { offset, blockSize in
            self.session.send(0x2C, 0x04, HuaweiTLV().with(0x01, [fileId]).with(0x02, HealthProbe.be32(offset))
                                .with(0x03, HealthProbe.be32(blockSize)), encrypted: !noEncrypt)
        }
        session.send(0x2C, 0x06, HuaweiTLV().with(0x01, [fileId]).with(0x02, [1]))
        return Array(received.prefix(size))
    }

    private func downloadOld(name: String, from: Int, to: Int) async throws -> [UInt8] {
        oldSync = true
        let initTLV = HuaweiTLV().with(0x02, [0x01])
            .with(0x83, HuaweiTLV().with(0x04, HealthProbe.be32(from)).with(0x05, HealthProbe.be32(to)).serialize())
        let initReply = try await session.request(0x0A, 0x01, initTLV, label: "File list", timeout: 10, quiet: true)
        let names = initReply.tlv?.value(0x01).map { String(decoding: $0, as: UTF8.self) }?.split(separator: ";").map(String.init) ?? []
        log.append("old sync files: \(names.joined(separator: ", "))")
        guard names.contains(name) else { return [] }
        let params = try await session.request(0x0A, 0x02, HuaweiTLV().with(0x06, [0x01]), label: "File parameters",
                                               timeout: 10, quiet: true)
        let maxBlock = max(params.tlv?.int(0x04) ?? 0, 256)
        let timeout = max(params.tlv?.int(0x05) ?? 0, 10)
        let info = try await session.request(0x0A, 0x03, HuaweiTLV().with(0x01, Array(name.utf8)), label: "File info",
                                             timeout: 10, quiet: true)
        let size = info.tlv?.int(0x02) ?? 0
        log.append("old sync: \(size) bytes, blocks of \(maxBlock)")
        received = []
        try await fetchBlocks(size: size, maxBlock: maxBlock, idle: timeout) { offset, blockSize in
            self.session.send(0x0A, 0x04, HuaweiTLV().with(0x01, Array(name.utf8)).with(0x02, HealthProbe.be32(offset))
                                .with(0x03, HealthProbe.be32(blockSize)))
        }
        session.send(0x0A, 0x06, HuaweiTLV().with(0x06, [0x01]))
        return Array(received.prefix(size))
    }

    /// Requests the file block by block. Waits while data keeps coming (the idle timer restarts with every packet);
    /// if the watch goes quiet mid-block, asks again from the current offset (up to 5 times in a row).
    private func fetchBlocks(size: Int, maxBlock: Int, idle: Int,
                             request: (_ offset: Int, _ blockSize: Int) -> Void) async throws {
        var retries = 0
        while received.count < size {
            let offset = received.count
            let blockSize = min(maxBlock, size - offset)
            target = offset + blockSize
            request(offset, blockSize)
            var lastCount = received.count
            while received.count < target {
                await waitForData(seconds: idle)
                if received.count == lastCount { break }   // nothing new during the idle time
                lastCount = received.count
            }
            if received.count >= target {
                retries = 0
            } else {
                retries += 1
                log.append("watch went quiet at \(received.count)/\(size), asking again (\(retries))")
                if retries > 5 { throw SleepFilesError.timeout(received.count, size) }
                // the old protocol numbers packets per block: a partial block is requested again from its start
                if oldSync { received.removeSubrange(offset...) }
            }
        }
    }

    // MARK: - Incoming data

    private func handleBlock(_ packet: HuaweiPacket) {
        let raw = session.decryptRaw(packet.body) ?? packet.body
        if packet.serviceId == 0x2C {
            // file id (1), offset (4, big endian), unknown (1), data
            guard raw.count > 6 else { return }
            let offset = raw[1..<5].reduce(0) { $0 << 8 | Int($1) }
            let data = Array(raw[6...])
            if offset == received.count {
                received += data
            } else if offset < received.count {
                // repeated packet: overwrite in place
                let end = min(received.count, offset + data.count)
                received.replaceSubrange(offset..<end, with: data.prefix(end - offset))
                if offset + data.count > end { received += data.suffix(offset + data.count - end) }
            } else {
                log.append("gap in file data at \(received.count), got \(offset)")
                return
            }
        } else {
            // packet number (1), data
            guard raw.count > 1 else { return }
            received += raw[1...]
        }
        // wake the waiter on every packet: fetchBlocks restarts the idle timer
        if let waiter {
            self.waiter = nil
            waiter.resume()
        }
    }

    private func waitForData(seconds: Int) async {
        if received.count >= target { return }
        let id = UUID()
        waiterID = id
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.waiterID == id, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.resume()
            }
        }
    }
}
