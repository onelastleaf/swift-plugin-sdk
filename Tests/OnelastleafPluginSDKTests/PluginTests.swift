import Testing

@testable import OnelastleafPluginSDK

@Test func validatesPluginIdentityAndActionRegistration() throws {
  #expect(throws: PluginSDKError.self) {
    try Plugin(id: "not-valid", version: "0.1.0")
  }

  let plugin = try Plugin(id: "org.example.echo", version: "0.1.0")
  try plugin.action(name: "echo", description: "Echo arguments") { _, arguments in
    .string(arguments.joined(separator: " "))
  }
  #expect(throws: PluginSDKError.self) {
    try plugin.action(name: "echo", description: "Duplicate") { _, _ in .string("") }
  }
}

@Test func pluginCannotBeReconfiguredOrRunTwice() throws {
  let plugin = try Plugin(id: "org.example.echo", version: "0.1.0")
  try plugin.action(name: "echo", description: "Echo arguments") { _, _ in .string("") }
  _ = try plugin.beginRun()

  #expect(throws: PluginSDKError.self) {
    try plugin.action(name: "late", description: "Too late") { _, _ in .string("") }
  }
  #expect(throws: PluginSDKError.self) {
    try plugin.beginRun()
  }
}

@Test func actionResultEncodesScalarValues() throws {
  #expect(ActionResult.string("hello").value?.stringValue == "hello")
  #expect(ActionResult.boolean(true).value?.boolValue == true)
  #expect(ActionResult.integer(42).value?.integerValue == 42)
  #expect(try ActionResult.number(3.5).value?.numberValue == 3.5)
  #expect(throws: PluginSDKError.self) { try ActionResult.number(.infinity) }
}

@Test func runtimeOverridesGrpcDefaultMessageLimits() {
  let options = pluginRuntimeCallOptions()
  #expect(options.maxRequestMessageBytes == Int.max)
  #expect(options.maxResponseMessageBytes == Int.max)
  #expect(options.waitForReady == true)
}

@Test func endpointRequiresAnExplicitLoopbackLiteral() throws {
  #expect(try PluginEndpoint.parse("http://127.0.0.1:1234").port == 1_234)
  #expect(try PluginEndpoint.parse("http://[::1]:4321").host == "::1")
  for invalid in [
    "https://127.0.0.1:1234",
    "http://localhost:1234",
    "http://127.0.0.1",
    "http://127.0.0.1:1234/path",
  ] {
    #expect(throws: PluginSDKError.self) { try PluginEndpoint.parse(invalid) }
  }
}
