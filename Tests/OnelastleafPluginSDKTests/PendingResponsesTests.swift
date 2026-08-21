import Testing

@testable import OnelastleafPluginSDK

@Test func pendingResponsesRequireTheCompleteRequestTrace() throws {
  let pending = PendingResponses()
  var expected = makeTrace()
  expected.parentCallID = 7
  expected.callDepth = 2
  expected.causalDepth = 3
  expected.taskID = "task"
  expected.taskGroupID = "group"
  _ = try pending.add(messageID: 1, trace: expected)

  var changed = expected
  changed.causalDepth += 1
  #expect(throws: PluginSDKError.self) {
    try pending.resolve(
      replyTo: 1,
      trace: changed,
      payload: .ready(Oll_Protocol_SessionReady())
    )
  }
}

@Test func cancelledPendingRequestConsumesItsLateResponse() async throws {
  let pending = PendingResponses()
  let trace = makeTrace()
  let request = try pending.add(messageID: 9, trace: trace)
  pending.cancel(messageID: 9)

  do {
    _ = try await request.value()
    Issue.record("cancelled request unexpectedly produced a value")
  } catch is CancellationError {
    // Expected.
  }
  try pending.resolve(
    replyTo: 9,
    trace: trace,
    payload: .ready(Oll_Protocol_SessionReady())
  )
}

@Test func sessionEndFailsEveryPendingRequest() async throws {
  let pending = PendingResponses()
  let first = try pending.add(messageID: 1, trace: makeTrace())
  let second = try pending.add(messageID: 2, trace: makeTrace())
  let failure = PluginSDKError.transport("closed")
  pending.failAll(failure)

  for request in [first, second] {
    do {
      _ = try await request.value()
      Issue.record("pending request survived session close")
    } catch let error as PluginSDKError {
      #expect(error.description == failure.description)
    }
  }
}

@Test func pendingHostRequestsAreBounded() throws {
  let pending = PendingResponses()
  for messageID in 1...maximumPendingHostRequests {
    _ = try pending.add(messageID: UInt64(messageID), trace: makeTrace())
  }

  do {
    _ = try pending.add(
      messageID: UInt64(maximumPendingHostRequests + 1),
      trace: makeTrace()
    )
    Issue.record("pending request limit was not enforced")
  } catch let error as PluginSDKError {
    guard case .invalidArgument = error else {
      Issue.record("pending request limit produced a session-fatal error")
      return
    }
  }
  pending.failAll(CancellationError())
}
