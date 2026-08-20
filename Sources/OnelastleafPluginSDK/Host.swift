import Crypto
import Foundation
import SwiftProtobuf

final class ResponseWaiter: @unchecked Sendable {
  let stream: AsyncThrowingStream<Oll_Protocol_PluginEnvelope.OneOf_Payload, Error>
  private let continuation:
    AsyncThrowingStream<Oll_Protocol_PluginEnvelope.OneOf_Payload, Error>.Continuation

  init() {
    var captured:
      AsyncThrowingStream<Oll_Protocol_PluginEnvelope.OneOf_Payload, Error>.Continuation?
    stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(1)) {
      captured = $0
    }
    continuation = captured!
  }

  func succeed(_ payload: Oll_Protocol_PluginEnvelope.OneOf_Payload) {
    continuation.yield(payload)
    continuation.finish()
  }

  func fail(_ error: Error) {
    continuation.finish(throwing: error)
  }

  func value() async throws -> Oll_Protocol_PluginEnvelope.OneOf_Payload {
    var iterator = stream.makeAsyncIterator()
    guard let value = try await iterator.next() else {
      throw PluginSDKError.transport("plugin session ended before host response")
    }
    return value
  }
}

final class PendingResponses: @unchecked Sendable {
  private struct Entry: Sendable {
    let trace: Oll_Protocol_TraceContext
    let waiter: ResponseWaiter
  }

  private var entries: [UInt64: Entry] = [:]
  private let lock = NSLock()

  func add(messageID: UInt64, trace: Oll_Protocol_TraceContext) throws -> ResponseWaiter {
    lock.lock()
    defer { lock.unlock() }
    guard entries[messageID] == nil else {
      throw PluginSDKError.protocolViolation("duplicate pending message ID")
    }
    let waiter = ResponseWaiter()
    entries[messageID] = Entry(trace: trace, waiter: waiter)
    return waiter
  }

  func resolve(
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext,
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
  ) throws {
    lock.lock()
    let entry = entries.removeValue(forKey: replyTo)
    lock.unlock()
    guard let entry else {
      throw PluginSDKError.protocolViolation(
        "response names no pending plugin request"
      )
    }
    guard entry.trace == trace else {
      entry.waiter.fail(
        PluginSDKError.protocolViolation("response trace context differs")
      )
      throw PluginSDKError.protocolViolation("response trace context differs")
    }
    entry.waiter.succeed(payload)
  }

  func fail(messageID: UInt64, error: Error) {
    lock.lock()
    let entry = entries.removeValue(forKey: messageID)
    lock.unlock()
    entry?.waiter.fail(error)
  }

  func failAll(_ error: Error) {
    lock.lock()
    let waiting = entries.values
    entries.removeAll()
    lock.unlock()
    for entry in waiting { entry.waiter.fail(error) }
  }
}

public struct HostClient: Sendable {
  let sender: EnvelopeSender
  let pending: PendingResponses
  public let maximumArtifactChunkBytes: UInt64
  let maximumCallDepth: UInt32

  public func call(
    _ call: Oll_Protocol_HostCallRequest.OneOf_Call,
    trace: Oll_Protocol_TraceContext
  ) async throws -> Oll_Protocol_HostCallResponse {
    var request = Oll_Protocol_HostCallRequest()
    request.call = call
    switch try await self.request(payload: .hostCall(request), trace: trace) {
    case .hostResult(let response):
      if case .error(let error)? = response.result {
        throw PluginSDKError.host(error)
      }
      return response
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    default:
      throw PluginSDKError.protocolViolation(
        "host call received another response kind"
      )
    }
  }

  func request(
    payload: Oll_Protocol_PluginEnvelope.OneOf_Payload,
    trace: Oll_Protocol_TraceContext
  ) async throws -> Oll_Protocol_PluginEnvelope.OneOf_Payload {
    let waiter = try await sender.sendRequest(
      trace: trace,
      payload: payload,
      pending: pending
    )
    return try await waiter.value()
  }
}

extension ActionContext {
  public func hostCall(
    _ call: Oll_Protocol_HostCallRequest.OneOf_Call
  ) async throws -> Oll_Protocol_HostCallResponse {
    try await host.call(call, trace: nestedTrace())
  }

  public func getConfig(
    _ path: Oll_Protocol_ConfigPath = Oll_Protocol_ConfigPath()
  ) async throws -> Oll_Protocol_GetConfigResponse {
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

  public func invokeConfigFunction(
    _ function: Oll_Protocol_ConfigFunctionRef,
    arguments: [Oll_Protocol_ConfigValue] = []
  ) async throws -> Oll_Protocol_InvokeConfigFunctionResponse {
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

  public func log(
    level: Oll_Protocol_LogLevel,
    target: String,
    message: String,
    fields: [String: Oll_Protocol_ConfigValue] = [:]
  ) async throws {
    var timestamp = Google_Protobuf_Timestamp()
    let now = Date().timeIntervalSince1970
    timestamp.seconds = Int64(now.rounded(.down))
    timestamp.nanos = Int32((now - now.rounded(.down)) * 1_000_000_000)
    var record = Oll_Protocol_LogRecord()
    record.timestamp = timestamp
    record.level = level
    record.target = target
    record.message = message
    record.fields = fields
    _ = try await host.sender.send(trace: trace, payload: .log(record))
  }

  public func storeArtifact(
    descriptor: Oll_Protocol_ArtifactDescriptor,
    chunks: [Data]
  ) async throws -> Oll_Protocol_ArtifactStored {
    guard descriptor.hasArtifactID,
      canonicalUUIDv4(descriptor.artifactID.value),
      !descriptor.fileName.isEmpty,
      !descriptor.mediaType.isEmpty,
      descriptor.sha256.count == 32
    else {
      throw PluginSDKError.invalidArgument("artifact descriptor is invalid")
    }
    guard !chunks.isEmpty, chunks.allSatisfy({ !$0.isEmpty }) else {
      throw PluginSDKError.invalidArgument("artifact chunks must be nonempty")
    }
    guard chunks.allSatisfy({ UInt64($0.count) <= host.maximumArtifactChunkBytes }) else {
      throw PluginSDKError.invalidArgument(
        "artifact chunk exceeds the negotiated limit"
      )
    }
    guard chunks.count <= Int(UInt32.max) else {
      throw PluginSDKError.invalidArgument("artifact has too many chunks")
    }
    var size: UInt64 = 0
    var sha256 = SHA256()
    for chunk in chunks {
      let (next, overflow) = size.addingReportingOverflow(UInt64(chunk.count))
      guard !overflow else {
        throw PluginSDKError.invalidArgument("artifact size overflowed")
      }
      size = next
      sha256.update(data: chunk)
    }
    guard descriptor.sizeBytes == size,
      descriptor.sha256 == Data(sha256.finalize())
    else {
      throw PluginSDKError.invalidArgument(
        "artifact size or SHA-256 does not match its bytes"
      )
    }
    let transferTrace = trace

    var start = Oll_Protocol_ArtifactTransferStart()
    var job = Oll_Protocol_PluginJobId()
    job.value = jobID
    start.jobID = job
    start.artifact = descriptor
    start.chunkCount = UInt32(chunks.count)
    switch try await host.request(
      payload: .artifactStart(start),
      trace: transferTrace
    ) {
    case .artifactAccepted(let accepted)
    where accepted.hasArtifactID
      && accepted.artifactID.value == descriptor.artifactID.value:
      break
    default:
      throw PluginSDKError.protocolViolation(
        "host did not accept the artifact transfer"
      )
    }

    for (index, data) in chunks.enumerated() {
      var chunk = Oll_Protocol_ArtifactTransferChunk()
      chunk.artifactID = descriptor.artifactID
      chunk.chunkIndex = UInt32(index)
      chunk.data = data
      _ = try await host.sender.send(
        trace: transferTrace,
        payload: .artifactChunk(chunk)
      )
    }

    var complete = Oll_Protocol_ArtifactTransferComplete()
    complete.artifactID = descriptor.artifactID
    switch try await host.request(
      payload: .artifactComplete(complete),
      trace: transferTrace
    ) {
    case .artifactStored(let stored)
    where stored.hasArtifactID
      && stored.artifactID.value == descriptor.artifactID.value:
      return stored
    default:
      throw PluginSDKError.protocolViolation(
        "host did not confirm artifact storage"
      )
    }
  }
}

private func canonicalUUIDv4(_ value: String) -> Bool {
  value.range(
    of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
    options: .regularExpression
  ) != nil
}
