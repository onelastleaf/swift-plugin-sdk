import Foundation
import SwiftProtobuf

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

public actor CancellationToken {
  private var cancelled = false

  public var isCancelled: Bool { cancelled || Task.isCancelled }

  public func checkCancellation() throws {
    if cancelled || Task.isCancelled {
      throw CancellationError()
    }
  }

  func cancel() {
    cancelled = true
  }
}

public struct ActionContext: Sendable {
  public let jobID: String
  public let deadline: Google_Protobuf_Timestamp?
  public let trace: Oll_Protocol_TraceContext
  public let cancellation: CancellationToken
  public let host: HostClient
  let parentCallID: UInt64

  func nestedTrace() throws -> Oll_Protocol_TraceContext {
    var child = trace
    child.parentCallID = parentCallID
    let (depth, overflow) = child.callDepth.addingReportingOverflow(1)
    guard !overflow, depth <= host.maximumCallDepth else {
      throw PluginSDKError.protocolViolation(
        "host call exceeds the negotiated call-depth limit"
      )
    }
    child.callDepth = depth
    return child
  }
}

struct RegisteredAction: Sendable {
  let description: String
  let handler: @Sendable (ActionContext, [String]) async throws -> ActionResult
}
