import Foundation

/// Sends a plain-text email via a local SMTP relay (e.g. MailRelay on
/// 127.0.0.1:2525) using `curl`'s SMTP support. The relay handles upstream
/// authentication, TLS and queueing, so we send unauthenticated plaintext to
/// localhost — no credentials are stored in this app.
enum Mailer {
    struct Config {
        var host: String
        var port: Int
        var sender: String     // may include a display name, e.g. "MatterServer <ms@host>"
        var recipient: String
    }

    enum MailError: LocalizedError {
        case missingRecipient
        case curlFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .missingRecipient: return "No recipient address configured."
            case .curlFailed(let code, let output):
                return "curl exited with code \(code): \(output)"
            }
        }
    }

    static func send(subject: String, body: String, config: Config) async throws {
        let recipientAddress = address(in: config.recipient)
        guard !recipientAddress.isEmpty else { throw MailError.missingRecipient }
        let senderAddress = address(in: config.sender)

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        // RFC 5322 message with CRLF line endings.
        let headers = [
            "From: \(config.sender)",
            "To: \(config.recipient)",
            "Subject: \(subject)",
            "Date: \(df.string(from: Date()))",
            "Content-Type: text/plain; charset=utf-8",
            "",
        ]
        let message = (headers.joined(separator: "\r\n") + "\r\n"
            + body.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("matter-mail-\(UUID().uuidString).eml")
        try message.data(using: .utf8)?.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await runCurl([
            "--silent", "--show-error",
            "--url", "smtp://\(config.host):\(config.port)",
            "--mail-from", senderAddress,
            "--mail-rcpt", recipientAddress,
            "--upload-file", tmp.path,
        ])
    }

    /// Extract the bare address from a "Display Name <addr@host>" string.
    private static func address(in value: String) -> String {
        if let open = value.firstIndex(of: "<"), let close = value.firstIndex(of: ">"), open < close {
            return String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func runCurl(_ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = args
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: MailError.curlFailed(p.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}
