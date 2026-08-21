import Synchronization

/// A single-consumer result used where checked continuations need to tolerate
/// completion-before-wait races. The mutex is never held while resuming.
final class AsyncResult<Value: Sendable>: Sendable {
  private enum State: Sendable {
    case pending
    case waiting(CheckedContinuation<Result<Value, any Error>, Never>)
    case resolved(Result<Value, any Error>)
  }

  private enum Registration {
    case stored
    case resume(Result<Value, any Error>)
  }

  private let state = Mutex<State>(.pending)

  func value() async throws -> Value {
    try await withTaskCancellationHandler {
      try await valueIgnoringCancellation()
    } onCancel: {
      fail(CancellationError())
    }
  }

  func valueIgnoringCancellation() async throws -> Value {
    let result = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<Value, any Error>, Never>) in
      let registration = state.withLock { state -> Registration in
        switch state {
        case .pending:
          state = .waiting(continuation)
          return .stored
        case .resolved(let result):
          return .resume(result)
        case .waiting:
          return .resume(
            .failure(PluginSDKError.protocolViolation("one-shot result was awaited twice"))
          )
        }
      }
      if case .resume(let result) = registration {
        continuation.resume(returning: result)
      }
    }
    return try result.get()
  }

  @discardableResult
  func succeed(_ value: Value) -> Bool {
    resolve(.success(value))
  }

  @discardableResult
  func fail(_ error: any Error) -> Bool {
    resolve(.failure(error))
  }

  private func resolve(_ result: Result<Value, any Error>) -> Bool {
    let resolution = state.withLock {
      state -> (Bool, CheckedContinuation<Result<Value, any Error>, Never>?) in
      switch state {
      case .pending:
        state = .resolved(result)
        return (true, nil)
      case .waiting(let continuation):
        state = .resolved(result)
        return (true, continuation)
      case .resolved:
        return (false, nil)
      }
    }
    resolution.1?.resume(returning: result)
    return resolution.0
  }
}
