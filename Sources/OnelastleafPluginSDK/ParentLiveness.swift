import Foundation
import Synchronization

/// Watches the parent-owned stdin pipe incrementally. It never buffers the
/// stream and removes Foundation's callback when the runtime is cancelled.
final class ParentLivenessMonitor: Sendable {
  private let input: FileHandle
  private let completion = AsyncResult<Void>()
  private let stopped = Mutex(false)

  init(input: FileHandle) {
    self.input = input
    input.readabilityHandler = { [weak self] handle in
      guard handle.availableData.isEmpty else { return }
      self?.finish()
    }
  }

  func waitForEOF() async throws {
    try await withTaskCancellationHandler {
      try await completion.value()
    } onCancel: {
      stop()
    }
  }

  func stop() {
    finish(error: CancellationError())
  }

  private func finish(error: (any Error)? = nil) {
    let first = stopped.withLock { stopped in
      guard !stopped else { return false }
      stopped = true
      return true
    }
    guard first else { return }
    input.readabilityHandler = nil
    if let error {
      completion.fail(error)
    } else {
      completion.succeed(())
    }
  }
}
