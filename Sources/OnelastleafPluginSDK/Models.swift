import Foundation
import OnelastleafPluginProtocol
import SwiftProtobuf
import Synchronization

/// The structured value and stored artifacts returned by an action.
public struct ActionResult: Sendable {
  /// The optional structured result value delivered to the caller.
  ///
  /// Leave this property `nil` when the action has no value to return. Values must
  /// obey the protocol's finite-number, timestamp, duration, nesting, and
  /// serialization rules.
  public var value: Oll_Protocol_ConfigValue?

  /// Descriptors for artifacts already stored through the current ``ActionContext``.
  ///
  /// oll rejects descriptors that were not acknowledged for the same job, including
  /// descriptors that differ from the stored artifact in any field.
  public var artifacts: [Oll_Protocol_ArtifactDescriptor]

  /// Creates an action result from a structured value and stored artifacts.
  ///
  /// The SDK validates both fields before it sends the terminal job update. Use the
  /// scalar convenience methods when returning a common value type.
  ///
  /// - Parameters:
  ///   - value: The optional structured result, or `nil` for no result value.
  ///   - artifacts: Exact descriptors passed to successful artifact storage calls
  ///     in this job.
  public init(
    value: Oll_Protocol_ConfigValue? = nil,
    artifacts: [Oll_Protocol_ArtifactDescriptor] = []
  ) {
    self.value = value
    self.artifacts = artifacts
  }

  /// Creates a result containing a string value.
  ///
  /// - Parameter value: The string to return.
  /// - Returns: An action result whose structured value is the supplied string.
  public static func string(_ value: String) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.stringValue = value
    return Self(value: encoded)
  }

  /// Creates a result containing a Boolean value.
  ///
  /// - Parameter value: The Boolean to return.
  /// - Returns: An action result whose structured value is the supplied Boolean.
  public static func boolean(_ value: Bool) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.boolValue = value
    return Self(value: encoded)
  }

  /// Creates a result containing a signed 64-bit integer.
  ///
  /// - Parameter value: The integer to return.
  /// - Returns: An action result whose structured value is the supplied integer.
  public static func integer(_ value: Int64) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.integerValue = value
    return Self(value: encoded)
  }

  /// Creates a result containing a finite floating-point number.
  ///
  /// - Parameter value: The finite number to return.
  /// - Returns: An action result whose structured value is the supplied number.
  /// - Throws: ``PluginSDKError/invalidArgument(_:)`` when `value` is NaN or
  ///   positive or negative infinity.
  public static func number(_ value: Double) throws -> Self {
    guard value.isFinite else {
      throw PluginSDKError.invalidArgument("action numbers must be finite")
    }
    var encoded = Oll_Protocol_ConfigValue()
    encoded.numberValue = value
    return Self(value: encoded)
  }

  /// Creates a result containing arbitrary bytes.
  ///
  /// Use ``ActionContext/storeArtifact(descriptor:chunkCount:chunks:)`` for large
  /// payloads so the complete value does not need to fit in memory.
  ///
  /// - Parameter value: The bytes to return inline.
  /// - Returns: An action result whose structured value is the supplied data.
  public static func bytes(_ value: Data) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.bytesValue = value
    return Self(value: encoded)
  }
}

/// Cooperative cancellation state for one action invocation.
///
/// oll cancels one job without terminating other jobs in the same process. Check
/// this token inside long loops and before expensive or externally visible work.
/// The SDK also observes Swift task cancellation.
public final class CancellationToken: Sendable {
  private enum State: Sendable {
    case active
    case cancelled
    case finished
  }

  private let state = Mutex<State>(.active)

  /// Whether oll or the surrounding Swift task has requested cancellation.
  ///
  /// This property is intended for branches that can stop without throwing. Prefer
  /// ``checkCancellation()`` when the current operation can propagate an error.
  public var isCancelled: Bool {
    state.withLock { $0 == .cancelled } || Task.isCancelled
  }

  /// Throws when cancellation has been requested for this job.
  ///
  /// - Throws: `CancellationError` after oll requests cancellation or the
  ///   surrounding Swift task is cancelled.
  public func checkCancellation() throws {
    if isCancelled { throw CancellationError() }
  }

  func checkActive() throws {
    let active = state.withLock { $0 == .active }
    if !active || Task.isCancelled { throw CancellationError() }
  }

  func cancel() {
    state.withLock { state in
      if state == .active { state = .cancelled }
    }
  }

  func finish() {
    state.withLock { state in
      if state == .active { state = .finished }
    }
  }
}

/// Per-invocation context. Its host operations preserve the job's trace and
/// stop accepting output once the action settles or is cancelled.
///
/// The SDK creates this value for the action handler. Do not construct or retain a
/// context for later jobs: its cancellation token, trace, and host-call scope belong
/// only to the current invocation.
public struct ActionContext: Sendable {
  /// The host-generated immutable identifier for this job.
  public let jobID: String

  /// The absolute protobuf deadline supplied by oll, or `nil` when none was set.
  ///
  /// Use ``cancellation`` for cooperative interruption. This value is informational;
  /// cancellation begins when oll sends a job-scoped cancellation request.
  public let deadline: Google_Protobuf_Timestamp?

  /// The cooperative cancellation token for this job.
  public let cancellation: CancellationToken

  let trace: Oll_Protocol_TraceContext
  let host: HostClient
  let parentCallID: UInt64
  let scope: JobScope

  /// The largest artifact chunk, in bytes, accepted by this oll session.
  ///
  /// Split nonempty artifacts so every chunk is nonempty and no larger than this
  /// value. The limit is negotiated during the session handshake.
  public var maximumArtifactChunkBytes: UInt64 {
    host.maximumArtifactChunkBytes
  }

  func nestedTrace() throws -> Oll_Protocol_TraceContext {
    var child = trace
    child.parentCallID = parentCallID
    let (depth, overflow) = child.callDepth.addingReportingOverflow(1)
    guard !overflow, depth <= host.maximumCallDepth else {
      throw PluginSDKError.callDepthExceeded(maximum: host.maximumCallDepth)
    }
    child.callDepth = depth
    return child
  }
}

struct RegisteredAction: Sendable {
  let description: String
  let handler: @Sendable (ActionContext, [String]) async throws -> ActionResult
}
