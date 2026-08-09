import Foundation
import HostigModels
#if os(macOS)
import Darwin
#endif

public enum PingService {
    public static func sample(host: String) async throws -> PingSnapshot {
        try await sample(host: host, count: 4)
    }

    public static func continuousSamples(host: String, interval: Duration) -> AsyncStream<PingSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                #if os(macOS)
                await runContinuousPing(host: host, interval: interval, continuation: continuation)
                #else
                while !Task.isCancelled {
                    let snapshot = (try? await sample(host: host)) ?? PingSnapshot(
                        latencyMS: nil,
                        packetLossPercent: nil,
                        lastUpdated: .now
                    )
                    continuation.yield(snapshot)
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
                #endif
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func sample(host: String, count: Int) async throws -> PingSnapshot {
        let output = try await ProcessRunner.run(
            executable: "/sbin/ping",
            arguments: ["-n", "-q", "-c", String(max(1, count)), host],
            timeout: 8
        )

        let combined = output.stdout + "\n" + output.stderr
        let packetLoss = parsePacketLoss(from: combined)
        let latencyStats = parseLatencyStats(from: combined)

        return PingSnapshot(
            latencyMS: latencyStats?.average,
            minLatencyMS: latencyStats?.minimum,
            maxLatencyMS: latencyStats?.maximum,
            standardDeviationMS: latencyStats?.standardDeviation,
            packetLossPercent: packetLoss,
            lastUpdated: .now
        )
    }

    #if os(macOS)
    private static func runContinuousPing(
        host: String,
        interval: Duration,
        continuation: AsyncStream<PingSnapshot>.Continuation
    ) async {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let accumulator = PingAccumulator()

        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-n", host]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task {
                await accumulator.recordStandardOutput(text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task {
                await accumulator.recordStandardError(text)
            }
        }

        do {
            try process.run()
        } catch {
            continuation.yield(PingSnapshot(latencyMS: nil, packetLossPercent: nil, lastUpdated: .now))
            continuation.finish()
            return
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            continuation.finish()
        }

        while !Task.isCancelled, process.isRunning {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, process.isRunning else { break }

            kill(process.processIdentifier, SIGINFO)
            try? await Task.sleep(for: .milliseconds(100))

            continuation.yield(await accumulator.snapshot(lastUpdated: .now))
        }
    }
    #endif

    private static func parsePacketLoss(from text: String) -> Double? {
        guard let range = text.range(of: #"([0-9.]+)% packet loss"#, options: .regularExpression) else {
            return nil
        }
        return Double(String(text[range]).replacingOccurrences(of: "% packet loss", with: ""))
    }

    private static func parseLatencyStats(from text: String) -> LatencyStats? {
        let patterns = [
            #"round-trip min/avg/max/(?:stddev|mdev) = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+|nan)"#,
            #"rtt min/avg/max/(?:mdev|stddev) = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+|nan)"#
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                let components = match.split(separator: "=").last?
                    .split(separator: "/")

                if
                    let components,
                    components.count == 4,
                    let minimum = parseDoublePrefix(components[0]),
                    let average = parseDoublePrefix(components[1]),
                    let maximum = parseDoublePrefix(components[2])
                {
                    return LatencyStats(
                        minimum: minimum,
                        average: average,
                        maximum: maximum,
                        standardDeviation: parseDoublePrefix(components[3]) ?? 0
                    )
                }
            }
        }

        return nil
    }

    private static func parseDoublePrefix(_ text: Substring) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) {
            return value
        }

        guard let firstComponent = trimmed.split(separator: " ").first else {
            return nil
        }
        return Double(firstComponent)
    }

    private struct LatencyStats {
        var minimum: Double
        var average: Double
        var maximum: Double
        var standardDeviation: Double
    }

    private actor PingAccumulator {
        private var lineBuffer = ""
        private var receivedCount = 0
        private var minimumLatency: Double?
        private var maximumLatency: Double?
        private var meanLatency = 0.0
        private var sumOfSquaredDifferences = 0.0
        private var highestSequence = -1
        private var reportedTransmittedCount: Int?
        private var reportedReceivedCount: Int?

        func recordStandardOutput(_ text: String) {
            lineBuffer.append(text)

            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)
                recordLine(line)
            }
        }

        func recordStandardError(_ text: String) {
            for line in text.components(separatedBy: .newlines) {
                recordInfoLine(line)
            }
        }

        func snapshot(lastUpdated: Date) -> PingSnapshot {
            guard receivedCount > 0 else {
                return PingSnapshot(latencyMS: nil, packetLossPercent: nil, lastUpdated: lastUpdated)
            }

            let packetLossPercent: Double?
            if
                let reportedTransmittedCount,
                let reportedReceivedCount,
                reportedTransmittedCount > 0
            {
                packetLossPercent = max(
                    0,
                    (1 - (Double(reportedReceivedCount) / Double(reportedTransmittedCount))) * 100
                )
            } else if highestSequence >= 0 {
                let transmittedCount = highestSequence + 1
                packetLossPercent = max(0, (1 - (Double(receivedCount) / Double(transmittedCount))) * 100)
            } else {
                packetLossPercent = nil
            }

            return PingSnapshot(
                latencyMS: meanLatency,
                minLatencyMS: minimumLatency,
                maxLatencyMS: maximumLatency,
                standardDeviationMS: receivedCount > 1 ? sqrt(sumOfSquaredDifferences / Double(receivedCount - 1)) : 0,
                packetLossPercent: packetLossPercent,
                lastUpdated: lastUpdated
            )
        }

        private func recordLine(_ line: String) {
            guard let latency = value(after: "time=", in: line) else { return }

            receivedCount += 1
            minimumLatency = minimumLatency.map { min($0, latency) } ?? latency
            maximumLatency = maximumLatency.map { max($0, latency) } ?? latency

            let delta = latency - meanLatency
            meanLatency += delta / Double(receivedCount)
            sumOfSquaredDifferences += delta * (latency - meanLatency)

            if let sequence = integerValue(after: "icmp_seq=", in: line) {
                highestSequence = max(highestSequence, sequence)
            }
        }

        private func recordInfoLine(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                trimmed.contains("packets received"),
                let slashIndex = trimmed.firstIndex(of: "/")
            else {
                return
            }

            let receivedText = trimmed[..<slashIndex]
            let transmittedText = trimmed[trimmed.index(after: slashIndex)...]
                .split(separator: " ")
                .first

            guard
                let received = Int(receivedText),
                let transmittedText,
                let transmitted = Int(transmittedText)
            else {
                return
            }

            reportedReceivedCount = received
            reportedTransmittedCount = transmitted
        }

        private func value(after marker: String, in line: String) -> Double? {
            guard let markerRange = line.range(of: marker) else { return nil }
            let suffix = line[markerRange.upperBound...]
            guard let token = suffix.split(separator: " ").first else { return nil }
            return Double(token)
        }

        private func integerValue(after marker: String, in line: String) -> Int? {
            guard let markerRange = line.range(of: marker) else { return nil }
            let suffix = line[markerRange.upperBound...]
            guard let token = suffix.split(separator: " ").first else { return nil }
            return Int(token)
        }
    }
}
