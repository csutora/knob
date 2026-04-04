import Foundation
import EQCore

/// Fixed-size filter bank for real-time audio processing.
/// All memory is pre-allocated — no heap activity in the audio callback.
struct FilterBank {
    private let filters: UnsafeMutablePointer<BiquadFilter>
    private let maxBands: Int
    var bandCount: Int = 0
    var preampGainLinear: Float = 1.0
    var enabled: Bool = true

    init(maxBands: Int = EQConstants.maxBands) {
        self.maxBands = maxBands
        self.filters = .allocate(capacity: maxBands)
        self.filters.initialize(repeating: BiquadFilter(), count: maxBands)
    }

    /// Recalculate coefficients from a preset. Called from the main thread.
    mutating func configure(from preset: Preset, sampleRate: Double) {
        let count = min(preset.bands.count, maxBands)
        bandCount = count
        preampGainLinear = Float(pow(10.0, preset.preampGainDB / 20.0))

        for i in 0..<count {
            let band = preset.bands[i]
            filters[i].coefficients = BiquadCoefficients.compute(
                type: band.type,
                frequency: band.frequency,
                gainDB: band.gainDB,
                q: band.q,
                sampleRate: sampleRate
            )
        }
    }

    /// Reset all filter state (e.g. on device change to avoid pops).
    mutating func resetState() {
        for i in 0..<maxBands {
            filters[i].stateL = BiquadState()
            filters[i].stateR = BiquadState()
        }
    }

    /// Process interleaved stereo audio in-place.
    /// Called from the real-time audio thread — MUST be allocation-free.
    func process(buffer: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        guard enabled else { return }

        let sampleCount = frameCount * channelCount

        // Apply preamp gain (even with 0 bands)
        if preampGainLinear != 1.0 {
            for i in 0..<sampleCount {
                buffer[i] *= preampGainLinear
            }
        }

        // Cascade each active biquad filter
        for f in 0..<bandCount {
            let coeff = filters[f].coefficients

            if channelCount >= 2 {
                // Interleaved stereo: process L and R with separate state
                for frame in 0..<frameCount {
                    let idx = frame * channelCount
                    buffer[idx] = BiquadFilter.processSample(
                        input: buffer[idx],
                        coefficients: coeff,
                        state: &filters[f].stateL
                    )
                    buffer[idx + 1] = BiquadFilter.processSample(
                        input: buffer[idx + 1],
                        coefficients: coeff,
                        state: &filters[f].stateR
                    )
                }
            } else {
                // Mono
                for frame in 0..<frameCount {
                    buffer[frame] = BiquadFilter.processSample(
                        input: buffer[frame],
                        coefficients: coeff,
                        state: &filters[f].stateL
                    )
                }
            }
        }
    }

    func deallocate() {
        filters.deinitialize(count: maxBands)
        filters.deallocate()
    }
}
