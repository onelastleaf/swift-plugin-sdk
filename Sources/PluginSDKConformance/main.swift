import Foundation
import OnelastleafPluginSDK

@main
struct Conformance {
  static func main() async {
    do {
      let plugin = try Plugin(id: "org.onelastleaf.conformance", version: "0.1.0")
      try plugin.action(name: "echo", description: "Echo arguments") { _, arguments in
        .string(arguments.joined(separator: " "))
      }
      try plugin.action(name: "wait", description: "Wait for cancellation") {
        context, _ in
        while !(await context.cancellation.isCancelled) {
          try await Task.sleep(for: .milliseconds(1))
        }
        try await context.cancellation.checkCancellation()
        return ActionResult()
      }
      try plugin.action(name: "host", description: "Exercise host capabilities") {
        context, _ in
        let configured = try await context.getConfig()
        guard case .functionValue(let function)? = configured.value.kind else {
          throw ConformanceError.invalidResponse("GetConfig omitted function")
        }
        var argument = Oll_Protocol_ConfigValue()
        argument.stringValue = "config"
        let invoked = try await context.invokeConfigFunction(
          function,
          arguments: [argument]
        )
        guard invoked.results.count == 1,
          case .stringValue(let functionResult)? = invoked.results[0].kind
        else {
          throw ConformanceError.invalidResponse(
            "configuration function omitted string result"
          )
        }
        var path = Oll_Protocol_DocumentPath()
        path.value = "/conformance.md"
        var request = Oll_Protocol_ReadDocumentRequest()
        request.path = path
        request.projection = .content
        let response = try await context.hostCall(.readDocument(request))
        guard case .readDocument(let read)? = response.result,
          read.hasDocument,
          case .content(let document)? = read.document.representation
        else {
          throw ConformanceError.invalidResponse(
            "document call omitted text content"
          )
        }
        try await context.log(
          level: .info,
          target: "conformance",
          message: "host action complete"
        )
        return .string("\(functionResult)|\(document)")
      }
      try plugin.action(name: "artifact", description: "Exercise artifact transfer") {
        context, _ in
        var artifactID = Oll_Protocol_PluginArtifactId()
        artifactID.value = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        var descriptor = Oll_Protocol_ArtifactDescriptor()
        descriptor.artifactID = artifactID
        descriptor.fileName = "conformance.txt"
        descriptor.mediaType = "text/plain"
        descriptor.sizeBytes = 16
        descriptor.sha256 = Data([
          0xa1, 0x1a, 0x40, 0x45, 0xc8, 0x9f, 0x72, 0x7f,
          0xad, 0xb9, 0xae, 0xdd, 0xb0, 0xf2, 0x96, 0x37,
          0xce, 0x5b, 0x50, 0x58, 0x46, 0xaf, 0xeb, 0xd8,
          0x2a, 0xe2, 0xc0, 0x1b, 0x67, 0x33, 0xa6, 0xb5,
        ])
        _ = try await context.storeArtifact(
          descriptor: descriptor,
          chunks: [Data("artifact ".utf8), Data("payload".utf8)]
        )
        return ActionResult(
          value: ActionResult.string("artifact").value,
          artifacts: [descriptor]
        )
      }
      try await plugin.run()
    } catch {
      FileHandle.standardError.write(Data("plugin failed: \(error)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}

enum ConformanceError: Error {
  case invalidResponse(String)
}
