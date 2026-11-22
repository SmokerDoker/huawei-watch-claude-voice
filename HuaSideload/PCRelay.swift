import Foundation
import Network
import SwiftUI

// PC relay: lets tools/huawei-cli on a computer talk to the watch through this app's existing, paired connection
// (watch <-Bluetooth-> iPhone <-Wi-Fi-> PC), so the watch never has to be paired with the PC.
// JSON lines over TCP, port 18651, only while the switch in the app is on. The first message must carry the token shown
// in the app. Requests go through HuaweiSession.request (the app encrypts and decrypts); every unsolicited packet from
// the watch is forwarded decrypted.
//   PC -> phone: {"op":"hello","token":…} | {"op":"request","id":1,"service":7,"command":10,"tlv":"hex",
//                 "encrypted":true,"sliced":false,"timeout":10} | {"op":"send",…same without id…}
//   phone -> PC: {"op":"hello","ok":true,"watch":…} | {"op":"response","id":1,"service":…,"command":…,"body":"hex"}
//                | {"op":"response","id":1,"error":…} | {"op":"packet","service":…,"command":…,"body":"hex"}
@MainActor
final class PCRelay: ObservableObject {
    static let shared = PCRelay()
    static let port: UInt16 = 18651

    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var clients = 0
    let token: String = {
        if let saved = UserDefaults.standard.string(forKey: "relay.token") { return saved }
        let token = String((0..<12).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        UserDefaults.standard.set(token, forKey: "relay.token")
        return token
    }()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Client] = [:]
    private weak var session: HuaweiSession?
    private var watchName = ""

    final class Client {
        let connection: NWConnection
        var authorized = false
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    func attach(_ session: HuaweiSession, watchName: String) {
        self.session = session
        self.watchName = watchName
        session.onUnsolicitedForRelay = { [weak self] packet in self?.forward(packet) }
    }

    func setRunning(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.status = L("Listening on \(Self.localAddress() ?? "?"):\(Self.port)", "Dinleniyor: \(Self.localAddress() ?? "?"):\(Self.port)")
                    case .failed(let error): self.status = L("Relay failed: \(error)", "Aktarıcı hatası: \(error)"); self.stop()
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            running = true
            UIApplication.shared.isIdleTimerDisabled = true   // the relay only works while the app is in the foreground
        } catch {
            status = L("Relay failed: \(error)", "Aktarıcı hatası: \(error)")
        }
    }

    private func stop() {
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.connection.cancel() }
        connections.removeAll()
        clients = 0
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = L("Relay off", "Aktarıcı kapalı")
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        connections[ObjectIdentifier(client)] = client
        clients = connections.count
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.drop(client) }
                if case .cancelled = state { self?.drop(client) }
            }
        }
        connection.start(queue: .main)
        receive(client)
    }

    private func drop(_ client: Client) {
        connections.removeValue(forKey: ObjectIdentifier(client))
        clients = connections.count
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { client.buffer.append(data) }
                while let newline = client.buffer.firstIndex(of: 0x0A) {
                    let line = client.buffer[client.buffer.startIndex..<newline]
                    client.buffer.removeSubrange(client.buffer.startIndex...newline)
                    if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self.handle(json, from: client)
                    }
                }
                if done || error != nil { client.connection.cancel(); self.drop(client); return }
                self.receive(client)
            }
        }
    }

    private func write(_ message: [String: Any], to client: Client) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        client.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handle(_ message: [String: Any], from client: Client) {
        let op = message["op"] as? String ?? ""
        guard client.authorized || op == "hello" else { client.connection.cancel(); return }
        switch op {
        case "hello":
            guard (message["token"] as? String) == token else {
                write(["op": "hello", "ok": false, "error": "wrong token"], to: client)
                client.connection.cancel()
                return
            }
            client.authorized = true
            write(["op": "hello", "ok": true, "watch": watchName, "paired": session?.isPaired ?? false], to: client)
            status = L("PC connected", "PC bağlandı")
        case "request", "send":
            guard let session, session.isPaired else {
                write(["op": "response", "id": message["id"] ?? 0, "error": "watch not connected"], to: client)
                return
            }
            guard let service = message["service"] as? Int, let command = message["command"] as? Int,
                  let tlvHex = message["tlv"] as? String, let bytes = Self.bytes(hex: tlvHex),
                  let tlv = try? HuaweiTLV.parse(bytes) else {
                write(["op": "response", "id": message["id"] ?? 0, "error": "bad request"], to: client)
                return
            }
            let encrypted = message["encrypted"] as? Bool ?? true
            if op == "send" {
                session.send(UInt8(service), UInt8(command), tlv, encrypted: encrypted)
                return
            }
            let id = message["id"] ?? 0
            Task {
                do {
                    let packet = try await session.request(UInt8(service), UInt8(command), tlv, label: String(format: "PC %02X/%02X", service, command),
                                                           encrypted: encrypted, sliced: message["sliced"] as? Bool ?? false,
                                                           timeout: message["timeout"] as? Double ?? 10, quiet: true)
                    write(["op": "response", "id": id, "service": Int(packet.serviceId), "command": Int(packet.commandId),
                           "body": Self.hex(packet.body)], to: client)
                } catch {
                    write(["op": "response", "id": id, "error": "\(error)"], to: client)
                }
            }
        default:
            break
        }
    }

    private func forward(_ packet: HuaweiPacket) {
        guard !connections.isEmpty else { return }
        let body = session?.decryptRaw(packet.body) ?? packet.body   // file blocks (0x2C/0x05) are encrypted raw data
        for client in connections.values where client.authorized {
            write(["op": "packet", "service": Int(packet.serviceId), "command": Int(packet.commandId), "body": Self.hex(body)], to: client)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(hex: String) -> [UInt8]? {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Wi-Fi IPv4 address of the phone (en0).
    static func localAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = item.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: interface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}

struct PCRelaySection: View {
    @ObservedObject private var relay = PCRelay.shared

    var body: some View {
        Section {
            Toggle(L("PC relay", "PC aktarıcı"), isOn: Binding(get: { relay.running }, set: { relay.setRunning($0) }))
            if relay.running {
                LabeledContent(L("Address", "Adres"), value: "\(PCRelay.localAddress() ?? "?"):\(PCRelay.port)")
                LabeledContent("Token", value: relay.token).textSelection(.enabled)
                LabeledContent(L("Connected PCs", "Bağlı PC"), value: "\(relay.clients)")
            }
            if let status = relay.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text(L("PC relay (developer)", "PC aktarıcı (geliştirici)"))
        } footer: {
            Text(L("Lets tools/huawei-cli on your computer use this watch connection over Wi-Fi: py cli.py info relay:ADDRESS --token TOKEN. Keep the app open while it runs.",
                   "Bilgisayardaki tools/huawei-cli bu saat bağlantısını Wi-Fi üzerinden kullanır. Çalışırken uygulamayı açık tut."))
        }
    }
}

/// Huawei account ID for pairing without Huawei Health (see HuaweiSession.finishSetup).
struct HuaweiAccountSection: View {
    @AppStorage("huawei.accountId") private var accountId = ""

    var body: some View {
        Section {
            TextField(L("Huawei account ID (17 digits)", "Huawei hesap kimliği (17 hane)"), text: $accountId)
                .keyboardType(.numberPad)
        } header: {
            Text(L("Huawei account (experimental)", "Huawei hesabı (deneysel)"))
        } footer: {
            Text(L("Lets the watch finish pairing without Huawei Health. The ID is the cookie \"userId\" on cloud.huawei.com when signed in with the account used in Huawei Health. Leave empty if unsure: a wrong ID makes the watch offer a factory reset (just dismiss it).",
                   "Saatin Huawei Health olmadan eşleşmeyi bitirmesini sağlar. Emin değilsen boş bırak."))
        }
    }
}
