import Foundation
import SwiftProtobuf
import Testing

@testable import OnelastleafPluginSDK

enum TestSupportError: Error {
  case missingEnvelope
  case timedOut
}

let lifecycleCorrelationID = "00000000-0000-4000-8000-000000000001"
let testSessionID = "sdk-test-session"
let testInstanceID = "sdk-test-instance"

func makeTrace(
  _ correlationID: String = lifecycleCorrelationID
) -> Oll_Protocol_TraceContext {
  var trace = Oll_Protocol_TraceContext()
  trace.correlationID = correlationID
  return trace
}

func makeHostEnvelope(
  messageID: UInt64,
  replyTo: UInt64? = nil,
  trace: Oll_Protocol_TraceContext,
  payload: Oll_Protocol_PluginEnvelope.OneOf_Payload
) -> Oll_Protocol_PluginEnvelope {
  var envelope = Oll_Protocol_PluginEnvelope()
  envelope.messageID = messageID
  if let replyTo { envelope.replyTo = replyTo }
  envelope.sessionID = testSessionID
  envelope.pluginInstanceID = testInstanceID
  envelope.trace = trace
  envelope.payload = payload
  return envelope
}

func makeHostHello() -> Oll_Protocol_HostHello {
  var nodeID = Oll_Protocol_NodeId()
  nodeID.value = "00000000-0000-4000-8000-000000000002"
  var nodeName = Oll_Protocol_NodeName()
  nodeName.value = "test-host"
  var node = Oll_Protocol_NodeIdentity()
  node.nodeID = nodeID
  node.nodeName = nodeName
  var pluginID = Oll_Protocol_PluginId()
  pluginID.value = "org.onelastleaf.test"
  var pluginName = Oll_Protocol_PluginName()
  pluginName.value = "test-plugin"
  var hello = Oll_Protocol_HostHello()
  hello.node = node
  hello.maximumCallDepth = 8
  hello.maximumCausalDepth = 8
  hello.maximumArtifactChunkBytes = 64 * 1_024
  hello.pluginID = pluginID
  hello.pluginName = pluginName
  return hello
}

struct SessionHarness {
  let queue: EnvelopeQueue
  let pending: PendingResponses
  let failures: RuntimeFailureSignal
  let session: PluginSession

  init(actions: [String: RegisteredAction]) {
    let queue = EnvelopeQueue()
    let pending = PendingResponses()
    let failures = RuntimeFailureSignal()
    self.queue = queue
    self.pending = pending
    self.failures = failures
    session = PluginSession(
      pluginID: "org.onelastleaf.test",
      version: "0.1.0",
      actions: actions,
      sender: EnvelopeSender(queue: queue),
      pending: pending,
      failures: failures
    )
  }
}

func performHandshake(
  _ harness: SessionHarness,
  outbound: inout AsyncStream<Oll_Protocol_PluginEnvelope>.Iterator
) async throws {
  let trace = makeTrace()
  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 1,
      trace: trace,
      payload: .hostHello(makeHostHello())
    )
  )
  let pluginHello = try await nextEnvelope(&outbound)
  #expect(pluginHello.trace == trace)
  #expect(pluginHello.payload?.isPluginHello == true)

  try await harness.session.handle(
    makeHostEnvelope(
      messageID: 2,
      trace: trace,
      payload: .ready(Oll_Protocol_SessionReady())
    )
  )
  let ready = try await nextEnvelope(&outbound)
  #expect(ready.trace == trace)
  #expect(ready.payload?.isReady == true)
}

func nextEnvelope(
  _ iterator: inout AsyncStream<Oll_Protocol_PluginEnvelope>.Iterator
) async throws -> Oll_Protocol_PluginEnvelope {
  guard let envelope = await iterator.next() else {
    throw TestSupportError.missingEnvelope
  }
  return envelope
}

func withTimeout<Value: Sendable>(
  _ duration: Duration = .seconds(2),
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TestSupportError.timedOut
    }
    guard let first = try await group.next() else {
      throw TestSupportError.timedOut
    }
    group.cancelAll()
    return first
  }
}

extension Oll_Protocol_PluginEnvelope.OneOf_Payload {
  fileprivate var isPluginHello: Bool {
    if case .pluginHello = self { return true }
    return false
  }

  fileprivate var isReady: Bool {
    if case .ready = self { return true }
    return false
  }
}

func makeJobID(_ value: String) -> Oll_Protocol_PluginJobId {
  var jobID = Oll_Protocol_PluginJobId()
  jobID.value = value
  return jobID
}

func makeStartJob(
  jobID: String,
  action: String,
  deadline: Google_Protobuf_Timestamp? = nil
) -> Oll_Protocol_StartJobRequest {
  var invocation = Oll_Protocol_ActionInvocation()
  invocation.action = action
  var request = Oll_Protocol_StartJobRequest()
  request.jobID = makeJobID(jobID)
  request.invocation = .action(invocation)
  if let deadline { request.deadline = deadline }
  return request
}

func makeCancelJob(_ jobID: String) -> Oll_Protocol_CancelJobRequest {
  var request = Oll_Protocol_CancelJobRequest()
  request.jobID = makeJobID(jobID)
  request.reason = .userRequest
  return request
}

func makeDescriptor(
  id: String = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  fileName: String = "result.bin",
  mediaType: String = "application/octet-stream",
  size: UInt64,
  sha256: Data
) -> Oll_Protocol_ArtifactDescriptor {
  var artifactID = Oll_Protocol_PluginArtifactId()
  artifactID.value = id
  var descriptor = Oll_Protocol_ArtifactDescriptor()
  descriptor.artifactID = artifactID
  descriptor.fileName = fileName
  descriptor.mediaType = mediaType
  descriptor.sizeBytes = size
  descriptor.sha256 = sha256
  return descriptor
}
