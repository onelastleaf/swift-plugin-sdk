# onelastleaf Swift plugin SDK

Build trusted [onelastleaf](https://github.com/onelastleaf/onelastleaf) plugins
in Swift with Swift concurrency and gRPC. The SwiftPM library product is
`OnelastleafPluginSDK`.

The SDK takes care of the protocol machinery—handshake, message ordering,
concurrent jobs, cancellation, host calls, artifacts, heartbeats, and graceful
shutdown—so plugin code can stay focused on its actions.

## Requirements

- Swift 6.2 or newer
- macOS 15 or newer when building for macOS

The SDK and generated projects fetch dependencies from their authoritative
remote repositories. You do not need a local checkout of the SDK to build a
plugin. The SDK package declares Swift tools 6.2 because its current
SwiftProtobuf dependency requires that toolchain. A generated plugin may still
declare Swift tools 6.0, but SwiftPM must itself run under Swift 6.2 or newer to
resolve and build the complete dependency graph.

## Build and test the SDK

Clone the official repository, check out the published `v0.1.0` tag in detached
HEAD state, then use the usual SwiftPM commands:

```sh
git clone https://github.com/onelastleaf/swift-plugin-sdk.git
cd swift-plugin-sdk
git switch --detach refs/tags/v0.1.0
swift build
swift test
```

`swift build -c release` produces an optimized build. The
`PluginSDKConformance` executable in this repository is for the onelastleaf
protocol conformance suite; it is not a standalone plugin demo.

## Start a plugin project

If `oll` is already installed, the shortest path is its project generator:

```sh
oll plugin new my-plugin \
  --language swift \
  --id com.example.my-plugin \
  --name my-plugin
cd my-plugin
swift build
swift test
```

The generated project includes an executable target, an `echo` action, tests,
and the `oll.toml` recipe used to build and launch the plugin. Its
`Package.swift` pins the SDK release directly from the official repository; it
does not rely on a local path.

### Add the SDK to an existing Swift package

For an existing executable package, add the official repository and pin the
release exactly:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "my-plugin",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "my-plugin", targets: ["PluginMain"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/onelastleaf/swift-plugin-sdk.git",
      exact: "0.1.0"
    )
  ],
  targets: [
    .executableTarget(
      name: "PluginMain",
      dependencies: [
        .product(
          name: "OnelastleafPluginSDK",
          package: "swift-plugin-sdk"
        )
      ]
    )
  ]
)
```

Then register one or more actions in the executable entry point:

```swift
import Foundation
import OnelastleafPluginSDK

do {
  let plugin = try Plugin(id: "com.example.my-plugin", version: "0.1.0")
    .action(name: "echo", description: "Return the supplied arguments") {
      _, arguments in
      .string(arguments.joined(separator: " "))
    }

  try await plugin.run()
} catch {
  FileHandle.standardError.write(Data("plugin failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
```

The ID passed to `Plugin` is immutable and must match `plugin.id` in
`oll.toml`. It must be a lower-case dotted DNS name with at least two labels
and no more than 191 UTF-8 bytes. A label may contain an internal hyphen, but it
must begin and end with a letter or digit. Action names must be nonempty and
unique within the plugin.

## Connect the project to oll

A plugin is not a server and normally should not be launched by hand. `oll`
starts the executable, hosts a loopback gRPC server on an ephemeral port, and
passes that address in `OLL_PLUGIN_ENDPOINT`. It also uses the plugin's stdin
as a parent-liveness pipe; when stdin reaches EOF, the plugin exits.

For a hand-written project, add this `oll.toml` at the repository root. Replace
the example ID and name, and keep the ID identical to the one in Swift code:

```toml
format_version = 1

[plugin]
id = "com.example.my-plugin"
name = "my-plugin"

[source]
checkout = "source"
steps = [
  ["swift", "build", "--package-path", "{source}", "--configuration", "release", "--scratch-path", "{source}/build"],
  ["install", "-m", "755", "{source}/build/release/my-plugin", "{install}/my-plugin"],
]

[source.dependencies]
"swift" = "Install Swift and ensure swift is in PATH."
"install" = "Install a POSIX install utility and ensure it is in PATH."

[runtime]
argv = ["{install}/my-plugin"]
```

This SDK follows the canonical protobuf wire contract. It never computes,
embeds, publishes, or compares a schema hash or fingerprint. Descriptor-wide
hashes change for compatible additions and unrelated services, so they reject
valid peers. Protocol changes instead preserve field numbers and wire types,
give additions safe absent semantics, and tolerate unknown fields. An exact SDK
pin fixes the SDK sources; commit your plugin's `Package.resolved` as well when
you need the complete transitive graph fixed. Neither is protobuf API
versioning.

Publish the plugin project to a Git remote that contains `Package.swift`,
`oll.toml`, and its sources. Install it from that remote, then start and call
it through `oll`:

```sh
oll plugin install https://github.com/your-org/my-plugin.git --source
oll plugin start com.example.my-plugin
oll plugin call com.example.my-plugin echo -- hello from Swift
```

`plugin install` reads `oll.toml`, checks the declared tools, builds the
selected source revision, and publishes the executable into oll's managed
plugin storage. A new installation starts in the stopped state, which is why
`plugin start` is a separate step.

To install a reproducible source revision, select it explicitly:

```sh
oll plugin install https://github.com/your-org/my-plugin.git \
  --rev <commit-or-tag> --source
```

## Write useful actions

An action receives an `ActionContext` and its ordered string arguments. Return
an `ActionResult`, or throw an error to fail the job.

Convenience constructors cover common result values:

```swift
return .string("done")
return .boolean(true)
return .integer(42)
return try .number(3.14)
return .bytes(data)
```

Long-running actions should cooperate with job cancellation:

```swift
try plugin.action(name: "work", description: "Do cancellable work") {
  context, arguments in

  for argument in arguments {
    try context.cancellation.checkCancellation()
    // Process argument.
  }

  return .string("done")
}
```

`ActionContext` also exposes the capabilities supplied by the host:

- `getConfig(_:)` reads the plugin's current host-owned configuration.
- `invokeConfigFunction(_:arguments:)` invokes a configuration function by
  its session-bound reference.
- `hostCall(_:)` makes a permitted document or other host capability call.
- `log(level:target:message:fields:)` emits a structured, job-correlated log.
- `storeArtifact(descriptor:chunks:)` transfers a verified job artifact.

For a large artifact, use the streaming overload instead of collecting every
chunk in an array first:

```swift
let stored = try await context.storeArtifact(
  descriptor: descriptor,
  chunkCount: expectedChunkCount,
  chunks: chunkStream
)
```

`chunkStream` can be any `Sendable` `AsyncSequence` of `Data`. Its count must
match the declaration, every nonempty chunk must fit the limit advertised by
oll, and the final size and SHA-256 must match the descriptor. Empty artifacts
are valid with both size and chunk count set to zero. An action result may list
only the exact descriptors oll already confirmed as stored for that job.

The generated protocol types are re-exported by `OnelastleafPluginSDK`, so the
request and response types used by these APIs are available from the same
import.

## A few runtime rules worth knowing

- Let `Plugin.run()` own the connection for the lifetime of the process.
- Register all actions before calling `run()`, and run each `Plugin` instance
  only once.
- Do not read application input from stdin; oll reserves it for parent
  liveness.
- Do not open a plugin gRPC server. The SDK connects to the oll-owned endpoint.
- Do not cache plugin configuration as a file. Ask the host with `getConfig`
  when the action needs it.
- Check cancellation in long loops or before expensive work. Cancelling one
  job must not stop unrelated jobs in the same process.
- Structured result and log values must be finite, stay inside the protobuf
  timestamp and duration domains and the 33-level nesting limit, and must not
  contain session-scoped function handles. The SDK checks these rules before
  sending them.

The plugin protocol has no encoded-envelope size cap. This SDK sets
grpc-swift's send and receive limits to `Int.max`, avoiding its smaller default.
Artifacts still use oll's advertised chunk limit and should go through
`storeArtifact` rather than being packed into one large envelope.

## API documentation

The [versioned API documentation](https://swiftpackageindex.com/onelastleaf/swift-plugin-sdk/documentation)
is built and hosted by the Swift Package Index. Start with the getting-started
guide there, then use the symbol pages for lifecycle, cancellation, host calls,
and artifact details.

The repository contains a native DocC catalog and tells the Swift Package Index
to build the `OnelastleafPluginSDK` target through `.spi.yml`. The package does
not add `swift-docc-plugin` as a dependency; the index's build system supplies
the documentation tooling.

## Troubleshooting

`OLL_PLUGIN_ENDPOINT is required` usually means the executable was started
directly. Install and start the repository through `oll` so the runtime
environment and stdin liveness pipe are created correctly.

If installation cannot find the built executable, make sure the executable
product name in `Package.swift`, the release binary path in `source.steps`, and
the filename in `runtime.argv` are all the same.

## License

`swift-plugin-sdk` is licensed under the GNU General Public License, version 3
or (at your option) any later version (`GPL-3.0-or-later`). See [LICENSE](LICENSE)
for the complete terms.
