#!/usr/bin/env swift
import Foundation

private struct SymbolGraph: Decodable {
  struct Symbol: Decodable {
    struct DocComment: Decodable {
      struct Line: Decodable {
        let text: String
      }

      let lines: [Line]
    }

    let accessLevel: String
    let pathComponents: [String]
    let docComment: DocComment?

    var hasDocumentation: Bool {
      docComment?.lines.contains {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      } == true
    }
  }

  let symbols: [Symbol]
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(
    Data("usage: check-public-api-docs.swift <symbol-graph.json>\n".utf8)
  )
  exit(EXIT_FAILURE)
}

do {
  let graphURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let graph = try JSONDecoder().decode(
    SymbolGraph.self,
    from: Data(contentsOf: graphURL)
  )
  let publicSymbols = graph.symbols.filter { $0.accessLevel == "public" }
  let undocumented = publicSymbols.filter { !$0.hasDocumentation }

  guard undocumented.isEmpty else {
    let names =
      undocumented
      .map { $0.pathComponents.joined(separator: ".") }
      .sorted()
      .joined(separator: "\n  - ")
    FileHandle.standardError.write(
      Data("undocumented public API:\n  - \(names)\n".utf8)
    )
    exit(EXIT_FAILURE)
  }

  print("Documented public API symbols: \(publicSymbols.count)/\(publicSymbols.count)")
} catch {
  FileHandle.standardError.write(
    Data("unable to check public API documentation: \(error)\n".utf8)
  )
  exit(EXIT_FAILURE)
}
