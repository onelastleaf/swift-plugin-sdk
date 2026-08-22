import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

@Test func readmeChecksOutThePublishedVersionTagExplicitly() throws {
  let readme = try String(
    contentsOf: repositoryRoot.appending(path: "README.md"),
    encoding: .utf8
  )

  #expect(readme.contains("git switch --detach refs/tags/v0.1.0"))
  #expect(!readme.contains("git clone --branch"))
}

@Test func swiftPackageIndexBuildsTheSDKDocumentationWithoutAPackagePlugin() throws {
  let manifest = try String(
    contentsOf: repositoryRoot.appending(path: ".spi.yml"),
    encoding: .utf8
  )
  let package = try String(
    contentsOf: repositoryRoot.appending(path: "Package.swift"),
    encoding: .utf8
  )

  #expect(manifest.contains("documentation_targets: [OnelastleafPluginSDK]"))
  #expect(!package.contains("swift-docc-plugin"))
}

@Test func continuousIntegrationUsesANode24SwiftSetupActionAndSupportedVersion() throws {
  let workflow = try String(
    contentsOf: repositoryRoot.appending(path: ".github/workflows/ci.yml"),
    encoding: .utf8
  )

  #expect(workflow.contains("SwiftyLab/setup-swift@v1.14.0"))
  #expect(workflow.contains("- \"6.2.0\""))
  #expect(workflow.contains("- \"6.2.1\""))
  #expect(!workflow.contains("swift-actions/setup-swift"))
  #expect(!workflow.contains("6.3.3"))
}
