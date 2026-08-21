import Foundation
import Synchronization
import Testing

@testable import OnelastleafPluginSDK

@Test func parentLivenessReadsIncrementallyAndCompletesOnlyAtEOF() async throws {
  let pipe = Pipe()
  let monitor = ParentLivenessMonitor(input: pipe.fileHandleForReading)
  let completed = Mutex(false)
  let waiter = Task {
    try await monitor.waitForEOF()
    completed.withLock { $0 = true }
  }

  try pipe.fileHandleForWriting.write(contentsOf: Data("still-alive".utf8))
  try await Task.sleep(for: .milliseconds(25))
  #expect(!completed.withLock { $0 })

  try pipe.fileHandleForWriting.close()
  try await withTimeout { try await waiter.value }
  #expect(completed.withLock { $0 })
  monitor.stop()
  try pipe.fileHandleForReading.close()
}
