import Foundation

enum PingService {
    static func sample(host: String) async throws -> PingSnapshot {
        let output = try await ProcessRunner.run(
            executable: "/sbin/ping",
            arguments: ["-n", "-q", "-c", "4", host],
            timeout: 8
        )

        let combined = output.stdout + "\n" + output.stderr
        let packetLoss = parsePacketLoss(from: combined)
        let latency = parseLatency(from: combined)

        return PingSnapshot(
            latencyMS: latency,
            packetLossPercent: packetLoss,
            lastUpdated: .now
        )
    }

    private static func parsePacketLoss(from text: String) -> Double? {
        guard let range = text.range(of: #"([0-9.]+)% packet loss"#, options: .regularExpression) else {
            return nil
        }
        return Double(String(text[range]).replacingOccurrences(of: "% packet loss", with: ""))
    }

    private static func parseLatency(from text: String) -> Double? {
        let patterns = [
            #"round-trip min/avg/max/(?:stddev|mdev) = [0-9.]+/([0-9.]+)/"#,
            #"rtt min/avg/max/(?:mdev|stddev) = [0-9.]+/([0-9.]+)/"#
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                if let value = match.split(separator: "=").last?
                    .split(separator: "/")
                    .dropFirst()
                    .first {
                    return Double(value.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        return nil
    }
}
