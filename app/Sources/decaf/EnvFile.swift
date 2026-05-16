import Foundation

/// Minimal `.env` reader/writer that preserves unknown lines (comments, blanks,
/// other keys). Quotes around values are stripped on read but not re-added on
/// write — bash `load_telegram_creds` accepts both forms.
struct EnvFile {
    let path: String

    func read() -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// Writes `updates` into the file, preserving lines we don't touch. New keys
    /// are appended at the end. Keys with empty values are removed entirely.
    func write(updates: [String: String]) throws {
        let original = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pendingUpdates = updates

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            guard let newValue = pendingUpdates[key] else { continue }
            pendingUpdates.removeValue(forKey: key)
            if newValue.isEmpty {
                lines[i] = ""   // removal marker; we'll drop these below
            } else {
                lines[i] = "\(key)=\(newValue)"
            }
        }

        for (key, value) in pendingUpdates where !value.isEmpty {
            lines.append("\(key)=\(value)")
        }

        // Drop the empty-string removal markers we just inserted, but keep
        // legitimately-empty separator lines that were already in the file.
        let final = lines.enumerated()
            .compactMap { idx, line -> String? in
                if line.isEmpty && idx < lines.count - 1 && lines[idx + 1].isEmpty { return nil }
                return line
            }
            .joined(separator: "\n")

        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try final.write(toFile: path, atomically: true, encoding: .utf8)
        // .env contains secrets — restrict perms.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
