import XCTest
@testable import YiliuCore

final class UsageTests: XCTestCase {
    func testRetentionAndExportAreNumericOnly() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let ledger = UsageLedger(now: base)
        for day in 0..<10 { ledger.record(tokens: TokenUsage(input: 20, output: 10), latency: 2, failed: false, now: base.addingTimeInterval(Double(day) * 86400)) }
        let exported = try ledger.export(now: base.addingTimeInterval(9 * 86400))
        let rows = try JSONDecoder().decode([DailyUsage].self, from: exported)
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.requests }, 7)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [[String: Any]])
        XCTAssertEqual(Set(json[0].keys), Set(["day", "requests", "failures", "inputTokens", "outputTokens", "audioSeconds", "latencySeconds", "estimatedUSD", "unpricedRequests"]))
    }
    func testUnknownAndFailedCostsNeverPretendToBeFree() {
        let ledger = UsageLedger()
        ledger.record(latency: 1, failed: false, estimatedUSD: 0)
        ledger.record(latency: 1, failed: false)
        ledger.record(latency: 1, failed: true, estimatedUSD: 0.1)
        XCTAssertEqual(ledger.days[0].unpricedRequests, 2)
        XCTAssertEqual(ledger.days[0].failures, 1)
        XCTAssertEqual(ledger.days[0].estimatedUSD, 0)
    }
    func testMalformedNumbersDoNotBreakExportAndClear() throws {
        let ledger = UsageLedger()
        ledger.record(audioSeconds: .infinity, latency: .nan, failed: false, estimatedUSD: -.infinity)
        XCTAssertNoThrow(try ledger.export())
        ledger.clear(); XCTAssertTrue(ledger.days.isEmpty)
    }
}
