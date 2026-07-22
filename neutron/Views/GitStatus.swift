import SwiftUI

// MARK: - GitStatus

enum GitFileStatus {
    case modified, staged, untracked, conflict

    var color: Color {
        switch self {
        case .modified: return .orange
        case .staged: return .green
        case .untracked: return .gray
        case .conflict: return .red
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .staged: return "Staged"
        case .untracked: return "Untracked"
        case .conflict: return "Conflict"
        }
    }
}

class GitStatusProvider {
    static func gitRoot(for directory: URL) -> URL? {
        var current = directory
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    static func status(for directory: URL) -> [String: GitFileStatus] {
        guard let root = gitRoot(for: directory) else { return [:] }
        return statusInRepo(root: root)
    }

    static func statusInRepo(root: URL) -> [String: GitFileStatus] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "-uall"]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: GitFileStatus] = [:]
        for line in output.split(separator: "\n") {
            guard line.count >= 4 else { continue }
            let index = line.index(line.startIndex, offsetBy: 0)
            let work = line.index(line.startIndex, offsetBy: 1)
            let filePath = String(line.dropFirst(3))
            let fullPath = root.appendingPathComponent(filePath).path

            let x = line[index]
            let y = line[work]
            if x == "U" || y == "U" {
                result[fullPath] = .conflict
            } else if x != " " && x != "?" {
                result[fullPath] = .staged
            } else if y == "M" || y == "D" {
                result[fullPath] = .modified
            } else if x == "?" && y == "?" {
                result[fullPath] = .untracked
            }
        }
        return result
    }
}
