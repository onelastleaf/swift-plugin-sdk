# Using Host Capabilities

Read live configuration, invoke session-scoped configuration functions, emit
structured logs, and request permitted document operations from an action.

## Read authoritative configuration

Plugin configuration belongs to oll. ``ActionContext/getConfig(_:)`` reads it
when the action needs it; the SDK does not copy configuration into a plugin
file or keep a stale cache.

An empty path reads the configuration root:

```swift
let response = try await context.getConfig()
let rootValue = response.value
```

To read a nested value, build an `Oll_Protocol_ConfigPath` from generated path
segments. List indexes at this protocol boundary are zero-based. Validate the
returned `Oll_Protocol_ConfigValue` kind before using its corresponding value.

## Invoke a configuration function

A configuration value may contain an `Oll_Protocol_ConfigFunctionRef`. It is a
host-owned reference to a closure that remains inside oll's Lua runtime:

```swift
let response = try await context.invokeConfigFunction(
  function,
  arguments: arguments
)
```

The reference is valid only in the session that returned it. Never serialize,
persist, or reuse it after the plugin reconnects. Function arguments may contain
other function references only when they belong to that same session.

## Emit structured logs

Use ``ActionContext/log(level:target:message:fields:)`` instead of writing
operational events to standard output. oll adds job correlation through the
current trace and routes the record with the plugin's logs:

```swift
var path = Oll_Protocol_ConfigValue()
path.stringValue = "/notes/today.md"

try await context.log(
  level: .info,
  target: "document-import",
  message: "reading document",
  fields: ["path": path]
)
```

The level must be known, the target must be nonempty, and field values must be
serializable. Log fields cannot contain configuration function references.

## Make document and CRDT calls

``ActionContext/hostCall(_:)`` is the typed low-level entry point for permitted
host capabilities such as reading a document, listing a directory, reading a
CRDT projection, or committing document operations. Construct the appropriate
generated request and pass its one-of variant:

```swift
var path = Oll_Protocol_DocumentPath()
path.value = "/notes/today.md"

var request = Oll_Protocol_ReadDocumentRequest()
request.path = path
request.projection = .content

let response = try await context.hostCall(.readDocument(request))
guard case .readDocument(let document)? = response.result else {
  throw PluginSDKError.protocolViolation("missing read-document result")
}
```

The SDK preserves tracing, enforces the negotiated call-depth limit, validates
the response kind, and surfaces a host rejection as
``PluginSDKError/host(_:)``. A plugin can request only capabilities exposed by
the canonical protocol; it cannot upload arbitrary input files or download
host artifacts through an invented side channel.
