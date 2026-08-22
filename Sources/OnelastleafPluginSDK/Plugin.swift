import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import OnelastleafPluginProtocol
import Synchronization

/// A trusted onelastleaf plugin process that connects to an oll-owned runtime.
///
/// Create one `Plugin`, register every action with ``action(name:description:handler:)``,
/// and then call ``run()`` from the executable entry point. A plugin instance is
/// single-use: registration closes when `run()` starts, and the same instance cannot
/// be run again.
///
/// `Plugin` connects as a gRPC client. It does not listen for incoming connections.
/// oll supplies the loopback endpoint in `OLL_PLUGIN_ENDPOINT` and reserves the
/// process's standard input as a parent-liveness pipe.
public final class Plugin: Sendable {
  private enum Phase: Sendable {
    case configuring
    case running
    case finished
  }

  private struct State: Sendable {
    var phase = Phase.configuring
    var actions: [String: RegisteredAction] = [:]
  }

  private let pluginID: String
  private let version: String
  private let state = Mutex(State())

  /// Creates a plugin with the identity oll expects during the handshake.
  ///
  /// Keep `id` identical to `plugin.id` in the publisher's `oll.toml`. The ID is a
  /// stable machine identity, not the mutable display name shown to users.
  ///
  /// - Parameters:
  ///   - id: A lower-case dotted DNS name such as `com.example.my-plugin`. It must
  ///     contain at least two labels and occupy no more than 191 UTF-8 bytes. Each
  ///     label begins and ends with a letter or digit and may contain internal
  ///     hyphens.
  ///   - version: A nonempty informational build or release string. The host reports
  ///     it for diagnostics but does not use it to select or update the package.
  /// - Throws: ``PluginSDKError/invalidArgument(_:)`` when either value is invalid.
  public init(id: String, version: String) throws {
    try validatePluginID(id)
    guard !version.isEmpty else {
      throw PluginSDKError.invalidArgument("plugin version must not be empty")
    }
    pluginID = id
    self.version = version
  }

  /// Registers an action that oll can invoke as a job.
  ///
  /// Register all actions before calling ``run()``. The handler may execute at the
  /// same time as handlers for other jobs, so captured mutable state must be safe to
  /// use concurrently. The ordered `arguments` array preserves duplicates, empty
  /// strings, and values beginning with `-`.
  ///
  /// - Parameters:
  ///   - name: The nonempty action name exposed through oll. Names must be unique
  ///     within this plugin instance.
  ///   - description: A human-facing summary of what the action does.
  ///   - handler: The asynchronous operation for one job. Return an ``ActionResult``
  ///     to succeed or throw an error to fail that job.
  /// - Returns: This plugin, so registrations can be chained.
  /// - Throws: ``PluginSDKError/invalidArgument(_:)`` when the name is empty or
  ///   duplicated, or when registration has already closed.
  @discardableResult
  public func action(
    name: String,
    description: String,
    handler: @escaping @Sendable (ActionContext, [String]) async throws -> ActionResult
  ) throws -> Self {
    try state.withLock { state in
      guard state.phase == .configuring else {
        throw PluginSDKError.invalidArgument(
          "actions cannot be registered after the plugin starts"
        )
      }
      guard !name.isEmpty, state.actions[name] == nil else {
        throw PluginSDKError.invalidArgument(
          "action names must be nonempty and unique"
        )
      }
      state.actions[name] = RegisteredAction(
        description: description,
        handler: handler
      )
    }
    return self
  }

  /// Connects to the oll-owned runtime and serves registered actions.
  ///
  /// This call normally lasts for the remaining lifetime of the plugin process. It
  /// returns after a graceful shutdown, parent stdin EOF, or connection closure. It
  /// throws when setup, transport, or protocol processing fails, and propagates
  /// caller cancellation as `CancellationError`.
  ///
  /// Call this method exactly once and do not read standard input elsewhere in the
  /// process. oll owns standard input as the parent-liveness pipe, and EOF requires
  /// the plugin to exit.
  ///
  /// - Throws: ``PluginSDKError`` for SDK failures, or `CancellationError` when the
  ///   task running the plugin is cancelled.
  public func run() async throws {
    let actions = try beginRun()
    defer { state.withLock { $0.phase = .finished } }
    try await PluginRuntime(pluginID: pluginID, version: version, actions: actions).run()
  }

  /// Atomically freezes registration and returns the runtime's action snapshot.
  func beginRun() throws -> [String: RegisteredAction] {
    try state.withLock { state in
      guard state.phase == .configuring else {
        throw PluginSDKError.invalidArgument("a Plugin instance can run only once")
      }
      state.phase = .running
      return state.actions
    }
  }
}

private enum RuntimeEvent: Sendable {
  case connectionClosed
  case parentEOF
  case sessionFailed(PluginSDKError)
}

final class RuntimeFailureSignal: Sendable {
  private let result = AsyncResult<PluginSDKError>()

  func report(_ error: PluginSDKError) {
    result.succeed(error)
  }

  func wait() async throws -> PluginSDKError {
    try await result.value()
  }
}

private struct PluginRuntime: Sendable {
  let pluginID: String
  let version: String
  let actions: [String: RegisteredAction]

  func run() async throws {
    guard let rawEndpoint = ProcessInfo.processInfo.environment["OLL_PLUGIN_ENDPOINT"] else {
      throw PluginSDKError.environment("OLL_PLUGIN_ENDPOINT is required")
    }
    let endpoint = try PluginEndpoint.parse(rawEndpoint)
    let queue = EnvelopeQueue()
    let sender = EnvelopeSender(queue: queue)
    let pending = PendingResponses()
    let failures = RuntimeFailureSignal()
    let session = PluginSession(
      pluginID: pluginID,
      version: version,
      actions: actions,
      sender: sender,
      pending: pending,
      failures: failures
    )

    // Install the EOF observer before connection work starts so an already
    // closed liveness pipe cannot be missed.
    let parentLiveness = ParentLivenessMonitor(input: .standardInput)
    let event: RuntimeEvent
    do {
      event = try await withThrowingTaskGroup(of: RuntimeEvent.self) { group in
        group.addTask {
          try await connect(
            endpoint: endpoint,
            queue: queue,
            session: session
          )
          return .connectionClosed
        }
        group.addTask {
          try await parentLiveness.waitForEOF()
          return .parentEOF
        }
        group.addTask {
          .sessionFailed(try await failures.wait())
        }

        guard let first = try await group.next() else {
          throw PluginSDKError.transport("plugin runtime stopped without an outcome")
        }
        group.cancelAll()
        parentLiveness.stop()
        queue.finish()
        return first
      }
    } catch {
      parentLiveness.stop()
      queue.finish()
      await session.close()
      if error is CancellationError {
        pending.failAll(CancellationError())
        throw error
      }
      let wrapped =
        (error as? PluginSDKError)
        ?? PluginSDKError.transport(String(describing: error))
      pending.failAll(wrapped)
      throw wrapped
    }

    parentLiveness.stop()
    queue.finish()
    await session.close()
    switch event {
    case .parentEOF:
      pending.failAll(CancellationError())
    case .connectionClosed:
      pending.failAll(
        PluginSDKError.transport("plugin session ended before host response")
      )
    case .sessionFailed(let error):
      pending.failAll(error)
      throw error
    }
  }

  private func connect(
    endpoint: PluginEndpoint,
    queue: EnvelopeQueue,
    session: PluginSession
  ) async throws {
    let options = pluginRuntimeCallOptions()

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
          for await envelope in queue.stream {
            try await writer.write(envelope)
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
  }
}

func pluginRuntimeCallOptions() -> CallOptions {
  var options = CallOptions.defaults
  // The canonical protocol has no envelope cap. Int.max is grpc-swift's
  // largest supported value and also overrides its smaller default.
  options.maxRequestMessageBytes = .max
  options.maxResponseMessageBytes = .max
  options.waitForReady = true
  return options
}
