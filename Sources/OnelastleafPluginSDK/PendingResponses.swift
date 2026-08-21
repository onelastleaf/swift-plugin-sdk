import OnelastleafPluginProtocol
import Synchronization

let maximumPendingHostRequests = 256

struct PendingRequest: Sendable {
  let messageID: UInt64
  fileprivate let response: AsyncResult<Oll_Protocol_PluginEnvelope.OneOf_Payload>

  func value() async throws -> Oll_Protocol_PluginEnvelope.OneOf_Payload {
    try await response.value()
  }
}

/// Correlates host replies without blocking the stream reader. A cancelled
/// request remains as a tombstone until its late response arrives, so a valid
/// late reply is consumed instead of being misclassified as an unknown reply.
final class PendingResponses: Sendable {
  private struct Entry: Sendable {
    let trace: Oll_Protocol_TraceContext
    let response: AsyncResult<Oll_Protocol_PluginEnvelope.OneOf_Payload>
    var cancelled = false
  }

  private let entries = Mutex<[UInt64: Entry]>([:])

  func add(messageID: UInt64, trace: Oll_Protocol_TraceContext) throws -> PendingRequest {
    let response = AsyncResult<Oll_Protocol_PluginEnvelope.OneOf_Payload>()
    try entries.withLock { entries in
      guard entries[messageID] == nil else {
        throw PluginSDKError.protocolViolation("duplicate pending message ID")
      }
      guard entries.count < maximumPendingHostRequests else {
        throw PluginSDKError.invalidArgument(
          "too many concurrent host requests"
        )
      }
      entries[messageID] = Entry(trace: trace, response: response)
    }
    return PendingRequest(messageID: messageID, response: response)
  }

  @discardableResult
  func resolve(
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
  ) throws -> Bool {
    guard let entry = entries.withLock({ $0.removeValue(forKey: replyTo) }) else { return false }
    guard entry.trace == trace else {
      let error = PluginSDKError.protocolViolation("response trace context differs")
      entry.response.fail(error)
      throw error
    }
    if !entry.cancelled {
      entry.response.succeed(payload)
    }
    return true
  }

  func cancel(messageID: UInt64) {
    let response = entries.withLock {
      entries -> AsyncResult<
        Oll_Protocol_PluginEnvelope.OneOf_Payload
      >? in
      guard var entry = entries[messageID], !entry.cancelled else { return nil }
      entry.cancelled = true
      entries[messageID] = entry
      return entry.response
    }
    response?.fail(CancellationError())
  }

  func discard(messageID: UInt64, error: any Error) {
    let entry = entries.withLock { $0.removeValue(forKey: messageID) }
    entry?.response.fail(error)
  }

  func failAll(_ error: any Error) {
    let waiting = entries.withLock { entries -> [Entry] in
      defer { entries.removeAll(keepingCapacity: false) }
      return Array(entries.values)
    }
    for entry in waiting where !entry.cancelled {
      entry.response.fail(error)
    }
  }
}
