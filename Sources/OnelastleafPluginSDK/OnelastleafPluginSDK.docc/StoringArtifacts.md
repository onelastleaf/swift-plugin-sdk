# Storing Artifacts

Transfer a job's output to oll with explicit metadata, bounded chunks, and
end-to-end integrity verification.

## Describe the complete artifact

Before sending bytes, create an `Oll_Protocol_ArtifactDescriptor` containing:

- A plugin-generated canonical, lower-case UUID v4 artifact ID.
- A safe base filename with no slash, NUL byte, `.` value, or `..` value.
- A nonempty media type.
- The exact total byte count.
- The exact 32-byte SHA-256 digest of the complete payload.

The artifact ID must be unique within the deployment. The descriptor is an
identity: after oll stores it, return the exact same fields in
``ActionResult/artifacts``.

## Store an in-memory payload

Use ``ActionContext/storeArtifact(descriptor:chunks:)`` when the payload is
already divided into reasonably sized `Data` values. The following helper
takes a digest computed by the caller:

```swift
func storeOutput(
  _ payload: Data,
  sha256: Data,
  context: ActionContext
) async throws -> ActionResult {
  var artifactID = Oll_Protocol_PluginArtifactId()
  artifactID.value = UUID().uuidString.lowercased()

  var descriptor = Oll_Protocol_ArtifactDescriptor()
  descriptor.artifactID = artifactID
  descriptor.fileName = "result.bin"
  descriptor.mediaType = "application/octet-stream"
  descriptor.sizeBytes = UInt64(payload.count)
  descriptor.sha256 = sha256

  let chunks = payload.isEmpty ? [] : [payload]
  _ = try await context.storeArtifact(
    descriptor: descriptor,
    chunks: chunks
  )
  return ActionResult(artifacts: [descriptor])
}
```

Before using one chunk for a nonempty artifact, make sure the payload fits
``ActionContext/maximumArtifactChunkBytes``. Split larger payloads into smaller
nonempty chunks.

## Stream a large payload

Use ``ActionContext/storeArtifact(descriptor:chunkCount:chunks:)`` for a file,
encoder, or other source that can produce data incrementally. Supply the exact
number of elements the asynchronous sequence will yield. Every nonempty chunk
must fit the negotiated limit; an empty artifact declares zero chunks and
yields nothing.

The SDK checks cancellation between chunks and verifies the declared count,
total size, and SHA-256 digest while consuming the sequence. This keeps memory
bounded by the producer's buffering instead of the complete artifact size.

## Return only acknowledged artifacts

Artifact transfer has a host-owned staging phase. A successful store method
means oll accepted the start, received and verified the chunks, and confirmed
storage. Only then should the action include the descriptor in its result.

If transfer throws, do not return that descriptor. Likewise, changing its
filename, media type, size, digest, or ID after storage makes it a different
descriptor and oll rejects the terminal result.
