# Writing Actions

Design action handlers that return structured results and cooperate with
concurrent execution, deadlines, and cancellation.

## Understand one invocation

Each call to a registered action becomes an independent job. The handler
receives an ``ActionContext`` for that job and an ordered array of strings.
oll preserves duplicate arguments, empty arguments, and values beginning with
`-`; do not parse them as process flags unless that is part of your action's
own interface.

Several handlers can run concurrently in one plugin process. Prefer immutable
captured values, actors, or another synchronization mechanism for shared
mutable state. Throwing from one handler fails only that job and does not stop
unrelated jobs.

```swift
try plugin.action(
  name: "count",
  description: "Count the supplied arguments"
) { context, arguments in
  try context.cancellation.checkCancellation()
  try await context.log(
    level: .info,
    target: "count",
    message: "counting arguments",
    fields: [:]
  )
  return .integer(Int64(arguments.count))
}
```

## Return a value

``ActionResult`` provides convenience constructors for strings, Booleans,
signed 64-bit integers, finite floating-point numbers, and bytes:

```swift
return .string("done")
return .boolean(true)
return .integer(42)
return try .number(3.14)
return .bytes(data)
```

Use the full initializer when returning a generated `Oll_Protocol_ConfigValue`
or descriptors for artifacts already stored through the same context. A
floating-point result cannot be NaN or infinity. Structured values also have
protocol limits for nesting and protobuf timestamp and duration ranges; the SDK
validates them before sending the terminal job update.

## Cooperate with cancellation

oll may cancel a job because a user requested it or its deadline expired. The
SDK cancels that job's Swift task and updates ``CancellationToken``. Check the
token in long loops and before expensive or externally visible operations:

```swift
for argument in arguments {
  try context.cancellation.checkCancellation()
  try await process(argument)
}
```

Use ``CancellationToken/isCancelled`` when cleanup code needs a nonthrowing
branch. Otherwise, ``CancellationToken/checkCancellation()`` is less likely to
let work continue accidentally. Host calls and artifact operations also reject
new output after the handler settles or cancellation begins.

``ActionContext/deadline`` contains the absolute deadline supplied by oll, when
one exists. Treat it as information for planning work; cancellation remains the
authoritative signal to stop.

## Report failures intentionally

Throw an ordinary error when the action cannot complete. The SDK converts it
into a failed terminal update for that job. ``PluginSDKError`` identifies
failures detected by the SDK itself, such as invalid arguments, rejected host
calls, and protocol violations.

Avoid catching cancellation and returning success. If cleanup is necessary,
perform it with `defer` or a narrow `catch`, then rethrow `CancellationError` so
oll observes the correct job outcome.
