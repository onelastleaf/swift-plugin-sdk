import Foundation

private final class DeliveryWaiter: @unchecked Sendable {
  let stream: AsyncThrowingStream<Void, Error>
  private let continuation: AsyncThrowingStream<Void, Error>.Continuation

  init() {
    var captured: AsyncThrowingStream<Void, Error>.Continuation?
    stream = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) {
      captured = $0
    }
    continuation = captured!
  }

  func succeed() {
    continuation.yield(())
    continuation.finish()
  }

  func fail(_ error: Error) {
    continuation.finish(throwing: error)
  }

  func value() async throws {
    var iterator = stream.makeAsyncIterator()
    guard try await iterator.next() != nil else {
      throw PluginSDKError.transport("plugin output closed before delivery")
    }
  }
}

struct OutboundEnvelope: Sendable {
  let envelope: Oll_Protocol_PluginEnvelope
  fileprivate let delivery: DeliveryWaiter
}

final class EnvelopeQueue: @unchecked Sendable {
  let stream: AsyncStream<OutboundEnvelope>
  private let continuation: AsyncStream<OutboundEnvelope>.Continuation

  init(capacity: Int = 256) {
    var captured: AsyncStream<OutboundEnvelope>.Continuation?
    stream = AsyncStream(bufferingPolicy: .bufferingOldest(capacity)) {
      captured = $0
    }
    continuation = captured!
  }

  fileprivate func send(_ envelope: Oll_Protocol_PluginEnvelope) throws -> DeliveryWaiter {
    let delivery = DeliveryWaiter()
    switch continuation.yield(OutboundEnvelope(envelope: envelope, delivery: delivery)) {
    case .enqueued:
      return delivery
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

  func delivered(_ outbound: OutboundEnvelope) {
    outbound.delivery.succeed()
  }

  func failed(_ outbound: OutboundEnvelope, error: Error) {
    outbound.delivery.fail(error)
  }
}

actor EnvelopeSender {
  private let queue: EnvelopeQueue
  private var sessionID = ""
  private var instanceID = ""
  private var nextMessageID: UInt64 = 1

  init(queue: EnvelopeQueue) {
    self.queue = queue
  }

  func configure(sessionID: String, instanceID: String) {
    self.sessionID = sessionID
    self.instanceID = instanceID
  }

  private func reserveMessageID() throws -> UInt64 {
    guard nextMessageID < UInt64.max else {
      throw PluginSDKError.protocolViolation("plugin exhausted message IDs")
    }
    let value = nextMessageID
    nextMessageID += 1
    return value
  }

  @discardableResult
  func send(
    replyTo: UInt64? = nil,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
  ) async throws -> UInt64 {
    let messageID = try reserveMessageID()
    let delivery = try enqueue(
      messageID: messageID, replyTo: replyTo, trace: trace, payload: payload)
    try await delivery.value()
    return messageID
  }

  func sendRequest(
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload,
    pending: PendingResponses
  ) async throws -> ResponseWaiter {
    let messageID = try reserveMessageID()
    let waiter = try pending.add(
      messageID: messageID,
      correlationID: trace.correlationID
    )
    do {
      let delivery = try enqueue(
        messageID: messageID, replyTo: nil, trace: trace, payload: payload)
      try await delivery.value()
      return waiter
    } catch {
      pending.fail(messageID: messageID, error: error)
      throw error
    }
  }

  private func enqueue(
    messageID: UInt64,
    replyTo: UInt64?,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
  ) throws -> DeliveryWaiter {
    var envelope = Oll_Protocol_PluginEnvelope()
    envelope.messageID = messageID
    if let replyTo { envelope.replyTo = replyTo }
    envelope.sessionID = sessionID
    envelope.pluginInstanceID = instanceID
    envelope.trace = trace
    envelope.payload = payload
    return try queue.send(envelope)
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
      let host = components.host,
      let port = components.port,
      (1...65535).contains(port),
      isLoopbackLiteral(host)
    else {
      throw PluginSDKError.environment(
        "OLL_PLUGIN_ENDPOINT must be an explicit plaintext loopback HTTP endpoint"
      )
    }
    return Self(host: host, port: port)
  }
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
