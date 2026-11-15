import AVFoundation
import AudioToolbox
import UserNotifications

// "Find phone" from the watch, without the Huawei app: loud alarm tone (ignores the silent switch,
// but not the volume buttons), vibration and a notification. Stops when the watch says so, when the
// notification is tapped / the app is opened, or after a minute.
@MainActor
final class PhoneRinger: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneRinger()

    private var player: AVAudioPlayer?
    private var vibration: Timer?
    private var timeout: Task<Void, Never>?
    private var onStoppedHere: (() -> Void)?
    private(set) var ringing = false

    func prepareNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start(onStoppedHere: @escaping () -> Void) {
        stop(notifyWatch: false)
        self.onStoppedHere = onStoppedHere
        ringing = true
        playTone()
        vibration = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        let content = UNMutableNotificationContent()
        content.title = L("Your watch is looking for this iPhone", "Saatin bu iPhone'u arıyor")
        content.body = L("Tap to stop the sound.", "Sesi durdurmak için dokun.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "find-phone", content: content, trigger: nil))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.stop(notifyWatch: true)
        }
    }

    /// notifyWatch: stopped on the phone (not by the watch), so the watch is told to close its screen.
    func stop(notifyWatch: Bool) {
        guard ringing else { return }
        ringing = false
        timeout?.cancel(); timeout = nil
        vibration?.invalidate(); vibration = nil
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["find-phone"])
        if notifyWatch { onStoppedHere?() }
        onStoppedHere = nil
    }

    private func playTone() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
        } catch {
            // in the background a non-mixable session may be refused: mixing still plays the tone
            try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? audio.setActive(true)
        }
        guard let player = try? AVAudioPlayer(data: Self.alarmWAV()) else { return }
        player.numberOfLoops = -1
        player.volume = 1
        player.play()
        self.player = player
    }

    /// Two-tone beeping alarm, 1.2 s, 16-bit mono WAV built in memory.
    private static func alarmWAV() -> Data {
        let rate = 22050
        var samples = [Int16]()
        for i in 0..<(rate * 12 / 10) {
            let t = Double(i) / Double(rate)
            let slot = Int(t / 0.15)
            let on = slot % 2 == 0 && t < 0.9
            let freq = slot % 4 == 0 ? 2000.0 : 2600.0
            let v = on ? sin(2 * .pi * freq * t) * 0.9 : 0
            samples.append(Int16(v * Double(Int16.max)))
        }
        var data = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    // Tapping the notification (or seeing it while the app is open) stops the alarm
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in PhoneRinger.shared.stop(notifyWatch: true) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
