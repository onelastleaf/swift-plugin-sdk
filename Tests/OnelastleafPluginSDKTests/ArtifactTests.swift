import Foundation
import Testing

@testable import OnelastleafPluginSDK

private let emptySHA256 = Data([
  0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
  0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
  0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
  0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
])

private struct ArtifactHarness {
  let queue = EnvelopeQueue()
  let pending = PendingResponses()
  let scope = JobScope()
  let context: ActionContext

  init(maximumChunkBytes: UInt64 = 1_024) throws {
    let sender = EnvelopeSender(queue: queue)
    try sender.configure(sessionID: testSessionID, instanceID: testInstanceID)
    context = ActionContext(
      jobID: "00000000-0000-4000-8000-000000000041",
      deadline: nil,
      cancellation: CancellationToken(),
      trace: makeTrace("00000000-0000-4000-8000-000000000040"),
      host: HostClient(
        sender: sender,
        pending: pending,
        sessionID: testSessionID,
        maximumArtifactChunkBytes: maximumChunkBytes,
        maximumCallDepth: 8
      ),
      parentCallID: 42,
      scope: scope
    )
  }
}

@Test func emptyArtifactUsesStartAndCompleteWithoutAChunk() async throws {
  let harness = try ArtifactHarness()
  let descriptor = makeDescriptor(size: 0, sha256: emptySHA256)

  let transfer = Task {
    try await harness.context.storeArtifact(descriptor: descriptor, chunks: [])
  }
  var outbound = harness.queue.stream.makeAsyncIterator()
  let start = try await nextEnvelope(&outbound)
  #expect(start.trace == harness.context.trace)
  #expect(start.artifactStart.chunkCount == 0)
  var accepted = Oll_Protocol_ArtifactTransferAccepted()
  accepted.artifactID = descriptor.artifactID
  try harness.pending.resolve(
    replyTo: start.messageID,
    trace: harness.context.trace,
    payload: .artifactAccepted(accepted)
  )

  let complete = try await nextEnvelope(&outbound)
  guard case .artifactComplete? = complete.payload else {
    Issue.record("empty artifact emitted a data chunk")
    return
  }
  var stored = Oll_Protocol_ArtifactStored()
  stored.artifactID = descriptor.artifactID
  try harness.pending.resolve(
    replyTo: complete.messageID,
    trace: harness.context.trace,
    payload: .artifactStored(stored)
  )
  #expect(try await transfer.value == stored)
  try harness.scope.validateResultArtifacts([descriptor])
}

@Test func artifactResultMustExactlyMatchAStoredDescriptor() throws {
  let scope = JobScope()
  let descriptor = makeDescriptor(size: 0, sha256: emptySHA256)
  try scope.recordStoredArtifact(descriptor)
  try scope.validateResultArtifacts([descriptor])
  #expect(throws: PluginSDKError.self) {
    try scope.validateResultArtifacts([descriptor, descriptor])
  }

  var changed = descriptor
  changed.fileName = "different.bin"
  #expect(throws: PluginSDKError.self) {
    try scope.validateResultArtifacts([changed])
  }
}

@Test func artifactRejectionRemainsAJobScopedHostError() async throws {
  let harness = try ArtifactHarness()
  let descriptor = makeDescriptor(size: 0, sha256: emptySHA256)

  let transfer = Task {
    try await harness.context.storeArtifact(descriptor: descriptor, chunks: [])
  }
  var outbound = harness.queue.stream.makeAsyncIterator()
  let start = try await nextEnvelope(&outbound)
  var rejected = Oll_Protocol_ProtocolError()
  rejected.code = .alreadyExists
  rejected.message = "artifact ID already exists"
  try harness.pending.resolve(
    replyTo: start.messageID,
    trace: start.trace,
    payload: .protocolError(rejected)
  )

  do {
    _ = try await transfer.value
    Issue.record("host artifact rejection unexpectedly succeeded")
  } catch let error as PluginSDKError {
    guard case .host(let response) = error else {
      Issue.record("artifact rejection was promoted to a session-fatal error")
      return
    }
    #expect(response.code == .alreadyExists)
  }
}

@Test func inMemoryArtifactIsVerifiedBeforeStartingAHostTransfer() async throws {
  let harness = try ArtifactHarness()
  let descriptor = makeDescriptor(size: 1, sha256: emptySHA256)

  do {
    _ = try await harness.context.storeArtifact(
      descriptor: descriptor,
      chunks: [Data([0])]
    )
    Issue.record("artifact with a mismatched digest unexpectedly succeeded")
  } catch let error as PluginSDKError {
    guard case .invalidArgument = error else {
      Issue.record("invalid in-memory artifact produced the wrong error")
      return
    }
  }

  harness.queue.finish()
  var outbound = harness.queue.stream.makeAsyncIterator()
  #expect(await outbound.next() == nil)
}

@Test func streamingArtifactRejectsAnImpossiblePartialChunkPlan() async throws {
  let harness = try ArtifactHarness()
  let descriptor = makeDescriptor(size: 1_026, sha256: Data(repeating: 0, count: 32))
  let chunks = AsyncStream<Data> { continuation in
    continuation.yield(Data([0]))
    continuation.yield(Data(repeating: 0, count: 1_025))
    continuation.finish()
  }
  let transfer = Task {
    try await harness.context.storeArtifact(
      descriptor: descriptor,
      chunkCount: 2,
      chunks: chunks
    )
  }
  var outbound = harness.queue.stream.makeAsyncIterator()
  let start = try await nextEnvelope(&outbound)
  var accepted = Oll_Protocol_ArtifactTransferAccepted()
  accepted.artifactID = descriptor.artifactID
  try harness.pending.resolve(
    replyTo: start.messageID,
    trace: start.trace,
    payload: .artifactAccepted(accepted)
  )

  do {
    _ = try await transfer.value
    Issue.record("impossible partial chunk plan unexpectedly succeeded")
  } catch let error as PluginSDKError {
    guard case .invalidArgument = error else {
      Issue.record("impossible chunk plan produced the wrong error")
      return
    }
  }
  harness.queue.finish()
  #expect(await outbound.next() == nil)
}
