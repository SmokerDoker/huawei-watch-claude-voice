import Charts
import SwiftUI

/// Trends over the last 30 days: sleep duration and bed time per night, night HRV, resting heart rate, stress.
struct TrendsView: View {
    @ObservedObject private var store = HealthStore.shared

    /// A night = TruSleep sessions with less than 4 h between them (interrupted nights), dated by the wake-up day.
    struct Night: Identifiable {
        var start: Int, end: Int, minutes: Int
        var hrv: Int?
        var id: Int { start }
        var day: Date { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(end))) }
        /// Bed time as hours after noon (so 23:00 = 11, 02:00 = 14): keeps late nights on one continuous axis.
        var bedHour: Double {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(start)))
            return Double(((c.hour ?? 0) + 12) % 24) + Double(c.minute ?? 0) / 60
        }
    }

    private var nights: [Night] {
        let cutoff = Int(Date().timeIntervalSince1970) - 30 * 86400
        var result: [Night] = []
        for s in store.data.truSleep.filter({ $0.end >= cutoff }).sorted(by: { $0.start < $1.start }) {
            if var last = result.last, s.start - last.end < 4 * 3600 {
                last.end = s.end; last.minutes += s.minutes
                last.hrv = last.hrv ?? store.data.nightHRV[s.start]?.rmssd
                result[result.count - 1] = last
            } else if s.minutes >= 60 {   // naps are not nights
                result.append(Night(start: s.start, end: s.end, minutes: s.minutes, hrv: store.data.nightHRV[s.start]?.rmssd))
            }
        }
        return result
    }

    private var days: [Date] {
        (0..<30).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Calendar.current.startOfDay(for: Date())) }.reversed()
    }

    var body: some View {
        let nights = self.nights
        List {
            Section(L("Sleep per night (h)", "Gece başına uyku (sa)")) {
                Chart(nights) { n in
                    BarMark(x: .value("Day", n.day, unit: .day), y: .value("h", Double(n.minutes) / 60))
                        .foregroundStyle(.indigo)
                }
                .frame(height: 170)
                if !nights.isEmpty {
                    let avg = Double(nights.map(\.minutes).reduce(0, +)) / Double(nights.count) / 60
                    Text(L("Average", "Ortalama") + String(format: " %.1f h", avg)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Bed time", "Yatış saati")) {
                Chart(nights) { n in
                    PointMark(x: .value("Day", n.day, unit: .day), y: .value("Bed", n.bedHour))
                        .foregroundStyle(.purple)
                }
                .chartYAxis {
                    AxisMarks(values: .stride(by: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%02d:00", (Int(v) + 12) % 24)) } }
                    }
                }
                .frame(height: 170)
                if nights.count > 2 {
                    let hours = nights.map(\.bedHour)
                    let mean = hours.reduce(0, +) / Double(hours.count)
                    let sd = (hours.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(hours.count)).squareRoot()
                    Text(L("Spread ± ", "Sapma ± ") + String(format: "%.1f h", sd) + L(" (regular rhythm: under 1 h)", " (düzenli: 1 sa altı)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("Night HRV (RMSSD, ms)", "Gece HRV (RMSSD, ms)")) {
                Chart(nights.filter { $0.hrv != nil }) { n in
                    LineMark(x: .value("Day", n.day, unit: .day), y: .value("ms", n.hrv ?? 0)).foregroundStyle(.green)
                    PointMark(x: .value("Day", n.day, unit: .day), y: .value("ms", n.hrv ?? 0)).foregroundStyle(.green)
                }
                .frame(height: 150)
            }
            Section(L("Resting heart rate (bpm)", "Dinlenme nabzı (bpm)")) {
                let rest = days.compactMap { d in store.restingHeartRate(for: d).map { (d, $0) } }
                Chart(rest, id: \.0) { p in
                    LineMark(x: .value("Day", p.0, unit: .day), y: .value("bpm", p.1)).foregroundStyle(.red)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 150)
            }
            Section(L("Stress (daily average)", "Stres (günlük ortalama)")) {
                let stress = days.compactMap { d -> (Date, Int)? in
                    let start = Int(d.timeIntervalSince1970)
                    let values = store.data.stress.filter { $0.time >= start && $0.time < start + 86400 }.map(\.score)
                    return values.isEmpty ? nil : (d, values.reduce(0, +) / values.count)
                }
                Chart(stress, id: \.0) { p in
                    BarMark(x: .value("Day", p.0, unit: .day), y: .value("Stress", p.1)).foregroundStyle(.orange)
                }
                .frame(height: 150)
            }
            if let auto = UserDefaults.standard.string(forKey: "autoSync.last") {
                Text(L("Last automatic sync: ", "Son otomatik eşitleme: ") + auto).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("Trends (30 days)", "Eğilimler (30 gün)"))
    }
}
