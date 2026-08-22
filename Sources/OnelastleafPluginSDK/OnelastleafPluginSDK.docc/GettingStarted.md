# Getting Started

Add the SDK to an executable package, register an action, and let oll start the
finished plugin.

## Add the package dependency

Use Swift 6.2 or newer. Add the published SDK tag and its library product to
your `Package.swift`:

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

The SwiftPM version remains `0.1.0` even though the Git tag is named
`v0.1.0`. Commit your plugin's `Package.resolved` when you need the entire
transitive dependency graph to remain reproducible.

## Create the executable entry point

Create `Sources/PluginMain/main.swift`, construct one ``Plugin``, and register
every action before starting the runtime:

```swift
import Foundation
import OnelastleafPluginSDK

do {
  let plugin = try Plugin(
    id: "com.example.my-plugin",
    version: "0.1.0"
  )

  try plugin.action(
    name: "echo",
    description: "Return the supplied arguments"
  ) { _, arguments in
    .string(arguments.joined(separator: " "))
  }

  try await plugin.run()
} catch {
  FileHandle.standardError.write(
    Data("plugin failed: \(error)\n".utf8)
  )
  exit(EXIT_FAILURE)
}
```

The plugin ID is its immutable identity. It must be a lower-case dotted DNS
name and must exactly match `plugin.id` in `oll.toml`. The version string is
informational; package installation and updates use the source recipe and
selected Git revision instead.

## Add the oll recipe

Place an `oll.toml` file at the plugin repository root. This minimal recipe
builds the release executable and installs it under oll's managed storage:

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

Keep the executable product name, build output name, installed filename, and
`runtime.argv` aligned.

## Build and run through oll

Build and test the plugin normally while developing:

```sh
swift build
swift test
```

Publish the plugin repository to a Git remote, then ask oll to install and run
it:

```sh
oll plugin install https://github.com/your-org/my-plugin.git --source
oll plugin start com.example.my-plugin
oll plugin call com.example.my-plugin echo -- hello from Swift
```

Do not launch the executable directly for normal use. ``Plugin/run()`` requires
the endpoint and liveness pipe that oll creates for a managed plugin process.

## Next steps

- Learn how handlers execute in <doc:WritingActions>.
- Read configuration and call the host in <doc:UsingHostCapabilities>.
- Return files safely with <doc:StoringArtifacts>.
