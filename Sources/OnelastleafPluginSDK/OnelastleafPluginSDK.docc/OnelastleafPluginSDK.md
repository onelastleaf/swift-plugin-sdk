# ``OnelastleafPluginSDK``

Build a trusted onelastleaf plugin as a Swift executable while the SDK handles
the host protocol, concurrent jobs, cancellation, and artifact transfer.

## Overview

An onelastleaf plugin is a child process started and supervised by `oll`. The
host opens a loopback gRPC server, passes its address in
`OLL_PLUGIN_ENDPOINT`, and reserves the plugin's standard input as a liveness
pipe. Your executable creates one ``Plugin``, registers its actions, and calls
``Plugin/run()``. The SDK connects to the host and owns the protocol session
until shutdown.

Start with <doc:GettingStarted> to create a package and register your first
action. Continue with <doc:WritingActions> for concurrency, cancellation, and
results. <doc:UsingHostCapabilities> explains configuration, logging, and
document calls, while <doc:StoringArtifacts> covers verified output files.

The protocol request and response types are generated from onelastleaf's
canonical protobuf schema and re-exported by this module. Plugin code therefore
needs only `import OnelastleafPluginSDK`.

> Important: A plugin connects to an oll-owned server; it never opens its own
> gRPC listener. Do not read application data from standard input because EOF
> is the mandatory signal that the parent process has gone away.

## Topics

### Essentials

- <doc:GettingStarted>
- ``Plugin``
- ``Plugin/action(name:description:handler:)``
- ``Plugin/run()``

### Jobs and results

- <doc:WritingActions>
- ``ActionContext``
- ``ActionResult``
- ``CancellationToken``

### Host interaction

- <doc:UsingHostCapabilities>
- ``ActionContext/getConfig(_:)``
- ``ActionContext/invokeConfigFunction(_:arguments:)``
- ``ActionContext/hostCall(_:)``
- ``ActionContext/log(level:target:message:fields:)``

### Artifacts

- <doc:StoringArtifacts>
- ``ActionContext/storeArtifact(descriptor:chunks:)``
- ``ActionContext/storeArtifact(descriptor:chunkCount:chunks:)``
- ``ActionContext/maximumArtifactChunkBytes``

### Errors

- ``PluginSDKError``
