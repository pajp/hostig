import Foundation
import Testing
@testable import HostigLocalServices

@Suite("Ping service")
struct PingServiceTests {
    @Test("Continuous samples ignore invalid latencies")
    func continuousSamplesIgnoreInvalidLatencies() async {
        let accumulator = PingService.PingAccumulator()
        let receivedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        await accumulator.recordStandardOutput(
            """
            64 bytes from 192.0.2.1: icmp_seq=0 ttl=54 time=25.160 ms
            64 bytes from 192.0.2.1: icmp_seq=1 ttl=54 time=-56.600 ms
            64 bytes from 192.0.2.1: icmp_seq=2 ttl=54 time=1066403.000 ms
            64 bytes from 192.0.2.1: icmp_seq=3 ttl=54 time=29.297 ms

            """,
            receivedAt: receivedAt
        )

        let snapshot = await accumulator.snapshot(lastUpdated: receivedAt)

        #expect(snapshot.latencyMS == 27.2285)
        #expect(snapshot.minLatencyMS == 25.160)
        #expect(snapshot.maxLatencyMS == 29.297)
        #expect(snapshot.packetLossPercent == 50)
    }

    @Test("Continuous samples reset after a long receive gap")
    func continuousSamplesResetAfterLongReceiveGap() async {
        let accumulator = PingService.PingAccumulator()
        let beforeSleep = Date(timeIntervalSinceReferenceDate: 1_000)
        let afterSleep = beforeSleep.addingTimeInterval(31)

        await accumulator.recordStandardOutput(
            """
            64 bytes from 192.0.2.1: icmp_seq=0 ttl=54 time=20.000 ms
            64 bytes from 192.0.2.1: icmp_seq=1 ttl=54 time=40.000 ms

            """,
            receivedAt: beforeSleep
        )

        await accumulator.recordStandardOutput(
            """
            64 bytes from 192.0.2.1: icmp_seq=2 ttl=54 time=30.000 ms

            """,
            receivedAt: afterSleep
        )

        let snapshot = await accumulator.snapshot(lastUpdated: afterSleep)

        #expect(snapshot.latencyMS == 30)
        #expect(snapshot.minLatencyMS == 30)
        #expect(snapshot.maxLatencyMS == 30)
        #expect(snapshot.standardDeviationMS == 0)
        #expect(snapshot.packetLossPercent == 0)
    }

    @Test("One-shot summaries reject invalid latency statistics")
    func oneShotSummariesRejectInvalidLatencyStatistics() {
        let invalidHugeSummary = "round-trip min/avg/max/stddev = 25.160/1131.700/1066403.000/28876.800 ms"
        let validSummary = "round-trip min/avg/max/stddev = 25.160/29.297/39.489/4.200 ms"

        #expect(PingService.parseLatencyStats(from: invalidHugeSummary) == nil)

        let stats = PingService.parseLatencyStats(from: validSummary)
        #expect(stats?.minimum == 25.160)
        #expect(stats?.average == 29.297)
        #expect(stats?.maximum == 39.489)
        #expect(stats?.standardDeviation == 4.200)
    }
}
