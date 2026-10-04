import Foundation

public struct TokenUsage: Codable, Sendable {
    public let input: Int
    public let output: Int
    public init(input: Int, output: Int) { self.input = max(0, input); self.output = max(0, output) }
}
public struct DailyUsage: Codable {
    public var day: String
    public var requests = 0
    public var failures = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var audioSeconds: Double = 0
    public var latencySeconds: Double = 0
    public var estimatedUSD: Double = 0
    public var unpricedRequests = 0
}
/// Stores only daily numeric counters. No draft, audio, app identity or endpoint is accepted.
public final class UsageLedger {
    private let file: URL?
    public private(set) var days: [DailyUsage]
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = TimeZone(secondsFromGMT: 0); return f
    }()
    public init(file: URL? = nil, now: Date = Date()) {
        self.file = file
        days = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([DailyUsage].self, from: $0) } ?? []
        prune(now: now)
    }
    private func prune(now: Date) {
        let cutoff = Self.formatter.string(from: now.addingTimeInterval(-6 * 86400))
        days.removeAll { $0.day < cutoff }
        save()
    }
    public func record(tokens: TokenUsage? = nil, audioSeconds: Double = 0, latency: Double,
                       failed: Bool, estimatedUSD: Double? = nil, now: Date = Date()) {
        prune(now: now)
        let day = Self.formatter.string(from: now)
        if !days.contains(where: { $0.day == day }) { days.append(DailyUsage(day: day)) }
        let i = days.firstIndex { $0.day == day }!
        days[i].requests += 1; if failed { days[i].failures += 1 }
        days[i].inputTokens += tokens?.input ?? 0; days[i].outputTokens += tokens?.output ?? 0
        days[i].audioSeconds += audioSeconds.isFinite ? max(0, audioSeconds) : 0
        days[i].latencySeconds += latency.isFinite ? max(0, latency) : 0
        if let estimatedUSD, estimatedUSD.isFinite, estimatedUSD >= 0, !failed { days[i].estimatedUSD += estimatedUSD }
        else { days[i].unpricedRequests += 1 }
        save()
    }
    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: file, options: .atomic) }
    }
    public func clear() { days = []; save() }
    public func export(now: Date = Date()) throws -> Data {
        prune(now: now)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(days)
    }
    public func summary(now: Date = Date()) -> String {
        prune(now: now)
        let requests = days.reduce(0) { $0 + $1.requests }, failed = days.reduce(0) { $0 + $1.failures }
        let input = days.reduce(0) { $0 + $1.inputTokens }, output = days.reduce(0) { $0 + $1.outputTokens }
        let audio = days.reduce(0.0) { $0 + $1.audioSeconds }, latency = days.reduce(0.0) { $0 + $1.latencySeconds }
        let cost = days.reduce(0.0) { $0 + $1.estimatedUSD }, unknown = days.reduce(0) { $0 + $1.unpricedRequests }
        return "最近 7 天（UTC）\n请求：\(requests)，失败：\(failed)\n文本计量：输入 \(input) / 输出 \(output) tokens\n音频：\(String(format: "%.1f", audio)) 秒\n累计请求耗时：\(String(format: "%.2f", latency)) 秒\n已知单价部分估算：USD \(String(format: "%.5f", cost))\n另有 \(unknown) 次请求费用未知，失败也可能收费。费用以供应商账单为准。"
    }
}
