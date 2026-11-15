import MapKit
import SwiftUI

/// Weather, find watch, remote shutter and workouts.
struct ExtrasSection: View {
    @ObservedObject var link: WatchLink
    @ObservedObject private var weather = WatchWeather.shared
    @ObservedObject private var workouts = WorkoutStore.shared
    @ObservedObject private var camera = CameraRemote.shared
    @State private var findingWatch = false

    var body: some View {
        Section(L("Weather on the watch", "Saatte hava durumu")) {
            LabeledContent(L("Place", "Yer"), value: weather.placeName ?? "–")
            HStack {
                TextField(L("City", "Şehir"), text: $weather.city).textInputAutocapitalization(.words)
                Button(L("Set", "Ayarla")) { Task { await weather.lookUpCity() } }
            }
            Button(L("Use my location", "Konumumu kullan"), systemImage: "location") { Task { await weather.useCurrentLocation() } }
            Button(weather.sending ? L("Sending…", "Gönderiliyor…") : L("Send weather now", "Havayı şimdi gönder")) {
                Task { await link.sendWeather() }
            }
            .disabled(weather.sending || weather.placeName == nil)
            if let status = weather.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }

        Section(L("Watch tools", "Saat araçları")) {
            Button(findingWatch ? L("Stop ringing", "Çalmayı durdur") : L("Find watch", "Saati bul"),
                   systemImage: findingWatch ? "bell.slash" : "bell.and.waves.left.and.right") {
                findingWatch.toggle()
                link.findWatch(findingWatch)
                if findingWatch {
                    Task {
                        try? await Task.sleep(for: .seconds(30))
                        if findingWatch { findingWatch = false; link.findWatch(false) }
                    }
                }
            }
            Button(L("Remote shutter (camera)", "Uzaktan deklanşör (kamera)"), systemImage: "camera") { camera.showing = true }
        }
        .fullScreenCover(isPresented: $camera.showing) { CameraRemoteView() }

        Section {
            Button(workouts.syncing ? L("Reading…", "Okunuyor…") : L("Sync workouts", "Antrenmanları eşitle")) {
                Task { await link.syncWorkouts() }
            }
            .disabled(workouts.syncing)
            if let status = workouts.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            ForEach(workouts.workouts.prefix(30)) { workout in
                NavigationLink { WorkoutDetail(workout: workout) } label: { WorkoutRow(workout: workout) }
            }
            Button(L("Fetch all workouts again", "Tüm antrenmanları yeniden al")) { Task { await link.syncWorkouts(all: true) } }
                .disabled(workouts.syncing).font(.caption)
        } header: {
            Text(L("Workouts", "Antrenmanlar"))
        } footer: {
            Text(L("Summary and GPS route. Also synced with \"Sync health data\".",
                   "Özet ve GPS rotası. \"Sağlık verisini eşitle\" ile de eşitlenir."))
        }
    }
}

private struct WorkoutRow: View {
    let workout: Workout
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(workout.name).font(.headline)
                if !workout.route.isEmpty { Image(systemName: "map").foregroundStyle(.secondary) }
            }
            Text(Date(timeIntervalSince1970: TimeInterval(workout.start)).formatted(date: .abbreviated, time: .shortened)
                 + " · " + WorkoutDetail.duration(workout.activeSeconds)
                 + (workout.distance.map { $0 > 0 ? String(format: " · %.2f km", Double($0) / 1000) : "" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WorkoutDetail: View {
    let workout: Workout

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                        : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        List {
            if !workout.route.isEmpty {
                Map {
                    MapPolyline(coordinates: workout.route.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(.orange, lineWidth: 4)
                }
                .frame(height: 280)
                .listRowInsets(EdgeInsets())
            }
            LabeledContent(L("Start", "Başlangıç"),
                           value: Date(timeIntervalSince1970: TimeInterval(workout.start)).formatted(date: .abbreviated, time: .shortened))
            LabeledContent(L("Duration", "Süre"), value: Self.duration(workout.activeSeconds))
            if let d = workout.distance, d > 0 {
                LabeledContent(L("Distance", "Mesafe"), value: String(format: "%.2f km", Double(d) / 1000))
                let pace = Double(workout.activeSeconds) / (Double(d) / 1000)
                LabeledContent(L("Pace", "Tempo"), value: String(format: "%d:%02d /km", Int(pace) / 60, Int(pace) % 60))
            }
            if let c = workout.calories, c > 0 { LabeledContent(L("Calories", "Kalori"), value: "\(c / 1000) kcal") }
            if let s = workout.steps, s > 0 { LabeledContent(L("Steps", "Adım"), value: "\(s)") }
            if let lo = workout.minHeartRate, let hi = workout.maxHeartRate, hi > 0 {
                LabeledContent(L("Heart rate", "Nabız"), value: "\(lo)–\(hi) bpm")
            }
            if let url = WorkoutStore.shared.gpx(workout) {
                ShareLink(item: url) { Label(L("Share as GPX", "GPX olarak paylaş"), systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle(workout.name)
    }
}
