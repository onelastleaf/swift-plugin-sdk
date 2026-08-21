import Foundation
import OnelastleafPluginProtocol
import SwiftProtobuf

let maximumConfigValueDepth = 33
let sha256ByteCount = 32
private let maximumIdentityBytes = 191
private let maximumDNSLabelBytes = 63
private let protobufTimestampMinimumSeconds: Int64 = -62_135_596_800
private let protobufTimestampMaximumSeconds: Int64 = 253_402_300_799
private let protobufDurationMaximumSeconds: Int64 = 315_576_000_000
private let maximumNanoseconds: Int32 = 999_999_999

enum ConfigValuePolicy: Sendable {
  case serializable
  case functionArguments(sessionID: String)
}

func validateConfigValue(
  _ value: Oll_Protocol_ConfigValue,
  policy: ConfigValuePolicy,
  depth: Int = 0
) throws {
  guard depth <= maximumConfigValueDepth else {
    throw PluginSDKError.invalidArgument(
      "ConfigValue nesting exceeds the supported limit"
    )
  }
  guard let kind = value.kind else {
    throw PluginSDKError.invalidArgument("ConfigValue kind is required")
  }
  switch kind {
  case .nullValue(.nullValue), .boolValue, .integerValue, .stringValue, .bytesValue:
    return
  case .nullValue:
    throw PluginSDKError.invalidArgument("ConfigValue contains an unknown null value")
  case .numberValue(let number):
    guard number.isFinite else {
      throw PluginSDKError.invalidArgument("ConfigValue numbers must be finite")
    }
  case .listValue(let list):
    for child in list.values {
      try validateConfigValue(child, policy: policy, depth: depth + 1)
    }
  case .mapValue(let map):
    for child in map.entries.values {
      try validateConfigValue(child, policy: policy, depth: depth + 1)
    }
  case .functionValue(let function):
    switch policy {
    case .serializable:
      throw PluginSDKError.invalidArgument(
        "session-scoped configuration functions cannot be stored or logged"
      )
    case .functionArguments(let sessionID):
      guard function.sessionID == sessionID else {
        throw PluginSDKError.invalidArgument(
          "configuration function belongs to another plugin session"
        )
      }
      guard !function.functionID.isEmpty else {
        throw PluginSDKError.invalidArgument(
          "configuration function ID must not be empty"
        )
      }
    }
  case .timestampValue(let timestamp):
    try validateTimestamp(timestamp, field: "ConfigValue timestamp")
  case .durationValue(let duration):
    guard
      (-protobufDurationMaximumSeconds...protobufDurationMaximumSeconds)
        .contains(duration.seconds),
      (-maximumNanoseconds...maximumNanoseconds).contains(duration.nanos),
      !(duration.seconds > 0 && duration.nanos < 0),
      !(duration.seconds < 0 && duration.nanos > 0)
    else {
      throw PluginSDKError.invalidArgument(
        "ConfigValue duration is outside the protobuf Duration domain"
      )
    }
  }
}

func validateTimestamp(
  _ timestamp: Google_Protobuf_Timestamp,
  field: String
) throws {
  guard
    (protobufTimestampMinimumSeconds...protobufTimestampMaximumSeconds)
      .contains(timestamp.seconds),
    (0...maximumNanoseconds).contains(timestamp.nanos)
  else {
    throw PluginSDKError.invalidArgument(
      "\(field) is outside the protobuf Timestamp domain"
    )
  }
}

func validatePluginID(_ value: String) throws {
  let labels = value.split(separator: ".", omittingEmptySubsequences: false)
  guard value.utf8.count <= maximumIdentityBytes,
    labels.count >= 2,
    labels.allSatisfy(validDNSLabel)
  else {
    throw PluginSDKError.invalidArgument(
      "plugin ID must be a lower-case dotted DNS name"
    )
  }
}

func isValidDNSLabel(_ value: String) -> Bool {
  validDNSLabel(value[...])
}

func isCanonicalUUIDv4(_ value: String) -> Bool {
  guard value.utf8.count == 36,
    UUID(uuidString: value)?.uuidString.lowercased() == value
  else { return false }
  let version = value.index(value.startIndex, offsetBy: 14)
  let variant = value.index(value.startIndex, offsetBy: 19)
  return value[version] == "4" && "89ab".contains(value[variant])
}

func validateArtifactDescriptor(_ descriptor: Oll_Protocol_ArtifactDescriptor) throws {
  let fileNameBytes = descriptor.fileName.utf8
  guard descriptor.hasArtifactID,
    isCanonicalUUIDv4(descriptor.artifactID.value),
    !fileNameBytes.isEmpty,
    fileNameBytes.count <= maximumIdentityBytes,
    descriptor.fileName != ".",
    descriptor.fileName != "..",
    !fileNameBytes.contains(0),
    !descriptor.fileName.contains("/"),
    !descriptor.mediaType.isEmpty,
    descriptor.sha256.count == sha256ByteCount
  else {
    throw PluginSDKError.invalidArgument("artifact descriptor is invalid")
  }
}

func validateArtifactChunkPlan(
  sizeBytes: UInt64,
  chunkCount: UInt32,
  maximumChunkBytes: UInt64
) throws {
  if sizeBytes == 0 {
    guard chunkCount == 0 else {
      throw PluginSDKError.invalidArgument(
        "an empty artifact must declare zero chunks"
      )
    }
    return
  }
  let capacity = UInt64(chunkCount).multipliedReportingOverflow(by: maximumChunkBytes)
  guard chunkCount > 0,
    UInt64(chunkCount) <= sizeBytes,
    capacity.overflow || sizeBytes <= capacity.partialValue
  else {
    throw PluginSDKError.invalidArgument(
      "artifact chunk count cannot represent the declared size"
    )
  }
}

private func validDNSLabel(_ value: Substring) -> Bool {
  let bytes = Array(value.utf8)
  guard !bytes.isEmpty, bytes.count <= maximumDNSLabelBytes,
    isLowercaseLetterOrDigit(bytes[0]),
    isLowercaseLetterOrDigit(bytes[bytes.count - 1])
  else { return false }
  return bytes.allSatisfy { isLowercaseLetterOrDigit($0) || $0 == 45 }
}

private func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
  (97...122).contains(byte) || (48...57).contains(byte)
}
