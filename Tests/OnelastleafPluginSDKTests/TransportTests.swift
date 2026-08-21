import Testing

@testable import OnelastleafPluginSDK

@Test func concurrentSenderAdmissionPreservesMessageIDOrder() async throws {
  let messageCount = 512
  let queue = EnvelopeQueue(capacity: messageCount)
  let sender = EnvelopeSender(queue: queue)
  try sender.configure(sessionID: testSessionID, instanceID: testInstanceID)
  let trace = makeTrace()

  try await withThrowingTaskGroup(of: Void.self) { group in
    for nonce in 0..<messageCount {
      group.addTask {
        var heartbeat = Oll_Protocol_Heartbeat()
        heartbeat.nonce = UInt64(nonce)
        _ = try sender.send(trace: trace, payload: .heartbeat(heartbeat))
      }
    }
    try await group.waitForAll()
  }
  queue.finish()

  var expectedMessageID: UInt64 = 1
  for await envelope in queue.stream {
    #expect(envelope.messageID == expectedMessageID)
    expectedMessageID += 1
  }
  #expect(expectedMessageID == UInt64(messageCount) + 1)
}

@Test func failedQueueAdmissionDoesNotLeakAPendingRequest() throws {
  let queue = EnvelopeQueue(capacity: 1)
  let sender = EnvelopeSender(queue: queue)
  let pending = PendingResponses()
  let trace = makeTrace()
  try sender.configure(sessionID: testSessionID, instanceID: testInstanceID)
  _ = try sender.send(
    trace: trace,
    payload: .heartbeat(Oll_Protocol_Heartbeat())
  )

  #expect(throws: PluginSDKError.self) {
    _ = try sender.sendRequest(
      trace: trace,
      payload: .hostCall(Oll_Protocol_HostCallRequest()),
      pending: pending
    )
  }
  #expect(
    try !pending.resolve(
      replyTo: 2,
      trace: trace,
      payload: .protocolError(Oll_Protocol_ProtocolError())
    )
  )
}
