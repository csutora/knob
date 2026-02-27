import Foundation

/// Sample-time-indexed ring buffer for loopback audio.
///
/// Based on eqMac's approach: WriteMix accumulates audio at sample-time positions,
/// ReadInput reads from sample-time positions. The HAL calls ReadInput before
/// WriteMix in each IO cycle, so there's one cycle of inherent latency.
///
/// When backed by shared memory, the daemon can read directly from the buffer
/// without needing its own IO proc on the driver device (avoids mic permission).
final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    let ringSize: Int  // in frames
    let channelCount: Int
    private let ownsBuffer: Bool

    init(frameCapacity: Int, channelCount: Int) {
        self.ringSize = frameCapacity
        self.channelCount = channelCount
        let total = frameCapacity * channelCount
        self.buffer = .allocate(capacity: total)
        buffer.initialize(repeating: 0.0, count: total)
        self.ownsBuffer = true
    }

    /// Initialize with external storage (e.g. shared memory region).
    /// The caller is responsible for the lifetime of the buffer.
    init(externalBuffer: UnsafeMutablePointer<Float>, frameCapacity: Int, channelCount: Int) {
        self.buffer = externalBuffer
        self.ringSize = frameCapacity
        self.channelCount = channelCount
        self.ownsBuffer = false
        let total = frameCapacity * channelCount
        externalBuffer.initialize(repeating: 0.0, count: total)
    }

    deinit {
        if ownsBuffer { buffer.deallocate() }
    }

    /// Store audio from WriteMix. Accumulates (`+=`) to support multiple clients.
    /// Also pre-cleans buffer ahead to prevent stale data.
    func store(_ src: UnsafeRawPointer, frameCount: Int, sampleTime: Int) {
        let srcFloat = src.assumingMemoryBound(to: Float.self)
        let ch = channelCount

        for frame in 0..<frameCount {
            var pos = (sampleTime + frame) % ringSize
            if pos < 0 { pos += ringSize }
            let base = pos * ch
            for c in 0..<ch {
                buffer[base + c] += srcFloat[frame * ch + c]
            }
        }

        // Batch pre-clean: zero frameCount frames starting 8192 frames ahead
        var cleanStart = (sampleTime + 8192) % ringSize
        if cleanStart < 0 { cleanStart += ringSize }
        let bytesPerFrame = ch * MemoryLayout<Float>.size
        let firstChunk = min(frameCount, ringSize - cleanStart)
        memset(buffer.advanced(by: cleanStart * ch), 0, firstChunk * bytesPerFrame)
        if firstChunk < frameCount {
            let remaining = frameCount - firstChunk
            memset(buffer, 0, remaining * bytesPerFrame)
        }
    }

    /// Fetch audio for ReadInput.
    func fetch(_ dst: UnsafeMutableRawPointer, frameCount: Int, sampleTime: Int) {
        let dstFloat = dst.assumingMemoryBound(to: Float.self)
        let ch = channelCount
        let bytesPerFrame = ch * MemoryLayout<Float>.size

        // Handle negative sample times (Swift % preserves sign)
        var pos = sampleTime % ringSize
        if pos < 0 { pos += ringSize }

        let firstChunk = min(frameCount, ringSize - pos)
        memcpy(dstFloat, buffer.advanced(by: pos * ch), firstChunk * bytesPerFrame)
        if firstChunk < frameCount {
            let remaining = frameCount - firstChunk
            memcpy(dstFloat.advanced(by: firstChunk * ch), buffer, remaining * bytesPerFrame)
        }
    }

    func reset() {
        let total = ringSize * channelCount
        buffer.initialize(repeating: 0.0, count: total)
    }
}
