import CoreLocation
import Foundation

// Weather for the watch's weather screen, without Huawei Health: fetched from Open-Meteo (free, no key) and sent with
// the Huawei weather service 0x0F. Protocol from Gadgetbridge (packets/Weather.java, HuaweiWeatherManager.java,
// GpsAndTime.CurrentGPSRequest). Sent after connecting, every hour while connected, and when the watch asks.
@MainActor
final class WatchWeather: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WatchWeather()

    @Published private(set) var status: String?
    @Published private(set) var sending = false
    @Published var city = UserDefaults.standard.string(forKey: "weather.city") ?? "" {
        didSet { UserDefaults.standard.set(city, forKey: "weather.city") }
    }
    private(set) var place: (lat: Double, lon: Double, name: String)? = {
        let d = UserDefaults.standard
        guard d.object(forKey: "weather.lat") != nil, let name = d.string(forKey: "weather.name") else { return nil }
        return (d.double(forKey: "weather.lat"), d.double(forKey: "weather.lon"), name)
    }()
    var placeName: String? { place?.name }

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?
    private var lastSent: Date?

    private func savePlace(_ lat: Double, _ lon: Double, _ name: String) {
        place = (lat, lon, name)
        let d = UserDefaults.standard
        d.set(lat, forKey: "weather.lat"); d.set(lon, forKey: "weather.lon"); d.set(name, forKey: "weather.name")
        objectWillChange.send()
    }

    // MARK: - Place

    /// Current position (asks for "while using" location access once).
    func useCurrentLocation() async {
        locationManager.delegate = self
        if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        let location: CLLocation? = await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
        guard let location else { status = L("No location (allow location access in Settings).", "Konum yok."); return }
        let name = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first?.locality ?? L("Here", "Burada")
        savePlace(location.coordinate.latitude, location.coordinate.longitude, name)
        status = L("Place: \(name)", "Yer: \(name)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.locationContinuation?.resume(returning: location); self.locationContinuation = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locationContinuation?.resume(returning: nil); self.locationContinuation = nil }
    }

    /// Place by name (Open-Meteo geocoding).
    func lookUpCity() async {
        let name = city.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else { return }
        url.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "1"), .init(name: "language", value: "de")]
        struct Result: Decodable { struct Hit: Decodable { let name: String; let latitude: Double; let longitude: Double }; let results: [Hit]? }
        do {
            let (data, _) = try await URLSession.shared.data(from: url.url!)
            guard let hit = try JSONDecoder().decode(Result.self, from: data).results?.first else {
                status = L("City not found.", "Şehir bulunamadı."); return
            }
            savePlace(hit.latitude, hit.longitude, hit.name)
            status = L("Place: \(hit.name)", "Yer: \(hit.name)")
        } catch {
            status = L("City lookup failed: \(error.localizedDescription)", "Şehir aranamadı.")
        }
    }

    // MARK: - Forecast

    struct Forecast {
        var time: Int
        var temperature: Double, code: Int, windSpeed: Double, windDirection: Double
        var hourly: [(time: Int, temperature: Double, code: Int)]
        var daily: [(time: Int, code: Int, high: Double, low: Double, sunrise: Int, sunset: Int, uv: Double)]
    }

    private func fetch(lat: Double, lon: Double) async throws -> Forecast {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(lat)), .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m"),
            .init(name: "hourly", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,uv_index_max"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "8"),
            .init(name: "timeformat", value: "unixtime"),
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let time: Int; let temperature_2m: Double; let weather_code: Int
                let wind_speed_10m: Double; let wind_direction_10m: Double
            }
            struct Hourly: Decodable { let time: [Int]; let temperature_2m: [Double?]; let weather_code: [Int?] }
            struct Daily: Decodable {
                let time: [Int]; let weather_code: [Int?]; let temperature_2m_max: [Double?]; let temperature_2m_min: [Double?]
                let sunrise: [Int?]; let sunset: [Int?]; let uv_index_max: [Double?]
            }
            let current: Current; let hourly: Hourly; let daily: Daily
        }
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        let r = try JSONDecoder().decode(Response.self, from: data)
        let now = Int(Date().timeIntervalSince1970)
        var hourly: [(Int, Double, Int)] = []
        for (i, t) in r.hourly.time.enumerated() where t >= now - 3600 && hourly.count < 24 {
            if let temp = r.hourly.temperature_2m[i], let code = r.hourly.weather_code[i] { hourly.append((t, temp, code)) }
        }
        var daily: [(Int, Int, Double, Double, Int, Int, Double)] = []
        for (i, t) in r.daily.time.enumerated() {
            daily.append((t, r.daily.weather_code[i] ?? 0, r.daily.temperature_2m_max[i] ?? 0, r.daily.temperature_2m_min[i] ?? 0,
                          r.daily.sunrise[i] ?? 0, r.daily.sunset[i] ?? 0, r.daily.uv_index_max[i] ?? 0))
        }
        return Forecast(time: r.current.time, temperature: r.current.temperature_2m, code: r.current.weather_code,
                        windSpeed: r.current.wind_speed_10m, windDirection: r.current.wind_direction_10m,
                        hourly: hourly.map { (time: $0.0, temperature: $0.1, code: $0.2) },
                        daily: daily.map { (time: $0.0, code: $0.1, high: $0.2, low: $0.3, sunrise: $0.4, sunset: $0.5, uv: $0.6) })
    }

    /// WMO weather code (Open-Meteo) -> Huawei weather icon byte (Weather.iconToByte).
    static func icon(_ wmo: Int) -> UInt8 {
        switch wmo {
        case 0: 0x00                         // sunny
        case 1, 2: 0x01                      // cloudy
        case 3: 0x02                         // overcast
        case 45, 48: 0x12                    // fog
        case 51, 53, 55: 0x07                // drizzle -> light rain
        case 56, 57, 66, 67: 0x13            // freezing rain
        case 61: 0x07
        case 63: 0x08
        case 65: 0x09
        case 71, 77: 0x0E                    // light snow
        case 73: 0x0F
        case 75: 0x10
        case 80, 81, 82: 0x03                // showers
        case 85, 86: 0x0D                    // snow flurries
        case 95: 0x04                        // thunderstorm
        case 96, 99: 0x05                    // thunder and hail
        default: 0x63
        }
    }

    // MARK: - Sending

    /// Sends the weather unless it was sent in the last 50 minutes (force: always).
    func send(_ session: HuaweiSession, force: Bool = false) async {
        guard let place, !sending else {
            if place == nil { status = L("Set a place for the weather first.", "Önce hava durumu için bir yer seç.") }
            return
        }
        if !force, let lastSent, Date().timeIntervalSince(lastSent) < 50 * 60 { return }
        sending = true
        defer { sending = false }
        do {
            let forecast = try await fetch(lat: place.lat, lon: place.lon)
            try await push(forecast, place: place, session: session)
            lastSent = Date()
            status = L("Weather sent: \(place.name), \(Int(forecast.temperature.rounded())) °C",
                       "Hava gönderildi: \(place.name), \(Int(forecast.temperature.rounded())) °C")
        } catch {
            status = L("Weather failed: \(error.localizedDescription)", "Hava gönderilemedi: \(error.localizedDescription)")
        }
    }

    private func push(_ f: Forecast, place: (lat: Double, lon: Double, name: String), session: HuaweiSession) async throws {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func temp(_ v: Double) -> [UInt8] { [UInt8(bitPattern: Int8(clamping: Int(v.rounded())))] }
        func leDouble(_ v: Double) -> [UInt8] { withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
        // optional steps: an unsupported one just times out or answers with an error
        func ask(_ command: UInt8, _ tlv: HuaweiTLV, _ label: String, sliced: Bool = false) async -> HuaweiTLV? {
            try? await session.request(0x0F, command, tlv, label: "Weather: " + label, sliced: sliced, timeout: 4).tlv
        }

        let start = await ask(0x09, HuaweiTLV().with(0x01, [0x03]), "start")
        if let code = start?.int(0x7F), code != 0x186A0, code != 0x186A3 {
            throw HuaweiAuthError.watchError(String(format: "weather start 0x%X", code))
        }
        _ = await ask(0x05, HuaweiTLV().with(0x01, [0x00]), "unit °C")
        let support = await ask(0x02, HuaweiTLV().with(0x01), "support")?.int(0x01) ?? 0xFF
        let extended = await ask(0x06, HuaweiTLV().with(0x01), "extended")?.int(0x01) ?? 0
        let sunMoon = await ask(0x0A, HuaweiTLV().with(0x01), "sun/moon")?.int(0x01) ?? 0
        let wind = support & 0x02 != 0, temperature = support & 0x08 != 0, location = support & 0x10 != 0
        let current = support & 0x20 != 0, unit = support & 0x40 != 0
        let time = extended & 0x01 != 0, source = extended & 0x02 != 0, icons = extended & 0x04 != 0
        let sun = sunMoon & 0x01 != 0

        // current weather (0x01)
        let beaufort = [1, 6, 12, 20, 29, 39, 50, 62, 75, 89, 103, 118].firstIndex { f.windSpeed < Double($0) } ?? 12
        let direction = Int(f.windDirection)
        var tlv = HuaweiTLV()
        if icons || wind {
            var inner = HuaweiTLV()
            if icons { inner = inner.with(0x02, [Self.icon(f.code)]) }
            if wind { inner = inner.with(0x03, be16(beaufort | (direction * 8 / 360) << 8)) }
            tlv = tlv.with(0x81, inner.serialize())
        }
        if temperature, let today = f.daily.first {
            tlv = tlv.with(0x85, HuaweiTLV().with(0x06, temp(today.low)).with(0x07, temp(today.high)).serialize())
        }
        if wind { tlv = tlv.with(0x03, be16((direction * 255 / 360) << 8 | beaufort)) }
        if location { tlv = tlv.with(0x08, Array(place.name.prefix(30).utf8)) }
        if current { tlv = tlv.with(0x09, temp(f.temperature)) }
        if unit { tlv = tlv.with(0x0A, [0x00]) }
        if time { tlv = tlv.with(0x0C, be32(f.time)) }
        if source { tlv = tlv.with(0x0E, Array("Open-Meteo".utf8)) }
        _ = await ask(0x01, tlv, "current")

        // position and time (GpsAndTime 0x18/0x07), backdated a bit like Gadgetbridge
        _ = try? await session.request(0x18, 0x07, HuaweiTLV().with(0x01, be32(Int(Date().timeIntervalSince1970) - 60))
                                        .with(0x02, leDouble(place.lon)).with(0x03, leDouble(place.lat)),
                                       label: "Weather: position", timeout: 4)

        // forecast (0x08): 24 hours + 8 days
        var hours = HuaweiTLV()
        for h in f.hourly {
            var item = HuaweiTLV().with(0x03, be32(h.time))
            if icons { item = item.with(0x04, [Self.icon(h.code)]) }
            if temperature || current { item = item.with(0x05, temp(h.temperature)) }
            hours = hours.with(0x82, item.serialize())
        }
        var days = HuaweiTLV()
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        for (i, d) in f.daily.prefix(8).enumerated() {
            let dayStart = Int(todayStart) + i * 86400
            var item = HuaweiTLV().with(0x12, be32(i == 0 ? f.time : d.time))
            if icons { item = item.with(0x13, [Self.icon(d.code)]) }
            if temperature { item = item.with(0x14, temp(d.high)).with(0x15, temp(d.low)) }
            // sunrise/sunset outside their own day stop the watch from showing any weather (Gadgetbridge fixupWeather)
            if sun {
                if d.sunrise >= dayStart && d.sunrise < dayStart + 86400 { item = item.with(0x16, be32(d.sunrise)) }
                if d.sunset >= dayStart && d.sunset < dayStart + 86400 { item = item.with(0x17, be32(d.sunset)) }
            }
            days = days.with(0x91, item.serialize())
        }
        _ = await ask(0x08, HuaweiTLV().with(0x81, hours.serialize()).with(0x90, days.serialize()), "forecast", sliced: true)
    }

    /// The watch's weather screen asks (0x0F/0x04 with 7F=0x186AA): send; other 0x0F/0x04 messages just get an OK.
    func handleWatchRequest(_ packet: HuaweiPacket, session: HuaweiSession) {
        if packet.tlv?.int(0x7F) == 0x186AA {
            Task { await send(session, force: true) }
        } else {
            session.send(0x0F, 0x04, HuaweiTLV().with(0x01, [0x00, 0x01, 0x86, 0xA0]), encrypted: false)
        }
    }
}
