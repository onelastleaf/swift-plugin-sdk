import Foundation
import SwiftProtobuf
import Testing

@testable import OnelastleafPluginSDK

@Test func configValueValidationMatchesTheCanonicalDepthAndScalarRules() throws {
  var finite = Oll_Protocol_ConfigValue()
  finite.numberValue = 1.5
  try validateConfigValue(finite, policy: .serializable)

  var nonfinite = Oll_Protocol_ConfigValue()
  nonfinite.numberValue = .nan
  #expect(throws: PluginSDKError.self) {
    try validateConfigValue(nonfinite, policy: .serializable)
  }

  var nested = finite
  for _ in 0...maximumConfigValueDepth {
    var list = Oll_Protocol_ConfigList()
    list.values = [nested]
    nested = Oll_Protocol_ConfigValue()
    nested.listValue = list
  }
  #expect(throws: PluginSDKError.self) {
    try validateConfigValue(nested, policy: .serializable)
  }

  var invalidDuration = Google_Protobuf_Duration()
  invalidDuration.seconds = 1
  invalidDuration.nanos = -1
  var durationValue = Oll_Protocol_ConfigValue()
  durationValue.durationValue = invalidDuration
  #expect(throws: PluginSDKError.self) {
    try validateConfigValue(durationValue, policy: .serializable)
  }
}

@Test func functionHandlesAreSessionScopedAndNotDurable() throws {
  var function = Oll_Protocol_ConfigFunctionRef()
  function.sessionID = testSessionID
  function.functionID = "function"
  var value = Oll_Protocol_ConfigValue()
  value.functionValue = function

  try validateConfigValue(value, policy: .functionArguments(sessionID: testSessionID))
  #expect(throws: PluginSDKError.self) {
    try validateConfigValue(value, policy: .serializable)
  }
  #expect(throws: PluginSDKError.self) {
    try validateConfigValue(value, policy: .functionArguments(sessionID: "other-session"))
  }
}

@Test func emptyArtifactHasOneCanonicalChunkPlan() throws {
  try validateArtifactChunkPlan(sizeBytes: 0, chunkCount: 0, maximumChunkBytes: 1_024)
  #expect(throws: PluginSDKError.self) {
    try validateArtifactChunkPlan(sizeBytes: 0, chunkCount: 1, maximumChunkBytes: 1_024)
  }
  #expect(throws: PluginSDKError.self) {
    try validateArtifactChunkPlan(sizeBytes: 2_049, chunkCount: 2, maximumChunkBytes: 1_024)
  }
}

@Test func canonicalUUIDValidationRejectsAlternateSpellingsAndVersions() {
  #expect(isCanonicalUUIDv4("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
  #expect(!isCanonicalUUIDv4("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
  #expect(!isCanonicalUUIDv4("aaaaaaaa-aaaa-3aaa-8aaa-aaaaaaaaaaaa"))
  #expect(!isCanonicalUUIDv4("not-a-uuid"))
}
