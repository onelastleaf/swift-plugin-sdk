import OnelastleafPluginProtocol

/// An environment, transport, protocol, host-capability, or action failure
/// surfaced by the SDK.
public enum PluginSDKError: Error, Sendable, CustomStringConvertible {
  /// The process environment is missing or contains an invalid runtime value.
  case environment(String)

  /// Plugin code supplied an invalid argument or used an SDK API in the wrong phase.
  case invalidArgument(String)

  /// The SDK could not establish or maintain its connection to oll.
  case transport(String)

  /// oll sent a message that violates the negotiated plugin protocol.
  case protocolViolation(String)

  /// A nested host call would exceed the call-depth limit negotiated with oll.
  ///
  /// - Parameter maximum: The maximum depth advertised for the active session.
  case callDepthExceeded(maximum: UInt32)

  /// The plugin did not finish graceful shutdown before the host's deadline.
  case shutdownDeadlineExceeded

  /// oll rejected a host-capability request with a structured protocol error.
  case host(Oll_Protocol_ProtocolError)

  /// An action failed with a description suitable for the job's terminal update.
  case action(String)

  /// A human-readable description prefixed with the failure category.
  public var description: String {
    switch self {
    case .environment(let message): "environment: \(message)"
    case .invalidArgument(let message): "invalid argument: \(message)"
    case .transport(let message): "transport: \(message)"
    case .protocolViolation(let message): "protocol: \(message)"
    case .callDepthExceeded(let maximum):
      "host call exceeds the negotiated maximum call depth of \(maximum)"
    case .shutdownDeadlineExceeded: "shutdown grace-period deadline exceeded"
    case .host(let error): "host: \(error.message)"
    case .action(let message): "action: \(message)"
    }
  }

  func protocolError() -> Oll_Protocol_ProtocolError {
    var error = Oll_Protocol_ProtocolError()
    switch self {
    case .invalidArgument:
      error.code = .invalidArgument
    case .host(let hostError):
      return hostError
    case .environment, .transport:
      error.code = .unavailable
    case .protocolViolation:
      error.code = .failedPrecondition
    case .callDepthExceeded:
      error.code = .callDepthExceeded
    case .shutdownDeadlineExceeded:
      error.code = .deadlineExceeded
    case .action:
      error.code = .internal
    }
    error.message = description
    return error
  }

  var terminatesSession: Bool {
    switch self {
    case .environment, .transport, .protocolViolation, .shutdownDeadlineExceeded:
      return true
    case .invalidArgument, .callDepthExceeded, .host, .action:
      return false
    }
  }
}
