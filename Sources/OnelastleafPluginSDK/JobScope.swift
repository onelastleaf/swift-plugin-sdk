import OnelastleafPluginProtocol
import Synchronization

/// Tracks in-flight SDK output and stored artifacts for one job. Closing the
/// scope prevents detached work from emitting after a terminal event or cancel
/// acknowledgement; the action runner waits for already-started operations.
final class JobScope: Sendable {
  private struct State: Sendable {
    var acceptsOperations = true
    var operationCount = 0
    var drainWaiter: CheckedContinuation<Void, Never>?
    var artifacts: [String: Oll_Protocol_ArtifactDescriptor] = [:]
  }

  private let state = Mutex(State())

  func perform<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
  ) async throws -> Value {
    try beginOperation()
    defer { endOperation() }
    return try await operation()
  }

  func stopAdmission() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.acceptsOperations = false
      guard state.operationCount == 0 else { return nil }
      defer { state.drainWaiter = nil }
      return state.drainWaiter
    }
    waiter?.resume()
  }

  func waitUntilDrained() async {
    stopAdmission()
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state in
        guard state.operationCount != 0 else { return true }
        precondition(state.drainWaiter == nil, "job scope may have only one drain waiter")
        state.drainWaiter = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func recordStoredArtifact(_ descriptor: Oll_Protocol_ArtifactDescriptor) throws {
    let artifactID = descriptor.artifactID.value
    try state.withLock { state in
      guard state.artifacts[artifactID] == nil else {
        throw PluginSDKError.invalidArgument(
          "artifact \(artifactID) was already stored by this job"
        )
      }
      state.artifacts[artifactID] = descriptor
    }
  }

  func validateResultArtifacts(_ descriptors: [Oll_Protocol_ArtifactDescriptor]) throws {
    try state.withLock { state in
      var seen = Set<String>()
      for descriptor in descriptors {
        let artifactID = descriptor.artifactID.value
        guard seen.insert(artifactID).inserted else {
          throw PluginSDKError.invalidArgument(
            "action result contains the same artifact more than once"
          )
        }
        guard state.artifacts[artifactID] == descriptor else {
          throw PluginSDKError.invalidArgument(
            "action result references an artifact that this job did not store"
          )
        }
      }
    }
  }

  private func beginOperation() throws {
    try state.withLock { state in
      guard state.acceptsOperations else { throw CancellationError() }
      let (count, overflow) = state.operationCount.addingReportingOverflow(1)
      guard !overflow else {
        throw PluginSDKError.action("too many concurrent job operations")
      }
      state.operationCount = count
    }
  }

  private func endOperation() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      precondition(state.operationCount > 0, "unbalanced job-scope operation")
      state.operationCount -= 1
      guard !state.acceptsOperations, state.operationCount == 0 else { return nil }
      defer { state.drainWaiter = nil }
      return state.drainWaiter
    }
    waiter?.resume()
  }
}
