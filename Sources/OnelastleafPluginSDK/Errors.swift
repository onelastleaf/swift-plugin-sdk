public enum PluginSDKError: Error, Sendable, CustomStringConvertible {
  case environment(String)
  case invalidArgument(String)
  case transport(String)
  case protocolViolation(String)
  case host(Oll_Protocol_ProtocolError)
  case action(String)

  public var description: String {
    switch self {
    case .environment(let message): "environment: \(message)"
    case .invalidArgument(let message): "invalid argument: \(message)"
    case .transport(let message): "transport: \(message)"
    case .protocolViolation(let message): "protocol: \(message)"
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
    case .action:
      error.code = .internal
    }
    error.message = description
    return error
  }
}
