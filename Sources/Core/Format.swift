import Foundation

enum Format {
    /// 950, 32.5K, 1.4M: unit picked from the rounded value, so 999,950 shows as 1M.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let number = value / divisor
            let text = number >= 100 ? String(format: "%.0f", number) : String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if value >= 999_950_000 { return scaled(1_000_000_000, "B") }
        if value >= 999_950 { return scaled(1_000_000, "M") }
        if value >= 1000 { return scaled(1000, "K") }
        return "\(count)"
    }

    /// "45秒", "12分", "2时05分", "3天4时".
    static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)分" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%d时%02d分", hours, minutes % 60) }
        return "\(hours / 24)天\(hours % 24)时"
    }

    /// "刚刚", "5分前", "2时10分前".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 45 ? "刚刚" : span(seconds) + "前"
    }

    /// "28分后重置".
    static func resets(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        return seconds <= 0 ? "已重置" : span(seconds) + "后重置"
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// One line, at most `limit` characters.
    static func oneLine(_ text: String?, limit: Int = 120) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
