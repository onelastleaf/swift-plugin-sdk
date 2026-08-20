import Foundation
import Testing

@testable import OnelastleafPluginSDK

@Test func validatesPluginIdentityAndActions() throws {
  #expect(throws: PluginSDKError.self) {
    try Plugin(id: "not-valid", version: "0.1.0")
  }

  let plugin = try Plugin(id: "org.example.echo", version: "0.1.0")
  try plugin.action(name: "echo", description: "Echo arguments") { _, arguments in
    .string(arguments.joined(separator: " "))
  }
  #expect(throws: PluginSDKError.self) {
    try plugin.action(name: "echo", description: "Duplicate") { _, _ in .string("") }
  }
}

@Test func actionResultEncodesStrings() {
  let result = ActionResult.string("hello")
  #expect(result.value?.stringValue == "hello")
}

@Test func pendingResponsesRequireTheCompleteRequestTrace() throws {
  let pending = PendingResponses()
  var expected = Oll_Protocol_TraceContext()
  expected.correlationID = "00000000-0000-4000-8000-000000000001"
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

@Test func artifactTransferPreservesTheCompleteJobTrace() async throws {
  let queue = EnvelopeQueue()
  let sender = EnvelopeSender(queue: queue)
  let pending = PendingResponses()
  let host = HostClient(
    sender: sender,
    pending: pending,
    maximumArtifactChunkBytes: 64 * 1024,
    maximumCallDepth: 8
  )
  var trace = Oll_Protocol_TraceContext()
  trace.correlationID = "00000000-0000-4000-8000-000000000040"
  trace.parentCallID = 7
  trace.callDepth = 2
  trace.causalDepth = 3
  trace.taskID = "task"
  trace.taskGroupID = "group"
  let context = ActionContext(
    jobID: "00000000-0000-4000-8000-000000000041",
    deadline: nil,
    trace: trace,
    cancellation: CancellationToken(),
    host: host,
    parentCallID: 42
  )
  var artifactID = Oll_Protocol_PluginArtifactId()
  artifactID.value = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  var descriptor = Oll_Protocol_ArtifactDescriptor()
  descriptor.artifactID = artifactID
  descriptor.fileName = "conformance.txt"
  descriptor.mediaType = "text/plain"
  descriptor.sizeBytes = 16
  descriptor.sha256 = Data([
    0xa1, 0x1a, 0x40, 0x45, 0xc8, 0x9f, 0x72, 0x7f,
    0xad, 0xb9, 0xae, 0xdd, 0xb0, 0xf2, 0x96, 0x37,
    0xce, 0x5b, 0x50, 0x58, 0x46, 0xaf, 0xeb, 0xd8,
    0x2a, 0xe2, 0xc0, 0x1b, 0x67, 0x33, 0xa6, 0xb5,
  ])

  let transfer = Task {
    try await context.storeArtifact(
      descriptor: descriptor,
      chunks: [Data("artifact ".utf8), Data("payload".utf8)]
    )
  }
  var outbound = queue.stream.makeAsyncIterator()

  let start = try #require(await outbound.next())
  #expect(start.envelope.trace == trace)
  queue.delivered(start)
  var accepted = Oll_Protocol_ArtifactTransferAccepted()
  accepted.artifactID = artifactID
  try pending.resolve(
    replyTo: start.envelope.messageID,
    trace: trace,
    payload: .artifactAccepted(accepted)
  )

  for expectedIndex in 0..<2 {
    let chunk = try #require(await outbound.next())
    #expect(chunk.envelope.trace == trace)
    #expect(chunk.envelope.artifactChunk.chunkIndex == expectedIndex)
    queue.delivered(chunk)
  }

  let complete = try #require(await outbound.next())
  #expect(complete.envelope.trace == trace)
  queue.delivered(complete)
  var stored = Oll_Protocol_ArtifactStored()
  stored.artifactID = artifactID
  try pending.resolve(
    replyTo: complete.envelope.messageID,
    trace: trace,
    payload: .artifactStored(stored)
  )
  #expect(try await transfer.value == stored)
}
