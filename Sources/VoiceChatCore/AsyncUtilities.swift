import Foundation

public func withTimeout<T>(
    seconds: TimeInterval,
    operationName: String,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw VoiceChatError.timedOut(operationName)
        }

        guard let result = try await group.next() else {
            throw VoiceChatError.timedOut(operationName)
        }
        group.cancelAll()
        return result
    }
}
