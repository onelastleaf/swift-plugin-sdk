import Foundation
import OnelastleafPluginProtocol

actor PluginSession {
  private enum Phase: Sendable {
    case awaitingHostHello
    case awaitingHostReady
    case active
    case shuttingDown
    case closed
    case failed
  }

  private enum ActionOutcome: Sendable {
    case succeeded(ActionResult)
    case sdkError(PluginSDKError)
    case actionError(String)
    case cancelled
  }

  private struct JobExecution: Sendable {
    let jobID: Oll_Protocol_PluginJobId
    let trace: Oll_Protocol_TraceContext
    let cancellation: CancellationToken
    let scope: JobScope
    let task: Task<Void, Never>
  }

  private struct CancellationReply: Sendable {
    let replyTo: UInt64
    let trace: Oll_Protocol_TraceContext
    let jobID: Oll_Protocol_PluginJobId
  }

  private enum Job: Sendable {
    case running(JobExecution)
    case cancelling(JobExecution, replies: [CancellationReply])
  }

  private struct ShutdownReply: Sendable {
    let replyTo: UInt64
    let trace: Oll_Protocol_TraceContext
  }

  private let pluginID: String
  private let version: String
  private let actions: [String: RegisteredAction]
  private let sender: EnvelopeSender
  private let pending: PendingResponses
  private let failures: RuntimeFailureSignal

  private var phase = Phase.awaitingHostHello
  private var expectedReadyTrace: Oll_Protocol_TraceContext?
  private var sessionID = ""
  private var instanceID = ""
  private var lastHostMessageID: UInt64 = 0
  private var host: HostClient?
  private var jobs: [String: Job] = [:]
  private var maximumCallDepth: UInt32 = 0
  private var maximumCausalDepth: UInt32 = 0
  private var shutdownReply: ShutdownReply?
  private var shutdownDeadlineTask: Task<Void, Never>?
  private var failure: PluginSDKError?

  init(
    pluginID: String,
    version: String,
    actions: [String: RegisteredAction],
    sender: EnvelopeSender,
    pending: PendingResponses,
    failures: RuntimeFailureSignal
  ) {
    self.pluginID = pluginID
    self.version = version
    self.actions = actions
    self.sender = sender
    self.pending = pending
    self.failures = failures
  }

  /// Dispatches one inbound envelope. It never waits for an action task to
  /// finish, so heartbeats and host responses keep flowing during cancellation.
  func handle(_ envelope: Oll_Protocol_PluginEnvelope) throws {
    try validateEnvelope(envelope)
    let trace = envelope.trace

    if envelope.hasReplyTo {
      guard let payload = envelope.payload else {
        throw PluginSDKError.protocolViolation("response payload is required")
      }
      let delivered = try pending.resolve(
        replyTo: envelope.replyTo,
        trace: trace,
        payload: payload
      )
      if !delivered {
        // Artifact chunks, logs, terminal updates, and acknowledgements have
        // no success response. oll can still reject one directly. The host
        // settles the owning job, and an artifact transfer observes the
        // resulting failure when it requests completion.
        guard case .protocolError = payload,
          sender.hasSent(messageID: envelope.replyTo)
        else {
          throw PluginSDKError.protocolViolation(
            "response names no pending plugin request"
          )
        }
      }
      return
    }

    switch phase {
    case .awaitingHostHello:
      try acceptHostHello(envelope, trace: trace)
    case .awaitingHostReady:
      guard case .ready? = envelope.payload,
        trace == expectedReadyTrace
      else {
        throw PluginSDKError.protocolViolation(
          "host SessionReady must exactly inherit the HostHello trace"
        )
      }
      try sender.send(trace: trace, payload: .ready(Oll_Protocol_SessionReady()))
      expectedReadyTrace = nil
      phase = .active
    case .active:
      try handleActive(envelope, trace: trace)
    case .shuttingDown:
      try handleQuiescing(envelope, trace: trace)
    case .closed:
      throw PluginSDKError.protocolViolation("host sent data after shutdown")
    case .failed:
      throw PluginSDKError.protocolViolation("host sent data after session failure")
    }
  }

  // MARK: Handshake

  private func acceptHostHello(
    _ envelope: Oll_Protocol_PluginEnvelope,
    trace: Oll_Protocol_TraceContext
  ) throws {
    guard case .hostHello(let hello)? = envelope.payload else {
      throw PluginSDKError.protocolViolation("HostHello must be the first host message")
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
        "HostHello exceeds a negotiated trace-depth limit"
      )
    }

    sessionID = envelope.sessionID
    instanceID = envelope.pluginInstanceID
    maximumCallDepth = hello.maximumCallDepth
    maximumCausalDepth = hello.maximumCausalDepth
    try sender.configure(sessionID: sessionID, instanceID: instanceID)
    host = HostClient(
      sender: sender,
      pending: pending,
      sessionID: sessionID,
      maximumArtifactChunkBytes: hello.maximumArtifactChunkBytes,
      maximumCallDepth: hello.maximumCallDepth
    )

    var reply = Oll_Protocol_PluginHello()
    var id = Oll_Protocol_PluginId()
    id.value = pluginID
    reply.pluginID = id
    reply.pluginName = hello.pluginName
    reply.pluginVersion = version
    reply.actions = actions.sorted(by: { $0.key < $1.key }).map { name, action in
      var descriptor = Oll_Protocol_ActionDescriptor()
      descriptor.name = name
      descriptor.description_p = action.description
      return descriptor
    }
    try sender.send(trace: trace, payload: .pluginHello(reply))
    expectedReadyTrace = trace
    phase = .awaitingHostReady
  }

  // MARK: Active message dispatch

  private func handleActive(
    _ envelope: Oll_Protocol_PluginEnvelope,
    trace: Oll_Protocol_TraceContext
  ) throws {
    switch envelope.payload {
    case .startJob(let request):
      try startJob(request, replyTo: envelope.messageID, trace: trace)
    case .cancelJob(let request):
      try cancelJob(request, replyTo: envelope.messageID, trace: trace)
    case .heartbeat(let heartbeat):
      try sendHeartbeat(heartbeat, replyTo: envelope.messageID, trace: trace)
    case .shutdown(let request):
      try beginShutdown(request, replyTo: envelope.messageID, trace: trace)
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    case .none:
      throw PluginSDKError.protocolViolation("payload is required")
    default:
      throw PluginSDKError.protocolViolation("unexpected host-initiated message")
    }
  }

  private func handleQuiescing(
    _ envelope: Oll_Protocol_PluginEnvelope,
    trace: Oll_Protocol_TraceContext
  ) throws {
    switch envelope.payload {
    case .cancelJob(let request):
      try cancelJob(request, replyTo: envelope.messageID, trace: trace)
    case .heartbeat(let heartbeat):
      try sendHeartbeat(heartbeat, replyTo: envelope.messageID, trace: trace)
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    default:
      throw PluginSDKError.protocolViolation(
        "host sent a new operation while the plugin was shutting down"
      )
    }
  }

  private func sendHeartbeat(
    _ heartbeat: Oll_Protocol_Heartbeat,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) throws {
    try sender.send(replyTo: replyTo, trace: trace, payload: .heartbeat(heartbeat))
  }

  // MARK: Jobs

  private func startJob(
    _ request: Oll_Protocol_StartJobRequest,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) throws {
    let jobID = request.jobID.value
    guard request.hasJobID,
      isCanonicalUUIDv4(jobID),
      jobs[jobID] == nil
    else {
      throw PluginSDKError.protocolViolation("job ID is missing, invalid, or already active")
    }
    guard case .action(let invocation)? = request.invocation,
      let action = actions[invocation.action],
      let host
    else {
      throw PluginSDKError.protocolViolation("unsupported or unknown job invocation")
    }
    if request.hasDeadline {
      do {
        try validateTimestamp(request.deadline, field: "StartJobRequest.deadline")
      } catch {
        throw PluginSDKError.protocolViolation(String(describing: error))
      }
    }

    var accepted = Oll_Protocol_JobAccepted()
    accepted.jobID = request.jobID
    try sender.send(
      replyTo: replyTo,
      trace: trace,
      payload: .jobAccepted(accepted)
    )

    let cancellation = CancellationToken()
    let scope = JobScope()
    let context = ActionContext(
      jobID: jobID,
      deadline: request.hasDeadline ? request.deadline : nil,
      cancellation: cancellation,
      trace: trace,
      host: host,
      parentCallID: replyTo,
      scope: scope
    )
    let session = self
    let protoJobID = request.jobID
    let arguments = invocation.arguments
    let task = Task {
      let outcome: ActionOutcome
      do {
        let result = try await action.handler(context, arguments)
        try cancellation.checkCancellation()
        outcome = .succeeded(result)
      } catch is CancellationError {
        outcome = .cancelled
      } catch let error as PluginSDKError {
        outcome = .sdkError(error)
      } catch {
        outcome = .actionError(String(describing: error))
      }
      scope.stopAdmission()
      cancellation.finish()
      await scope.waitUntilDrained()
      await session.actionFinished(jobID: jobID, outcome: outcome)
    }
    jobs[jobID] = .running(
      JobExecution(
        jobID: protoJobID,
        trace: trace,
        cancellation: cancellation,
        scope: scope,
        task: task
      )
    )
  }

  private func cancelJob(
    _ request: Oll_Protocol_CancelJobRequest,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) throws {
    let jobID = request.jobID.value
    guard request.hasJobID,
      isCanonicalUUIDv4(jobID),
      request.reason == .userRequest || request.reason == .deadline
    else {
      throw PluginSDKError.protocolViolation("CancelJobRequest is invalid")
    }
    let reply = CancellationReply(replyTo: replyTo, trace: trace, jobID: request.jobID)

    switch jobs[jobID] {
    case .running(let execution):
      guard execution.trace.correlationID == trace.correlationID else {
        throw PluginSDKError.protocolViolation(
          "cancellation correlation context differs from its job"
        )
      }
      jobs[jobID] = .cancelling(execution, replies: [reply])
      execution.scope.stopAdmission()
      execution.cancellation.cancel()
      execution.task.cancel()
    case .cancelling(let execution, var replies):
      guard execution.trace.correlationID == trace.correlationID else {
        throw PluginSDKError.protocolViolation(
          "cancellation correlation context differs from its job"
        )
      }
      replies.append(reply)
      jobs[jobID] = .cancelling(execution, replies: replies)
    case .none:
      try acknowledgeCancellation(reply)
    }
  }

  private func actionFinished(jobID: String, outcome: ActionOutcome) {
    guard let state = jobs[jobID] else { return }
    switch state {
    case .running(let execution):
      if case .sdkError(let error) = outcome, error.terminatesSession {
        reportFailure(error)
        return
      }
      do {
        let update = terminalUpdate(for: execution, outcome: outcome)
        // Sender admission is synchronous and ordered. The terminal update is
        // therefore queued before this job can disappear or a late cancel can
        // observe it as inactive.
        try sender.send(trace: execution.trace, payload: .jobUpdate(update))
        jobs.removeValue(forKey: jobID)
        try settleShutdownIfPossible()
      } catch let error as PluginSDKError {
        reportFailure(error)
      } catch {
        reportFailure(.transport(String(describing: error)))
      }
    case .cancelling(_, let replies):
      do {
        for reply in replies {
          try acknowledgeCancellation(reply)
        }
        jobs.removeValue(forKey: jobID)
        try settleShutdownIfPossible()
      } catch let error as PluginSDKError {
        reportFailure(error)
      } catch {
        reportFailure(.transport(String(describing: error)))
      }
    }
  }

  private func terminalUpdate(
    for execution: JobExecution,
    outcome: ActionOutcome
  ) -> Oll_Protocol_JobUpdate {
    var update = Oll_Protocol_JobUpdate()
    update.jobID = execution.jobID
    switch outcome {
    case .succeeded(let result):
      do {
        if let value = result.value {
          try validateConfigValue(value, policy: .serializable)
          update.result = value
        }
        try execution.scope.validateResultArtifacts(result.artifacts)
        update.artifacts = result.artifacts
        update.state = .succeeded
        update.progress = 1
      } catch let error as PluginSDKError {
        update.state = .failed
        update.error = error.protocolError()
      } catch {
        update.state = .failed
        update.error = PluginSDKError.action(String(describing: error)).protocolError()
      }
    case .sdkError(let error):
      update.state = .failed
      update.error = error.protocolError()
    case .actionError(let description):
      update.state = .failed
      update.error = PluginSDKError.action(description).protocolError()
    case .cancelled:
      var error = Oll_Protocol_ProtocolError()
      error.code = .cancelled
      error.message = "action cancelled without a host cancellation request"
      update.state = .failed
      update.error = error
    }
    return update
  }

  private func acknowledgeCancellation(_ reply: CancellationReply) throws {
    var acknowledged = Oll_Protocol_CancelJobAcknowledged()
    acknowledged.jobID = reply.jobID
    try sender.send(
      replyTo: reply.replyTo,
      trace: reply.trace,
      payload: .cancelJobAcknowledged(acknowledged)
    )
  }

  // MARK: Shutdown

  private func beginShutdown(
    _ request: Oll_Protocol_ShutdownRequest,
    replyTo: UInt64,
    trace: Oll_Protocol_TraceContext
  ) throws {
    guard request.hasGracePeriodDeadline else {
      throw PluginSDKError.protocolViolation(
        "ShutdownRequest.grace_period_deadline is required"
      )
    }
    do {
      try validateTimestamp(
        request.gracePeriodDeadline,
        field: "ShutdownRequest.grace_period_deadline"
      )
    } catch {
      throw PluginSDKError.protocolViolation(String(describing: error))
    }

    phase = .shuttingDown
    shutdownReply = ShutdownReply(replyTo: replyTo, trace: trace)
    let delay = max(0, request.gracePeriodDeadline.date.timeIntervalSinceNow)
    let session = self
    shutdownDeadlineTask = Task {
      do {
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
      } catch is CancellationError {
        return
      } catch {
        await session.shutdownDeadlineTimerFailed(String(describing: error))
        return
      }
      guard !Task.isCancelled else { return }
      await session.shutdownDeadlineReached()
    }

    for jobID in Array(jobs.keys) {
      guard case .running(let execution) = jobs[jobID] else { continue }
      jobs[jobID] = .cancelling(execution, replies: [])
      execution.scope.stopAdmission()
      execution.cancellation.cancel()
      execution.task.cancel()
    }
    try settleShutdownIfPossible()
  }

  private func settleShutdownIfPossible() throws {
    guard phase == .shuttingDown, jobs.isEmpty, let shutdownReply else { return }
    shutdownDeadlineTask?.cancel()
    shutdownDeadlineTask = nil
    try sender.send(
      replyTo: shutdownReply.replyTo,
      trace: shutdownReply.trace,
      payload: .shutdownAcknowledged(Oll_Protocol_ShutdownAcknowledged())
    )
    self.shutdownReply = nil
    phase = .closed
  }

  private func shutdownDeadlineReached() {
    guard phase == .shuttingDown else { return }
    reportFailure(.shutdownDeadlineExceeded)
  }

  private func shutdownDeadlineTimerFailed(_ description: String) {
    guard phase == .shuttingDown else { return }
    reportFailure(.transport("shutdown deadline timer failed: \(description)"))
  }

  // MARK: Validation and teardown

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
    if maximumCallDepth != 0, envelope.trace.callDepth > maximumCallDepth {
      throw PluginSDKError.protocolViolation(
        "host envelope exceeds maximum call depth"
      )
    }
    if maximumCausalDepth != 0, envelope.trace.causalDepth > maximumCausalDepth {
      throw PluginSDKError.protocolViolation(
        "host envelope exceeds maximum causal depth"
      )
    }
    lastHostMessageID = envelope.messageID
  }

  private func validateHostHello(_ hello: Oll_Protocol_HostHello) throws {
    guard hello.hasNode,
      hello.node.hasNodeID,
      isCanonicalUUIDv4(hello.node.nodeID.value),
      hello.node.hasNodeName,
      isValidDNSLabel(hello.node.nodeName.value),
      hello.hasPluginID,
      hello.pluginID.value == pluginID,
      hello.hasPluginName,
      isValidDNSLabel(hello.pluginName.value),
      hello.maximumCallDepth > 0,
      hello.maximumCausalDepth > 0,
      hello.maximumArtifactChunkBytes > 0
    else {
      throw PluginSDKError.protocolViolation(
        "HostHello does not describe a valid expected plugin instance"
      )
    }
  }

  private func reportFailure(_ error: PluginSDKError) {
    guard phase != .failed else { return }
    phase = .failed
    failure = error
    shutdownDeadlineTask?.cancel()
    shutdownDeadlineTask = nil
    shutdownReply = nil
    cancelJobsWithoutWaiting()
    pending.failAll(error)
    failures.report(error)
  }

  func close() {
    guard phase != .closed, phase != .failed else { return }
    phase = .closed
    shutdownDeadlineTask?.cancel()
    shutdownDeadlineTask = nil
    shutdownReply = nil
    cancelJobsWithoutWaiting()
  }

  private func cancelJobsWithoutWaiting() {
    let active = Array(jobs.values)
    jobs.removeAll(keepingCapacity: false)
    for job in active {
      switch job {
      case .running(let execution), .cancelling(let execution, _):
        execution.scope.stopAdmission()
        execution.cancellation.cancel()
        execution.task.cancel()
      }
    }
  }

  func responseStreamEnded() throws {
    if let failure { throw failure }
    guard phase == .closed else {
      throw PluginSDKError.transport(
        "host closed the plugin stream without completing ShutdownRequest"
      )
    }
  }
}
