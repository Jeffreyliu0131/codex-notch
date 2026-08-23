import Foundation

public final class RolloutTaskStateReader {
    private struct CacheEntry {
        let fileSize: UInt64
        let modifiedAt: Date?
        let state: CodexTaskState?
    }

    private let fileManager: FileManager
    private let chunkSize = 64 * 1024
    private var cache: [String: CacheEntry] = [:]

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func state(atPath path: String) -> CodexTaskState? {
        guard !path.isEmpty,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }

        let fileSize = sizeNumber.uint64Value
        let modifiedAt = attributes[.modificationDate] as? Date
        if let cached = cache[path],
           cached.fileSize == fileSize,
           cached.modifiedAt == modifiedAt {
            return cached.state
        }

        let state = readLatestLifecycleState(
            from: URL(fileURLWithPath: path),
            fileSize: fileSize
        )
        cache[path] = CacheEntry(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            state: state
        )
        return state
    }

    private func readLatestLifecycleState(from url: URL, fileSize: UInt64) -> CodexTaskState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var cursor = fileSize
        var suffix = Data()

        while cursor > 0 {
            let readSize = Int(min(UInt64(chunkSize), cursor))
            cursor -= UInt64(readSize)

            do {
                try handle.seek(toOffset: cursor)
                guard let chunk = try handle.read(upToCount: readSize) else { return nil }
                var combined = chunk
                combined.append(suffix)

                while let newline = combined.lastIndex(of: 0x0A) {
                    let lineStart = combined.index(after: newline)
                    if lineStart < combined.endIndex,
                       let state = lifecycleState(from: combined[lineStart...]) {
                        return state
                    }
                    combined.removeSubrange(newline...)
                }

                suffix = combined
            } catch {
                return nil
            }
        }

        return suffix.isEmpty ? nil : lifecycleState(from: suffix[...])
    }

    private func lifecycleState(from line: Data.SubSequence) -> CodexTaskState? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let record = object as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        switch type {
        case "task_started":
            return .running
        case "task_complete":
            return .inactive
        default:
            return nil
        }
    }
}
