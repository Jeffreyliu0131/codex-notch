import Foundation

public struct TaskRepositorySnapshot {
    public let local: Result<[CodexTask], Error>
    public let remote: Result<[CodexTask], Error>
}

/// Repository I/O is actor-isolated, never executed by the UI's MainActor.
public actor TaskSnapshotLoader {
    private let local: LocalTaskRepository
    private let remote: RemoteTaskRepository

    public init(local: LocalTaskRepository, remote: RemoteTaskRepository) {
        self.local = local
        self.remote = remote
    }

    public func load() throws -> TaskRepositorySnapshot {
        try Task.checkCancellation()
        let localResult = Result { try local.loadTasks(limit: 50) }
        try Task.checkCancellation()
        let remoteResult = Result { try remote.loadTasks(limitPerHost: 50) }
        try Task.checkCancellation()
        return TaskRepositorySnapshot(local: localResult, remote: remoteResult)
    }
}
