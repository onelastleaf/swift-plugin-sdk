import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

private final class ParentLivenessState: @unchecked Sendable {
  private let lock = NSLock()
  private var reachedEOF = false

  func markEOF() {
    lock.withLock { reachedEOF = true }
  }

  var didReachEOF: Bool {
    lock.withLock { reachedEOF }
  }
}

public final class Plugin: @unchecked Sendable {
  private let pluginID: String
  private let version: String
  private var actions: [String: RegisteredAction] = [:]

  public init(id: String, version: String) throws {
    try validatePluginID(id)
    guard !version.isEmpty else {
      throw PluginSDKError.invalidArgument("plugin version must not be empty")
    }
    pluginID = id
    self.version = version
  }

  @discardableResult
  public func action(
    name: String,
    description: String,
    handler: @escaping @Sendable (ActionContext, [String]) async throws -> ActionResult
  ) throws -> Self {
    guard !name.isEmpty, actions[name] == nil else {
      throw PluginSDKError.invalidArgument(
        "action names must be nonempty and unique"
      )
    }
    actions[name] = RegisteredAction(description: description, handler: handler)
    return self
  }

  public func run() async throws {
    guard let rawEndpoint = ProcessInfo.processInfo.environment["OLL_PLUGIN_ENDPOINT"] else {
      throw PluginSDKError.environment("OLL_PLUGIN_ENDPOINT is required")
    }
    let endpoint = try PluginEndpoint.parse(rawEndpoint)
    let queue = EnvelopeQueue()
    let sender = EnvelopeSender(queue: queue)
    let pending = PendingResponses()
    let session = PluginSession(
      pluginID: pluginID,
      version: version,
      actions: actions,
      sender: sender,
      pending: pending
    )

    var options = CallOptions.defaults
    options.maxRequestMessageBytes = 64 * 1024 * 1024
    options.maxResponseMessageBytes = 64 * 1024 * 1024
    options.waitForReady = true

    let connection = Task {
      try await withGRPCClient(
        transport: .http2NIOPosix(
          target: .dns(host: endpoint.host, port: endpoint.port),
          transportSecurity: .plaintext
        )
      ) { client in
        let runtime = Oll_Protocol_PluginRuntime.Client(wrapping: client)
        try await runtime.connect(
          options: options,
          requestProducer: { writer in
            for await outbound in queue.stream {
              do {
                try await writer.write(outbound.envelope)
                queue.delivered(outbound)
              } catch {
                queue.failed(outbound, error: error)
                throw error
              }
            }
          },
          onResponse: { response in
            defer { queue.finish() }
            for try await envelope in response.messages {
              try await session.handle(envelope)
            }
            try await session.responseStreamEnded()
          }
        )
      }
      await session.close()
    }
    let parentLiveness = ParentLivenessState()
    Task.detached {
      _ = FileHandle.standardInput.readDataToEndOfFile()
      parentLiveness.markEOF()
      queue.finish()
      connection.cancel()
    }

    do {
      try await connection.value
    } catch  where parentLiveness.didReachEOF {
      await session.close()
    } catch let error as PluginSDKError {
      await session.close()
      pending.failAll(error)
      throw error
    } catch {
      await session.close()
      let wrapped = PluginSDKError.transport(String(describing: error))
      pending.failAll(wrapped)
      throw wrapped
    }
  }
}

private actor PluginSession {
  private enum Phase: Sendable {
    case hostHello
    case hostReady(correlationID: String)
    case active
    case closed
  }

  private struct ActiveJob: Sendable {
    let cancellation: CancellationToken
    let task: Task<Void, Never>
  }

  private let pluginID: String
  private let version: String
  private let actions: [String: RegisteredAction]
  private let sender: EnvelopeSender
  private let pending: PendingResponses
  private var phase: Phase = .hostHello
  private var sessionID = ""
  private var instanceID = ""
  private var lastHostMessageID: UInt64 = 0
  private var host: HostClient?
  private var jobs: [String: ActiveJob] = [:]
  private var maximumCallDepth: UInt32 = 0
  private var maximumCausalDepth: UInt32 = 0

  init(
    pluginID: String,
    version: String,
    actions: [String: RegisteredAction],
    sender: EnvelopeSender,
    pending: PendingResponses
  ) {
    self.pluginID = pluginID
    self.version = version
    self.actions = actions
    self.sender = sender
    self.pending = pending
  }

  func handle(_ envelope: Oll_Protocol_PluginEnvelope) async throws {
    try validateEnvelope(envelope)
    let trace = envelope.trace

    if envelope.hasReplyTo {
      guard let payload = envelope.payload else {
        throw PluginSDKError.protocolViolation("response payload is required")
      }
      try pending.resolve(
        replyTo: envelope.replyTo,
        trace: trace,
        payload: payload
      )
      return
    }

    switch phase {
    case .hostHello:
      try await acceptHostHello(envelope, trace: trace)
    case .hostReady(let correlationID):
      guard case .ready? = envelope.payload,
        trace.correlationID == correlationID
      else {
        throw PluginSDKError.protocolViolation(
          "host SessionReady must follow PluginHello"
        )
      }
      try await sender.send(trace: trace, payload: .ready(Oll_Protocol_SessionReady()))
      phase = .active
      return
    case .active:
      try await handleActive(envelope, trace: trace)
    case .closed:
      throw PluginSDKError.protocolViolation("host sent data after shutdown")
    }
  }

  private func acceptHostHello(
    _ envelope: Oll_Protocol_PluginEnvelope,
    trace: Oll_Protocol_TraceContext
  ) async throws {
    guard !envelope.hasReplyTo,
      case .hostHello(let hello)? = envelope.payload
    else {
      throw PluginSDKError.protocolViolation(
        "HostHello must be the first host message"
      )
    }
    guard !envelope.sessionID.isEmpty, !envelope.pluginInstanceID.isEmpty else {
      throw PluginSDKError.protocolViolation(
        "HostHello envelope omitted its session or instance identity"
      )
    }
    try validateHostHello(hello)
    guard trace.callDepth <= hello.maximumCallDepth,
      trace.causalDepth <= hello.maximumCausalDepth
    else {
      throw PluginSDKError.protocolViolation(
        "HostHello exceeds a negotiated trace depth limit"
      )
    }
    sessionID = envelope.sessionID
    instanceID = envelope.pluginInstanceID
    maximumCallDepth = hello.maximumCallDepth
    maximumCausalDepth = hello.maximumCausalDepth
    await sender.configure(sessionID: sessionID, instanceID: instanceID)
    host = HostClient(
      sender: sender,
      pending: pending,
      maximumArtifactChunkBytes: hello.maximumArtifactChunkBytes,
      maximumCallDepth: hello.maximumCallDepth
    )

    var helloReply = Oll_Protocol_PluginHello()
    var id = Oll_Protocol_PluginId()
    id.value = pluginID
    helloReply.pluginID = id
    helloReply.pluginName = hello.pluginName
    helloReply.pluginVersion = version
    helloReply.actions = actions.sorted(by: { $0.key < $1.key }).map { name, action in
      var descriptor = Oll_Protocol_ActionDescriptor()
      descriptor.name = name
      descriptor.description_p = action.description
      return descriptor
    }
    try await sender.send(trace: trace, payload: .pluginHello(helloReply))
    phase = .hostReady(correlationID: trace.correlationID)
  }

  private func handleActive(
    _ envelope: Oll_Protocol_PluginEnvelope,
    trace: Oll_Protocol_TraceContext
  ) async throws {
    switch envelope.payload {
    case .startJob(let request):
      try await startJob(request, replyTo: envelope.messageID, trace: trace)
    case .cancelJob(let request):
      try await cancelJob(request, replyTo: envelope.messageID, trace: trace)
    case .heartbeat(let heartbeat):
      try await sender.send(
        replyTo: envelope.messageID,
        trace: trace,
        payload: .heartbeat(heartbeat)
      )
    case .shutdown:
      await cancelAllJobs()
      try await sender.send(
        replyTo: envelope.messageID,
        trace: trace,
        payload: .shutdownAcknowledged(Oll_Protocol_ShutdownAcknowledged())
      )
      phase = .closed
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    case .none:
      throw PluginSDKError.protocolViolation("payload is required")
    default:
      throw PluginSDKError.protocolViolation(
        "unexpected host-initiated message"
      )
    }
  }

  private func startJob(
    _ request: Oll_Protocol_StartJobRequest,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) async throws {
    let jobID = request.jobID.value
    guard request.hasJobID, canonicalUUIDv4(jobID), jobs[jobID] == nil else {
      throw PluginSDKError.protocolViolation("job ID is missing or already active")
    }
    guard case .action(let invocation)? = request.invocation,
      let action = actions[invocation.action],
      let host
    else {
      throw PluginSDKError.protocolViolation("unsupported or unknown job invocation")
    }

    var accepted = Oll_Protocol_JobAccepted()
    accepted.jobID = request.jobID
    try await sender.send(
      replyTo: replyTo,
      trace: trace,
      payload: .jobAccepted(accepted)
    )

    let cancellation = CancellationToken()
    let deadline = request.hasDeadline ? request.deadline : nil
    let context = ActionContext(
      jobID: jobID,
      deadline: deadline,
      trace: trace,
      cancellation: cancellation,
      host: host,
      parentCallID: replyTo
    )
    let sender = self.sender
    let session = self
    let task = Task {
      var update = Oll_Protocol_JobUpdate()
      update.jobID = request.jobID
      update.progress = 1
      do {
        let result = try await action.handler(context, invocation.arguments)
        try await cancellation.checkCancellation()
        update.state = .succeeded
        if let value = result.value { update.result = value }
        update.artifacts = result.artifacts
      } catch is CancellationError {
        await session.jobFinished(jobID)
        return
      } catch let error as PluginSDKError {
        update.state = .failed
        update.error = error.protocolError()
      } catch {
        update.state = .failed
        update.error = PluginSDKError.action(String(describing: error)).protocolError()
      }
      _ = try? await sender.send(trace: trace, payload: .jobUpdate(update))
      await session.jobFinished(jobID)
    }
    jobs[jobID] = ActiveJob(cancellation: cancellation, task: task)
  }

  private func cancelJob(
    _ request: Oll_Protocol_CancelJobRequest,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) async throws {
    let jobID = request.jobID.value
    guard request.hasJobID, let job = jobs.removeValue(forKey: jobID) else {
      throw PluginSDKError.protocolViolation("cancellation names no active job")
    }
    await job.cancellation.cancel()
    job.task.cancel()
    await job.task.value
    var acknowledged = Oll_Protocol_CancelJobAcknowledged()
    acknowledged.jobID = request.jobID
    try await sender.send(
      replyTo: replyTo,
      trace: trace,
      payload: .cancelJobAcknowledged(acknowledged)
    )
  }

  private func cancelAllJobs() async {
    let active = jobs.values
    jobs.removeAll()
    for job in active {
      await job.cancellation.cancel()
      job.task.cancel()
    }
    for job in active { await job.task.value }
  }

  private func jobFinished(_ jobID: String) {
    jobs.removeValue(forKey: jobID)
  }

  private func validateEnvelope(_ envelope: Oll_Protocol_PluginEnvelope) throws {
    guard envelope.messageID > lastHostMessageID else {
      throw PluginSDKError.protocolViolation(
        "host message IDs must be nonzero and strictly increasing"
      )
    }
    guard envelope.hasTrace, !envelope.trace.correlationID.isEmpty else {
      throw PluginSDKError.protocolViolation("host omitted correlation context")
    }
    if !sessionID.isEmpty,
      envelope.sessionID != sessionID || envelope.pluginInstanceID != instanceID
    {
      throw PluginSDKError.protocolViolation(
        "host envelope belongs to another plugin instance"
      )
    }
    if maximumCallDepth != 0,
      envelope.trace.callDepth > maximumCallDepth
    {
      throw PluginSDKError.protocolViolation(
        "host envelope exceeds maximum call depth"
      )
    }
    if maximumCausalDepth != 0,
      envelope.trace.causalDepth > maximumCausalDepth
    {
      throw PluginSDKError.protocolViolation(
        "host envelope exceeds maximum causal depth"
      )
    }
    lastHostMessageID = envelope.messageID
  }

  func close() async {
    if case .closed = phase { return }
    phase = .closed
    await cancelAllJobs()
  }

  func responseStreamEnded() throws {
    guard case .closed = phase else {
      throw PluginSDKError.transport(
        "host closed the plugin stream without ShutdownRequest"
      )
    }
  }

  private func validateHostHello(_ hello: Oll_Protocol_HostHello) throws {
    guard hello.hasNode,
      hello.hasPluginID,
      hello.pluginID.value == pluginID,
      hello.hasPluginName,
      !hello.pluginName.value.isEmpty,
      hello.maximumCallDepth > 0,
      hello.maximumCausalDepth > 0,
      hello.maximumArtifactChunkBytes > 0
    else {
      throw PluginSDKError.protocolViolation(
        "HostHello does not describe the expected plugin instance"
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

private func validatePluginID(_ value: String) throws {
  let labels = value.split(separator: ".", omittingEmptySubsequences: false)
  guard value.utf8.count <= 191,
    labels.count >= 2,
    labels.allSatisfy({ validDNSLabel($0) })
  else {
    throw PluginSDKError.invalidArgument(
      "plugin ID must be a lower-case dotted DNS name"
    )
  }
}

private func validDNSLabel(_ value: Substring) -> Bool {
  let bytes = Array(value.utf8)
  guard !bytes.isEmpty, bytes.count <= 63,
    isLowercaseLetterOrDigit(bytes[0]),
    isLowercaseLetterOrDigit(bytes[bytes.count - 1])
  else { return false }
  return bytes.allSatisfy { isLowercaseLetterOrDigit($0) || $0 == 45 }
}

private func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
  (97...122).contains(byte) || (48...57).contains(byte)
}
