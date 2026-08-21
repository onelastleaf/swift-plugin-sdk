import Foundation
import SwiftProtobuf
import Testing

@testable import OnelastleafPluginSDK

private let firstJobID = "00000000-0000-4000-8000-000000000011"
private let firstJobCorrelationID = "00000000-0000-4000-8000-000000000010"

@Test func cancellationDoesNotBlockHeartbeatDispatch() async throws {
  let started = AsyncResult<Void>()
  let release = AsyncResult<Void>()
  let action = RegisteredAction(description: "wait") { context, _ in
    started.succeed(())
    try await release.valueIgnoringCancellation()
    try context.cancellation.checkCancellation()
    return .string("unexpected")
  }
  let harness = SessionHarness(actions: ["wait": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)

  let jobTrace = makeTrace(firstJobCorrelationID)
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: jobTrace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "wait"))
    )
  )
  let accepted = try await nextEnvelope(&outbound)
  #expect(accepted.replyTo == 3)
  guard case .jobAccepted? = accepted.payload else {
    Issue.record("job was not accepted")
    return
  }
  _ = try await withTimeout { try await started.value() }

  try await withTimeout {
    try await harness.session.handle(
      makeHostEnvelope(
        messageID: 4,
        trace: jobTrace,
        payload: .cancelJob(makeCancelJob(firstJobID))
      )
    )
  }
  var heartbeat = Oll_Protocol_Heartbeat()
  heartbeat.nonce = 42
  let heartbeatTrace = makeTrace("00000000-0000-4000-8000-000000000012")
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 5,
      trace: heartbeatTrace,
      payload: .heartbeat(heartbeat)
    )
  )

  let response = try await nextEnvelope(&outbound)
  #expect(response.replyTo == 5)
  #expect(response.trace == heartbeatTrace)
  guard case .heartbeat(let echoed)? = response.payload else {
    Issue.record("heartbeat was blocked by job cancellation")
    return
  }
  #expect(echoed.nonce == 42)

  release.succeed(())
  let acknowledged = try await nextEnvelope(&outbound)
  #expect(acknowledged.replyTo == 4)
  #expect(acknowledged.trace == jobTrace)
  guard case .cancelJobAcknowledged(let value)? = acknowledged.payload else {
    Issue.record("job cancellation was not acknowledged")
    return
  }
  #expect(value.jobID.value == firstJobID)
  await harness.session.close()
}

@Test func unknownAndCompletedJobCancellationIsIdempotent() async throws {
  let action = RegisteredAction(description: "echo") { _, _ in .string("done") }
  let harness = SessionHarness(actions: ["echo": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "echo"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  let terminal = try await nextEnvelope(&outbound)
  guard case .jobUpdate(let update)? = terminal.payload else {
    Issue.record("completed action omitted its terminal update")
    return
  }
  #expect(update.state == .succeeded)

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 4,
      trace: trace,
      payload: .cancelJob(makeCancelJob(firstJobID))
    )
  )
  let late = try await nextEnvelope(&outbound)
  #expect(late.replyTo == 4)
  guard case .cancelJobAcknowledged? = late.payload else {
    Issue.record("late cancellation was not acknowledged")
    return
  }

  let unknownID = "00000000-0000-4000-8000-000000000099"
  let unknownTrace = makeTrace("00000000-0000-4000-8000-000000000098")
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 5,
      trace: unknownTrace,
      payload: .cancelJob(makeCancelJob(unknownID))
    )
  )
  let unknown = try await nextEnvelope(&outbound)
  #expect(unknown.replyTo == 5)
  #expect(unknown.cancelJobAcknowledged.jobID.value == unknownID)

  harness.queue.finish()
  let remaining = await outbound.next()
  #expect(remaining == nil)
  await harness.session.close()
}

@Test func heartbeatContinuesWhileAHostCallIsPending() async throws {
  let action = RegisteredAction(description: "host") { context, _ in
    let response = try await context.getConfig()
    return .string(response.value.stringValue)
  }
  let harness = SessionHarness(actions: ["host": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "host"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  let call = try await nextEnvelope(&outbound)
  guard case .hostCall? = call.payload else {
    Issue.record("action did not issue its host call")
    return
  }

  var heartbeat = Oll_Protocol_Heartbeat()
  heartbeat.nonce = 7
  let heartbeatTrace = makeTrace("00000000-0000-4000-8000-000000000012")
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 4,
      trace: heartbeatTrace,
      payload: .heartbeat(heartbeat)
    )
  )
  let echoed = try await nextEnvelope(&outbound)
  #expect(echoed.replyTo == 4)
  #expect(echoed.heartbeat.nonce == 7)

  var configured = Oll_Protocol_ConfigValue()
  configured.stringValue = "configured"
  var getConfig = Oll_Protocol_GetConfigResponse()
  getConfig.value = configured
  var hostResponse = Oll_Protocol_HostCallResponse()
  hostResponse.result = .getConfig(getConfig)
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 5,
      replyTo: call.messageID,
      trace: call.trace,
      payload: .hostResult(hostResponse)
    )
  )
  let terminal = try await nextEnvelope(&outbound)
  #expect(terminal.jobUpdate.result.stringValue == "configured")
  await harness.session.close()
}

@Test func malformedHostResponseInsideAnActionFailsTheSession() async throws {
  let action = RegisteredAction(description: "fatal") { _, _ in
    throw PluginSDKError.protocolViolation("malformed host response")
  }
  let harness = SessionHarness(actions: ["fatal": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "fatal"))
    )
  )
  _ = try await nextEnvelope(&outbound)

  let failure = try await withTimeout { try await harness.failures.wait() }
  guard case .protocolViolation = failure else {
    Issue.record("fatal SDK error was downgraded to a job failure")
    return
  }
  harness.queue.finish()
  let remaining = await outbound.next()
  #expect(remaining == nil)
  await harness.session.close()
}

@Test func sessionReadyRequiresTheCompleteHandshakeTrace() async throws {
  let harness = SessionHarness(actions: [:])
  var outbound = harness.queue.stream.makeAsyncIterator()
  let trace = makeTrace()
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 1,
      trace: trace,
      payload: .hostHello(makeHostHello())
    )
  )
  _ = try await nextEnvelope(&outbound)

  var changed = trace
  changed.taskID = "different"
  do {
    try await harness.session.handle(
      makeHostEnvelope(
        messageID: 2,
        trace: changed,
        payload: .ready(Oll_Protocol_SessionReady())
      )
    )
    Issue.record("SessionReady accepted a different trace")
  } catch let error as PluginSDKError {
    guard case .protocolViolation = error else {
      Issue.record("trace mismatch produced the wrong error")
      return
    }
  }
  await harness.session.close()
}

@Test func invalidActionResultBecomesATerminalJobFailure() async throws {
  let action = RegisteredAction(description: "invalid") { _, _ in
    var value = Oll_Protocol_ConfigValue()
    value.numberValue = .infinity
    return ActionResult(value: value)
  }
  let harness = SessionHarness(actions: ["invalid": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "invalid"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  let terminal = try await nextEnvelope(&outbound)
  #expect(terminal.jobUpdate.state == .failed)
  #expect(terminal.jobUpdate.error.code == .invalidArgument)
  await harness.session.close()
}

@Test func exhaustedCallDepthFailsOnlyTheJob() async throws {
  let action = RegisteredAction(description: "too deep") { context, _ in
    _ = try await context.getConfig()
    return .string("unexpected")
  }
  let harness = SessionHarness(actions: ["too-deep": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  var trace = makeTrace(firstJobCorrelationID)
  trace.callDepth = makeHostHello().maximumCallDepth

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "too-deep"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  let terminal = try await nextEnvelope(&outbound)
  #expect(terminal.jobUpdate.state == .failed)
  #expect(terminal.jobUpdate.error.code == .callDepthExceeded)

  var heartbeat = Oll_Protocol_Heartbeat()
  heartbeat.nonce = 19
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 4,
      trace: makeTrace("00000000-0000-4000-8000-000000000012"),
      payload: .heartbeat(heartbeat)
    )
  )
  #expect(try await nextEnvelope(&outbound).heartbeat.nonce == 19)
  await harness.session.close()
}

@Test func shutdownDeadlineFailsInsteadOfAcknowledgingLiveWork() async throws {
  let started = AsyncResult<Void>()
  let release = AsyncResult<Void>()
  let action = RegisteredAction(description: "stubborn") { _, _ in
    started.succeed(())
    try await release.valueIgnoringCancellation()
    return .string("done")
  }
  let harness = SessionHarness(actions: ["stubborn": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "stubborn"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  _ = try await withTimeout { try await started.value() }

  var shutdown = Oll_Protocol_ShutdownRequest()
  shutdown.reason = "test"
  shutdown.gracePeriodDeadline = Google_Protobuf_Timestamp(
    date: Date().addingTimeInterval(0.1)
  )
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 4,
      trace: makeTrace("00000000-0000-4000-8000-000000000020"),
      payload: .shutdown(shutdown)
    )
  )
  let failure = try await withTimeout { try await harness.failures.wait() }
  guard case .shutdownDeadlineExceeded = failure else {
    Issue.record("shutdown deadline produced the wrong failure")
    return
  }
  release.succeed(())
  await harness.session.close()
}

@Test func asynchronousArtifactChunkRejectionFailsOnlyItsJob() async throws {
  let digest = Data([
    0x6e, 0x34, 0x0b, 0x9c, 0xff, 0xb3, 0x7a, 0x98,
    0x9c, 0xa5, 0x44, 0xe6, 0xbb, 0x78, 0x0a, 0x2c,
    0x78, 0x90, 0x1d, 0x3f, 0xb3, 0x37, 0x38, 0x76,
    0x85, 0x11, 0xa3, 0x06, 0x17, 0xaf, 0xa0, 0x1d,
  ])
  let descriptor = makeDescriptor(size: 1, sha256: digest)
  let action = RegisteredAction(description: "artifact") { context, _ in
    _ = try await context.storeArtifact(
      descriptor: descriptor,
      chunks: [Data([0])]
    )
    return ActionResult(artifacts: [descriptor])
  }
  let harness = SessionHarness(actions: ["artifact": action])
  var outbound = harness.queue.stream.makeAsyncIterator()
  try await performHandshake(harness, outbound: &outbound)
  let trace = makeTrace(firstJobCorrelationID)

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 3,
      trace: trace,
      payload: .startJob(makeStartJob(jobID: firstJobID, action: "artifact"))
    )
  )
  _ = try await nextEnvelope(&outbound)
  let start = try await nextEnvelope(&outbound)
  var accepted = Oll_Protocol_ArtifactTransferAccepted()
  accepted.artifactID = descriptor.artifactID
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 4,
      replyTo: start.messageID,
      trace: trace,
      payload: .artifactAccepted(accepted)
    )
  )

  let chunk = try await nextEnvelope(&outbound)
  let complete = try await nextEnvelope(&outbound)
  var chunkError = Oll_Protocol_ProtocolError()
  chunkError.code = .unavailable
  chunkError.message = "artifact staging write failed"
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 5,
      replyTo: chunk.messageID,
      trace: trace,
      payload: .protocolError(chunkError)
    )
  )

  var completeError = Oll_Protocol_ProtocolError()
  completeError.code = .notFound
  completeError.message = "artifact transfer was aborted"
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 6,
      replyTo: complete.messageID,
      trace: trace,
      payload: .protocolError(completeError)
    )
  )
  let terminal = try await nextEnvelope(&outbound)
  #expect(terminal.jobUpdate.state == .failed)
  #expect(terminal.jobUpdate.error.code == .notFound)

  var heartbeat = Oll_Protocol_Heartbeat()
  heartbeat.nonce = 23
  let heartbeatTrace = makeTrace("00000000-0000-4000-8000-000000000022")
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 7,
      trace: heartbeatTrace,
      payload: .heartbeat(heartbeat)
    )
  )
  #expect(try await nextEnvelope(&outbound).heartbeat.nonce == 23)
  await harness.session.close()
}
