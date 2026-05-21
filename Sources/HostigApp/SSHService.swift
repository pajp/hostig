import Foundation

enum SSHServiceError: LocalizedError {
    case authenticationFailed(String)
    case metricsFailed(String)
    case rebootFailed(String)
    case sudoPasswordRequired
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message):
            return message
        case .metricsFailed(let message):
            return message
        case .rebootFailed(let message):
            return message
        case .sudoPasswordRequired:
            return "A sudo password is required."
        case .malformedResponse:
            return "Received malformed host metrics."
        }
    }
}

struct SSHService {
    func probe(host: String, port: Int) async throws {
        let output = try await runSSH(host: host, port: port, remoteCommand: "printf '__HOSTIG_OK__\\n'")
        guard output.status == 0, output.stdout.contains("__HOSTIG_OK__") else {
            throw SSHServiceError.authenticationFailed(compactError(output.stderr, fallback: output.stdout))
        }
    }

    func fetchMetrics(host: String, port: Int) async throws -> HostMetrics {
        let script = #"""
        LC_ALL=C
        LANG=C
        export LC_ALL LANG
        os=$(uname -s 2>/dev/null || echo Unknown)
        os_version=""
        if [ "$os" = "Darwin" ]; then
          os_version=$(sw_vers -productVersion 2>/dev/null || true)
        elif [ "$os" = "Linux" ]; then
          if [ -r /etc/os-release ]; then
            os_version=$(awk -F= '/^VERSION_ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
          fi
          if [ -z "$os_version" ]; then
            os_version=$(uname -r 2>/dev/null || true)
          fi
        else
          os_version=$(uname -r 2>/dev/null || true)
        fi
        uptime_raw=$(uptime 2>/dev/null || true)
        uptime_text=$(printf '%s\n' "$uptime_raw" | sed 's/.* up /up /' | sed 's/, *[0-9][0-9]* users\{0,1\}.*//')
        load=$(printf '%s\n' "$uptime_raw" | sed -n 's/.*load averages*: //p' | sed -n '1p')
        if [ -z "$load" ]; then
          load=$(printf '%s\n' "$uptime_raw" | sed -n 's/.*load average: //p' | sed -n '1p')
        fi
        disk=$(df -kP / 2>/dev/null | awk 'NR==2 {print $4 "|" $5}')
        users=$(who 2>/dev/null | wc -l | tr -d ' ')
        cpu=""
        mem=""
        if [ "$os" = "Darwin" ]; then
          cpu=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage:/ {u=$3; s=$5; gsub("%","",u); gsub("%","",s); printf "%.1f", u + s; exit}')
          mem=$(vm_stat 2>/dev/null | awk '
            /page size of/ {gsub("\\.","", $8); pageSize=$8}
            /Anonymous pages:/ {gsub("\\.","", $3); anonymous=$3}
            /Pages wired down:/ {gsub("\\.","", $4); wired=$4}
            /Pages purgeable:/ {gsub("\\.","", $3); purgeable=$3}
            END {
              pageSize += 0
              anonymous += 0
              wired += 0
              purgeable += 0
              if (pageSize > 0) {
                usedBytes = (anonymous + wired - purgeable) * pageSize
                if (usedBytes < 0) usedBytes = 0
                printf "%.0f", usedBytes
              }
            }')
          if [ -z "$mem" ]; then
            mem=$(vm_stat 2>/dev/null | awk '
            /Pages active/ {gsub("\\.","", $3); active=$3}
            /Pages wired down/ {gsub("\\.","", $4); wired=$4}
            /Pages occupied by compressor/ {gsub("\\.","", $5); comp=$5}
            /Pages free/ {gsub("\\.","", $3); free=$3}
            END {
              active += 0
              wired += 0
              comp += 0
              free += 0
              used=active+wired+comp
              total=used+free
              if (total > 0) printf "%.1f", (used / total) * 100
            }')
          else
            totalMem=$(sysctl -n hw.memsize 2>/dev/null || true)
            if [ -n "$totalMem" ] && [ "$totalMem" -gt 0 ] 2>/dev/null; then
              mem=$(awk -v used="$mem" -v total="$totalMem" 'BEGIN { printf "%.1f", (used / total) * 100 }')
            else
              mem=""
            fi
          fi
          if [ -z "$mem" ]; then
            mem=$(top -l 1 -n 0 2>/dev/null | awk '
              function tobytes(value, num, unit) {
                num = value
                sub(/[KMGTP]$/, "", num)
                unit = substr(value, length(value), 1)
                if (unit ~ /[0-9]/) return num
                if (unit == "K") return num * 1024
                if (unit == "M") return num * 1024 * 1024
                if (unit == "G") return num * 1024 * 1024 * 1024
                if (unit == "T") return num * 1024 * 1024 * 1024 * 1024
                if (unit == "P") return num * 1024 * 1024 * 1024 * 1024 * 1024
                return num
              }
              $1 == "PhysMem:" {
                used = $2
                unused = $(NF-1)
                gsub(",", "", used)
                gsub(",", "", unused)
                usedBytes = tobytes(used)
                unusedBytes = tobytes(unused)
                totalBytes = usedBytes + unusedBytes
                if (totalBytes > 0) {
                  printf "%.1f", (usedBytes / totalBytes) * 100
                  exit
                }
              }')
          fi
        elif [ "$os" = "Linux" ]; then
          cpu=$(top -bn1 2>/dev/null | awk -F',' '/^%Cpu|^%Cpu\(s\)/ {
            idle=$4
            gsub("%", "", idle)
            gsub(" id", "", idle)
            gsub("id", "", idle)
            printf "%.1f", 100 - idle
            exit
          }')
          mem=$(free 2>/dev/null | awk '/^Mem:/ {if ($2 > 0) printf "%.1f", ($3 / $2) * 100}')
        fi
        printf 'os=%s\n' "$os"
        printf 'os_version=%s\n' "$os_version"
        printf 'uptime=%s\n' "$uptime_text"
        printf 'load=%s\n' "$load"
        printf 'disk=%s\n' "$disk"
        printf 'users=%s\n' "$users"
        printf 'cpu=%s\n' "$cpu"
        printf 'mem=%s\n' "$mem"
        """#

        let output = try await runSSH(host: host, port: port, remoteCommand: "/bin/sh -c \(shellQuoted(script))")
        guard output.status == 0 else {
            throw SSHServiceError.metricsFailed(compactError(output.stderr, fallback: output.stdout, defaultMessage: "Connected over SSH, but failed to read host metrics."))
        }

        let map = Dictionary(
            uniqueKeysWithValues: output.stdout
                .split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0], parts[1])
                }
        )

        guard
            let uptime = map["uptime"],
            let load = map["load"],
            let disk = map["disk"],
            let usersString = map["users"],
            let os = map["os"]
        else {
            throw SSHServiceError.metricsFailed(SSHServiceError.malformedResponse.localizedDescription)
        }
        let osVersion = map["os_version"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let diskParts = disk.split(separator: "|").map(String.init)
        let diskFreeKB = Double(diskParts.first ?? "") ?? 0
        let diskUsedPercent = parsePercent(diskParts.dropFirst().first ?? "")
        let cpu = parseNumber(map["cpu"] ?? "") ?? 0
        let mem = parseNumber(map["mem"] ?? "")
        let users = Int(usersString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return HostMetrics(
            uptime: uptime.isEmpty ? "Unavailable" : uptime,
            loadAverage: load.isEmpty ? "Unavailable" : load,
            cpuPercent: cpu,
            diskUsedPercent: diskUsedPercent,
            diskFree: ByteCountFormatter.string(fromByteCount: Int64(diskFreeKB * 1024), countStyle: .file),
            memoryUsedPercent: mem,
            userCount: users,
            operatingSystem: os,
            operatingSystemVersion: osVersion.isEmpty ? "Unavailable" : osVersion,
            lastUpdated: .now
        )
    }

    func reboot(host: String, port: Int, sudoPassword: String? = nil) async throws -> RebootResolution {
        if let sudoPassword {
            let output = try await runSSH(
                host: host,
                port: port,
                remoteCommand: "sudo -S -p '' reboot",
                stdin: Data((sudoPassword + "\n").utf8),
                forceTTY: true,
                timeout: 20
            )

            if rebootWasAccepted(output) {
                return .started
            }

            let message = compactError(output.stderr, fallback: output.stdout, defaultMessage: "Remote reboot failed.")
            if indicatesBadSudoPassword(message) {
                throw SSHServiceError.rebootFailed("Incorrect sudo password.")
            }
            throw SSHServiceError.rebootFailed(message)
        }

        let output = try await runSSH(
            host: host,
            port: port,
            remoteCommand: "sudo -n reboot",
            timeout: 15
        )

        if rebootWasAccepted(output) {
            return .started
        }

        let message = compactError(output.stderr, fallback: output.stdout, defaultMessage: "Remote reboot failed.")
        if requiresSudoPassword(message) {
            return .passwordRequired
        }
        throw SSHServiceError.rebootFailed(message)
    }

    private func runSSH(
        host: String,
        port: Int,
        remoteCommand: String,
        stdin: Data? = nil,
        forceTTY: Bool = false,
        timeout: TimeInterval = 12
    ) async throws -> ProcessOutput {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-p", String(port)
        ]

        if forceTTY {
            arguments.append("-tt")
        }

        arguments.append(host)
        arguments.append(remoteCommand)

        return try await ProcessRunner.run(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func compactError(_ stderr: String, fallback: String, defaultMessage: String = "SSH authentication failed.") -> String {
        let message = [stderr, fallback]
            .joined(separator: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? defaultMessage
        return message
    }

    private func parsePercent(_ text: String) -> Double {
        parseNumber(text.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    private func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) {
            return value
        }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func requiresSudoPassword(_ message: String) -> Bool {
        let lowercase = message.lowercased()
        return lowercase.contains("password is required")
            || lowercase.contains("a terminal is required")
            || lowercase.contains("sudo:")
    }

    private func indicatesBadSudoPassword(_ message: String) -> Bool {
        let lowercase = message.lowercased()
        return lowercase.contains("incorrect password")
            || lowercase.contains("sorry, try again")
    }

    private func rebootWasAccepted(_ output: ProcessOutput) -> Bool {
        if output.status == 0 {
            return true
        }

        let text = (output.stdout + "\n" + output.stderr).lowercased()
        return text.contains("connection to ")
            || text.contains("connection closed")
            || text.contains("connection reset by peer")
            || text.contains("broken pipe")
    }
}
