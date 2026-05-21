import Foundation

enum ProcessRunnerError: Error {
    case launchPathMissing(String)
    case nonZeroExit(Int32, String)
}

struct ProcessOutput {
    var stdout: String
    var stderr: String
    var status: Int32
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessRunnerError.launchPathMissing(executable))
                return
            }

            if let stdin {
                stdinPipe.fileHandleForWriting.write(stdin)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                }
            }

            process.terminationHandler = { process in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessOutput(stdout: stdout, stderr: stderr, status: process.terminationStatus))
            }
        }
    }
}
