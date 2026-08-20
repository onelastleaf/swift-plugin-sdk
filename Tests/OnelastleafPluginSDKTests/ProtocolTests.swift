import Foundation
import Testing

@testable import OnelastleafPluginSDK

@Test func validatesPluginIdentityAndActions() throws {
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

@Test func actionResultEncodesStrings() {
  let result = ActionResult.string("hello")
  #expect(result.value?.stringValue == "hello")
}
