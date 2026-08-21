import Foundation
import OnelastleafPluginProtocol
import SwiftProtobuf
import Synchronization

/// The structured value and stored artifacts returned by an action.
public struct ActionResult: Sendable {
  public var value: Oll_Protocol_ConfigValue?
  public var artifacts: [Oll_Protocol_ArtifactDescriptor]

  public init(
    value: Oll_Protocol_ConfigValue? = nil,
    artifacts: [Oll_Protocol_ArtifactDescriptor] = []
  ) {
    self.value = value
    self.artifacts = artifacts
  }

  public static func string(_ value: String) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.stringValue = value
    return Self(value: encoded)
  }

  public static func boolean(_ value: Bool) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.boolValue = value
    return Self(value: encoded)
  }

  public static func integer(_ value: Int64) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.integerValue = value
    return Self(value: encoded)
  }

  public static func number(_ value: Double) throws -> Self {
    guard value.isFinite else {
      throw PluginSDKError.invalidArgument("action numbers must be finite")
    }
    var encoded = Oll_Protocol_ConfigValue()
    encoded.numberValue = value
    return Self(value: encoded)
  }

  public static func bytes(_ value: Data) -> Self {
    var encoded = Oll_Protocol_ConfigValue()
    encoded.bytesValue = value
    return Self(value: encoded)
  }
}

/// Cooperative cancellation state for one action invocation.
public final class CancellationToken: Sendable {
  private enum State: Sendable {
    case active
    case cancelled
    case finished
  }

  private let state = Mutex<State>(.active)

  public var isCancelled: Bool {
    state.withLock { $0 == .cancelled } || Task.isCancelled
  }

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
public struct ActionContext: Sendable {
  public let jobID: String
  public let deadline: Google_Protobuf_Timestamp?
  public let cancellation: CancellationToken

  let trace: Oll_Protocol_TraceContext
  let host: HostClient
  let parentCallID: UInt64
  let scope: JobScope

  /// The largest artifact chunk accepted by this oll session.
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
