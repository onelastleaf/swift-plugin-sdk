import Foundation
import OnelastleafPluginProtocol
import SwiftProtobuf

struct HostClient: Sendable {
  let sender: EnvelopeSender
  let pending: PendingResponses
  let sessionID: String
  let maximumArtifactChunkBytes: UInt64
  let maximumCallDepth: UInt32

  func call(
    _ call: Oll_Protocol_HostCallRequest.OneOf_Call,
    trace: Oll_Protocol_TraceContext
  ) async throws -> Oll_Protocol_HostCallResponse {
    try validate(call)
    var request = Oll_Protocol_HostCallRequest()
    request.call = call
    switch try await self.request(payload: .hostCall(request), trace: trace) {
    case .hostResult(let response):
      guard let result = response.result else {
        throw PluginSDKError.protocolViolation("HostCallResponse result is required")
      }
      if case .error(let error) = result { throw PluginSDKError.host(error) }
      guard result.matches(call) else {
        throw PluginSDKError.protocolViolation(
          "host call received another response kind"
        )
      }
      try validate(response: result)
      return response
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    default:
      throw PluginSDKError.protocolViolation(
        "host call received another response payload"
      )
    }
  }

  func request(
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload,
    trace: Oll_Protocol_TraceContext
  ) async throws -> Oll_Protocol_PluginEnvelope.OneOf_Payload {
    try Task.checkCancellation()
    let request = try sender.sendRequest(
      trace: trace,
      payload: payload,
      pending: pending
    )
    return try await withTaskCancellationHandler {
      try await request.value()
    } onCancel: {
      pending.cancel(messageID: request.messageID)
    }
  }

  private func validate(_ call: Oll_Protocol_HostCallRequest.OneOf_Call) throws {
    guard case .invokeConfigFunction(let request) = call else { return }
    guard request.hasFunction,
      request.function.sessionID == sessionID,
      !request.function.functionID.isEmpty
    else {
      throw PluginSDKError.invalidArgument(
        "configuration function must belong to the active plugin session"
      )
    }
    for value in request.arguments {
      try validateConfigValue(value, policy: .functionArguments(sessionID: sessionID))
    }
  }

  private func validate(
    response: Oll_Protocol_HostCallResponse.OneOf_Result
  ) throws {
    do {
      switch response {
      case .getConfig(let result):
        guard result.hasValue else {
          throw PluginSDKError.protocolViolation("GetConfig response value is required")
        }
        try validateConfigValue(
          result.value,
          policy: .functionArguments(sessionID: sessionID)
        )
      case .invokeConfigFunction(let result):
        for value in result.results {
          try validateConfigValue(
            value,
            policy: .functionArguments(sessionID: sessionID)
          )
        }
      default:
        return
      }
    } catch let error as PluginSDKError {
      if case .protocolViolation = error { throw error }
      throw PluginSDKError.protocolViolation(error.description)
    }
  }
}

extension Oll_Protocol_HostCallResponse.OneOf_Result {
  fileprivate func matches(_ call: Oll_Protocol_HostCallRequest.OneOf_Call) -> Bool {
    switch (call, self) {
    case (.readDocument, .readDocument),
      (.listDirectory, .listDirectory),
      (.getDirectoryTree, .getDirectoryTree),
      (.readCrdt, .readCrdt),
      (.commitDocuments, .commitDocuments),
      (.getConfig, .getConfig),
      (.invokeConfigFunction, .invokeConfigFunction):
      return true
    default:
      return false
    }
  }
}

extension ActionContext {
  /// Invokes a low-level host capability for the current job.
  ///
  /// Prefer ``getConfig(_:)`` and ``invokeConfigFunction(_:arguments:)`` for their
  /// corresponding operations. Use this method for document and CRDT capabilities
  /// represented by `Oll_Protocol_HostCallRequest.OneOf_Call`.
  ///
  /// The SDK validates the request, preserves the job's trace and call depth, and
  /// checks that the response kind matches the request kind.
  ///
  /// - Parameter call: The protocol request variant to send to oll.
  /// - Returns: The matching host response envelope.
  /// - Throws: `CancellationError` when the job is cancelled. Other validation,
  ///   host, call-depth, transport, and protocol failures use ``PluginSDKError``.
  public func hostCall(
    _ call: Oll_Protocol_HostCallRequest.OneOf_Call
  ) async throws -> Oll_Protocol_HostCallResponse {
    try await scope.perform {
      try cancellation.checkActive()
      return try await host.call(call, trace: nestedTrace())
    }
  }

  /// Reads the plugin's current host-owned configuration.
  ///
  /// Configuration is authoritative in oll and is read when this method is called;
  /// the SDK does not cache it in a file. An empty path reads the root value. List
  /// indexes in a path are zero-based.
  ///
  /// - Parameter path: A path relative to the current plugin configuration root.
  /// - Returns: The configuration response for that path.
  /// - Throws: `CancellationError` when the job is cancelled. An invalid path,
  ///   rejected request, transport failure, or invalid response uses
  ///   ``PluginSDKError``.
  public func getConfig(
    _ path: Oll_Protocol_ConfigPath = Oll_Protocol_ConfigPath()
  ) async throws -> Oll_Protocol_GetConfigResponse {
    try await scope.perform {
      try cancellation.checkActive()
      var request = Oll_Protocol_GetConfigRequest()
      request.path = path
      let response = try await host.call(.getConfig(request), trace: nestedTrace())
      guard case .getConfig(let value)? = response.result else {
        throw PluginSDKError.protocolViolation(
          "host returned another response kind for GetConfig"
        )
      }
      return value
    }
  }

  /// Invokes a configuration closure owned by the active oll session.
  ///
  /// A function reference is an in-memory handle into oll's configuration runtime.
  /// It is valid only for the session that returned it and must not be persisted or
  /// reused after reconnection.
  ///
  /// - Parameters:
  ///   - function: A function reference obtained from configuration in this session.
  ///   - arguments: Structured arguments. Function handles among them must also
  ///     belong to the same active session.
  /// - Returns: The ordered structured values returned by the configuration function.
  /// - Throws: `CancellationError` when the job is cancelled. A stale or malformed
  ///   reference, invalid argument, host error, transport failure, or protocol
  ///   violation uses ``PluginSDKError``.
  public func invokeConfigFunction(
    _ function: Oll_Protocol_ConfigFunctionRef,
    arguments: [Oll_Protocol_ConfigValue] = []
  ) async throws -> Oll_Protocol_InvokeConfigFunctionResponse {
    try await scope.perform {
      try cancellation.checkActive()
      var request = Oll_Protocol_InvokeConfigFunctionRequest()
      request.function = function
      request.arguments = arguments
      let response = try await host.call(
        .invokeConfigFunction(request),
        trace: nestedTrace()
      )
      guard case .invokeConfigFunction(let value)? = response.result else {
        throw PluginSDKError.protocolViolation(
          "host returned another response kind for InvokeConfigFunction"
        )
      }
      return value
    }
  }

  /// Emits a structured log record associated with this job.
  ///
  /// The SDK supplies the timestamp and job trace. Field values must be serializable
  /// and cannot contain session-scoped configuration function references.
  ///
  /// - Parameters:
  ///   - level: A known severity other than `unspecified`.
  ///   - target: A nonempty subsystem or component name used to group records.
  ///   - message: The human-readable log message.
  ///   - fields: Optional structured context such as counts, identifiers, or paths.
  /// - Throws: `CancellationError` when the job is cancelled or already settled.
  ///   Invalid fields, levels, or targets use ``PluginSDKError``.
  public func log(
    level: Oll_Protocol_LogLevel,
    target: String,
    message: String,
    fields: [String: Oll_Protocol_ConfigValue] = [:]
  ) async throws {
    try await scope.perform {
      try cancellation.checkActive()
      guard level != .unspecified,
        !level.isUnrecognized,
        !target.isEmpty
      else {
        throw PluginSDKError.invalidArgument(
          "log level must be known and target must not be empty"
        )
      }
      for value in fields.values {
        try validateConfigValue(value, policy: .serializable)
      }
      var record = Oll_Protocol_LogRecord()
      record.timestamp = Google_Protobuf_Timestamp(date: Date())
      record.level = level
      record.target = target
      record.message = message
      record.fields = fields
      try host.sender.send(trace: trace, payload: .log(record))
    }
  }

}

extension Oll_Protocol_LogLevel {
  fileprivate var isUnrecognized: Bool {
    if case .UNRECOGNIZED = self { return true }
    return false
  }
}
