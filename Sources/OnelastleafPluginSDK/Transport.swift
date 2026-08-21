import Foundation
import OnelastleafPluginProtocol
import Synchronization

private let outboundEnvelopeCapacity = 256

/// A bounded multi-producer, single-consumer queue for the gRPC request stream.
/// `AsyncStream.Continuation` is thread-safe; `EnvelopeSender` supplies ordering.
final class EnvelopeQueue: Sendable {
  let stream: AsyncStream<Oll_Protocol_PluginEnvelope>
  private let continuation: AsyncStream<Oll_Protocol_PluginEnvelope>.Continuation

  init(capacity: Int = outboundEnvelopeCapacity) {
    (stream, continuation) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingOldest(capacity)
    )
  }

  func send(_ envelope: Oll_Protocol_PluginEnvelope) throws {
    switch continuation.yield(envelope) {
    case .enqueued:
      return
    case .dropped:
      throw PluginSDKError.transport("plugin output queue is full")
    case .terminated:
      throw PluginSDKError.transport("plugin output stream is closed")
    @unknown default:
      throw PluginSDKError.transport("plugin output stream rejected a message")
    }
  }

  func finish() {
    continuation.finish()
  }
}

/// Owns the plugin's message-ID sequence and is the only envelope construction
/// path. Envelope construction and queue admission share one short synchronous
/// critical section, so protocol ordering never crosses an actor reentrancy
/// point. The gRPC writer reports later transport failures through the runtime.
final class EnvelopeSender: Sendable {
  private struct State: Sendable {
    var sessionID: String?
    var instanceID: String?
    var nextMessageID: UInt64? = 1
  }

  private let queue: EnvelopeQueue
  private let state = Mutex(State())

  init(queue: EnvelopeQueue) {
    self.queue = queue
  }

  func configure(sessionID: String, instanceID: String) throws {
    guard !sessionID.isEmpty, !instanceID.isEmpty else {
      throw PluginSDKError.protocolViolation("plugin sender identity must not be empty")
    }
    try state.withLock { state in
      guard state.sessionID == nil, state.instanceID == nil else {
        throw PluginSDKError.protocolViolation("plugin sender was configured more than once")
      }
      state.sessionID = sessionID
      state.instanceID = instanceID
    }
  }

  @discardableResult
  func send(
    replyTo: UInt64? = nil,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
  ) throws -> UInt64 {
    try state.withLock { state in
      let messageID = try availableMessageID(state: state)
      try enqueue(
        messageID: messageID,
        replyTo: replyTo,
        trace: trace,
        payload: payload,
        state: state
      )
      advanceMessageID(after: messageID, state: &state)
      return messageID
    }
  }

  func sendRequest(
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload,
    pending: PendingResponses
  ) throws -> PendingRequest {
    try state.withLock { state in
      let messageID = try availableMessageID(state: state)
      let request = try pending.add(messageID: messageID, trace: trace)
      do {
        try enqueue(
          messageID: messageID,
          replyTo: nil,
          trace: trace,
          payload: payload,
          state: state
        )
        advanceMessageID(after: messageID, state: &state)
        return request
      } catch {
        pending.discard(messageID: messageID, error: error)
        throw error
      }
    }
  }

  /// Whether this sender has admitted the named envelope to its ordered queue.
  /// oll may directly reject fire-and-forget output even though it has no
  /// success response slot.
  func hasSent(messageID: UInt64) -> Bool {
    guard messageID != 0 else { return false }
    return state.withLock { state in
      state.nextMessageID.map { messageID < $0 } ?? true
    }
  }

  private func availableMessageID(state: State) throws -> UInt64 {
    guard let messageID = state.nextMessageID else {
      throw PluginSDKError.protocolViolation("plugin exhausted message IDs")
    }
    return messageID
  }

  private func advanceMessageID(after messageID: UInt64, state: inout State) {
    state.nextMessageID = messageID == .max ? nil : messageID + 1
  }

  private func enqueue(
    messageID: UInt64,
    replyTo: UInt64?,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload,
    state: State
  ) throws {
    guard let sessionID = state.sessionID, let instanceID = state.instanceID else {
      throw PluginSDKError.protocolViolation("plugin sender has no session identity")
    }
    var envelope = Oll_Protocol_PluginEnvelope()
    envelope.messageID = messageID
    if let replyTo { envelope.replyTo = replyTo }
    envelope.sessionID = sessionID
    envelope.pluginInstanceID = instanceID
    envelope.trace = trace
    envelope.payload = payload
    try queue.send(envelope)
  }
}

struct PluginEndpoint: Sendable {
  let host: String
  let port: Int

  static func parse(_ value: String) throws -> Self {
    guard let components = URLComponents(string: value),
      components.scheme == "http",
      components.user == nil,
      components.password == nil,
      components.path.isEmpty,
      components.query == nil,
      components.fragment == nil,
      let parsedHost = components.host,
      let port = components.port,
      (1...65_535).contains(port),
      isLoopbackLiteral(normalizedURLHost(parsedHost))
    else {
      throw PluginSDKError.environment(
        "OLL_PLUGIN_ENDPOINT must be an explicit plaintext loopback HTTP endpoint"
      )
    }
    return Self(host: normalizedURLHost(parsedHost), port: port)
  }
}

/// Foundation returns bracketed IPv6 hosts on Linux and unbracketed hosts on
/// Darwin. Normalize that platform difference before enforcing loopback.
private func normalizedURLHost(_ host: String) -> String {
  guard host.first == "[", host.last == "]" else { return host }
  return String(host.dropFirst().dropLast())
}

private func isLoopbackLiteral(_ host: String) -> Bool {
  if host == "::1" { return true }
  let parts = host.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4,
    parts[0] == "127",
    parts.allSatisfy({ UInt8($0) != nil })
  else { return false }
  return true
}
