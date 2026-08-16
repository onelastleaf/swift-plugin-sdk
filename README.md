# onelastleaf Swift plugin SDK

The Swift concurrency and gRPC runtime for trusted onelastleaf process plugins.
The SwiftPM product is `OnelastleafPluginSDK`.

```swift
import OnelastleafPluginSDK

let plugin = try Plugin(id: "org.example.echo", version: "0.1.0")
    .action(name: "echo", description: "Echo arguments") { _, arguments in
        .string(arguments.joined(separator: " "))
    }

try await plugin.run()
```

The SDK owns the gRPC stream, exact schema handshake, bounded 64 MiB envelope
limit, message sequencing, concurrent jobs, cooperative cancellation, host
calls, artifacts, heartbeats, shutdown acknowledgement, and stdin parent
liveness. Action code receives those capabilities through `ActionContext`.
