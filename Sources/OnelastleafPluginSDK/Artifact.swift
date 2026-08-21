import Crypto
import Foundation
import OnelastleafPluginProtocol

extension ActionContext {
  /// Transfers an artifact from an asynchronous chunk source without retaining
  /// the complete payload in memory. Empty artifacts use a zero chunk count.
  public func storeArtifact<Chunks>(
    descriptor: Oll_Protocol_ArtifactDescriptor,
    chunkCount: UInt32,
    chunks: Chunks
  ) async throws -> Oll_Protocol_ArtifactStored
  where Chunks: AsyncSequence & Sendable, Chunks.Element == Data {
    try await scope.perform {
      try await transferArtifact(
        descriptor: descriptor,
        chunkCount: chunkCount,
        chunks: chunks
      )
    }
  }

  /// Convenience overload for payloads already split into in-memory chunks.
  public func storeArtifact(
    descriptor: Oll_Protocol_ArtifactDescriptor,
    chunks: [Data]
  ) async throws -> Oll_Protocol_ArtifactStored {
    guard let chunkCount = UInt32(exactly: chunks.count) else {
      throw PluginSDKError.invalidArgument("artifact has too many chunks")
    }
    return try await scope.perform {
      // In-memory payloads can be checked completely before oll allocates a
      // staging transfer. Streaming payloads are necessarily checked as read.
      try cancellation.checkActive()
      var verifier = try ArtifactVerifier(
        descriptor: descriptor,
        chunkCount: chunkCount,
        maximumChunkBytes: host.maximumArtifactChunkBytes
      )
      for chunk in chunks {
        try cancellation.checkActive()
        _ = try verifier.consume(chunk)
      }
      try verifier.finish()
      return try await transferArtifact(
        descriptor: descriptor,
        chunkCount: chunkCount,
        chunks: DataArraySequence(chunks: chunks)
      )
    }
  }

  private func transferArtifact<Chunks>(
    descriptor: Oll_Protocol_ArtifactDescriptor,
    chunkCount: UInt32,
    chunks: Chunks
  ) async throws -> Oll_Protocol_ArtifactStored
  where Chunks: AsyncSequence & Sendable, Chunks.Element == Data {
    try cancellation.checkActive()
    var verifier = try ArtifactVerifier(
      descriptor: descriptor,
      chunkCount: chunkCount,
      maximumChunkBytes: host.maximumArtifactChunkBytes
    )

    var start = Oll_Protocol_ArtifactTransferStart()
    var job = Oll_Protocol_PluginJobId()
    job.value = jobID
    start.jobID = job
    start.artifact = descriptor
    start.chunkCount = chunkCount
    switch try await host.request(payload: .artifactStart(start), trace: trace) {
    case .artifactAccepted(let accepted)
    where accepted.hasArtifactID && accepted.artifactID == descriptor.artifactID:
      break
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    default:
      throw PluginSDKError.protocolViolation(
        "host did not accept the artifact transfer"
      )
    }

    for try await data in chunks {
      try cancellation.checkActive()
      let index = try verifier.consume(data)

      var chunk = Oll_Protocol_ArtifactTransferChunk()
      chunk.artifactID = descriptor.artifactID
      chunk.chunkIndex = index
      chunk.data = data
      try host.sender.send(trace: trace, payload: .artifactChunk(chunk))
    }
    try verifier.finish()

    var complete = Oll_Protocol_ArtifactTransferComplete()
    complete.artifactID = descriptor.artifactID
    let stored: Oll_Protocol_ArtifactStored
    switch try await host.request(payload: .artifactComplete(complete), trace: trace) {
    case .artifactStored(let response)
    where response.hasArtifactID && response.artifactID == descriptor.artifactID:
      stored = response
    case .protocolError(let error):
      throw PluginSDKError.host(error)
    default:
      throw PluginSDKError.protocolViolation(
        "host did not confirm artifact storage"
      )
    }
    try scope.recordStoredArtifact(descriptor)
    return stored
  }
}

private struct ArtifactVerifier {
  private let descriptor: Oll_Protocol_ArtifactDescriptor
  private let chunkCount: UInt32
  private let maximumChunkBytes: UInt64
  private var index: UInt32 = 0
  private var size: UInt64 = 0
  private var sha256 = SHA256()

  init(
    descriptor: Oll_Protocol_ArtifactDescriptor,
    chunkCount: UInt32,
    maximumChunkBytes: UInt64
  ) throws {
    try validateArtifactDescriptor(descriptor)
    try validateArtifactChunkPlan(
      sizeBytes: descriptor.sizeBytes,
      chunkCount: chunkCount,
      maximumChunkBytes: maximumChunkBytes
    )
    self.descriptor = descriptor
    self.chunkCount = chunkCount
    self.maximumChunkBytes = maximumChunkBytes
  }

  mutating func consume(_ data: Data) throws -> UInt32 {
    guard index < chunkCount,
      !data.isEmpty,
      UInt64(data.count) <= maximumChunkBytes
    else {
      throw PluginSDKError.invalidArgument(
        "artifact chunks exceed their declared count or negotiated size"
      )
    }
    let (nextSize, sizeOverflow) = size.addingReportingOverflow(UInt64(data.count))
    guard !sizeOverflow, nextSize <= descriptor.sizeBytes else {
      throw PluginSDKError.invalidArgument(
        "artifact bytes exceed the declared size"
      )
    }
    let nextIndex = index + 1
    let remainingChunks = UInt64(chunkCount - nextIndex)
    let remainingBytes = descriptor.sizeBytes - nextSize
    let remainingCapacity = remainingChunks.multipliedReportingOverflow(
      by: maximumChunkBytes
    )
    guard remainingBytes >= remainingChunks,
      remainingCapacity.overflow || remainingBytes <= remainingCapacity.partialValue
    else {
      throw PluginSDKError.invalidArgument(
        "artifact chunk sizes cannot satisfy the declared size and count"
      )
    }

    let consumedIndex = index
    index = nextIndex
    size = nextSize
    sha256.update(data: data)
    return consumedIndex
  }

  mutating func finish() throws {
    guard index == chunkCount,
      size == descriptor.sizeBytes,
      Data(sha256.finalize()) == descriptor.sha256
    else {
      throw PluginSDKError.invalidArgument(
        "artifact chunk count, size, or SHA-256 does not match its descriptor"
      )
    }
  }
}

private struct DataArraySequence: AsyncSequence, Sendable {
  typealias Element = Data

  struct AsyncIterator: AsyncIteratorProtocol {
    private let chunks: [Data]
    private var index = 0

    init(chunks: [Data]) {
      self.chunks = chunks
    }

    mutating func next() async -> Data? {
      guard index < chunks.count else { return nil }
      defer { index += 1 }
      return chunks[index]
    }
  }

  let chunks: [Data]

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(chunks: chunks)
  }
}
