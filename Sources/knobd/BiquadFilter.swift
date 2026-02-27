import Foundation
import EQCore

/// Pre-normalized biquad coefficients (already divided by a0).
struct BiquadCoefficients {
    var b0: Float = 0
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0

    /// Compute coefficients using the Robert Bristow-Johnson Audio EQ Cookbook.
    /// Computation uses Double for precision; stored as Float for audio processing.
    static func compute(
        type: FilterType,
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)
        let A = pow(10.0, gainDB / 40.0) // sqrt of linear gain

        var b0, b1, b2, a0, a1, a2: Double

        switch type {
        case .peaking:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha / A

        case .lowShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha)
            a0 = (A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW)
            a2 = (A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha

        case .highShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW)
            b2 = A * ((A + 1.0) + (A - 1.0) * cosW - twoSqrtAAlpha)
            a0 = (A + 1.0) - (A - 1.0) * cosW + twoSqrtAAlpha
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW)
            a2 = (A + 1.0) - (A - 1.0) * cosW - twoSqrtAAlpha

        case .lowpass:
            b0 = (1.0 - cosW) / 2.0
            b1 = 1.0 - cosW
            b2 = (1.0 - cosW) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha

        case .highpass:
            b0 = (1.0 + cosW) / 2.0
            b1 = -(1.0 + cosW)
            b2 = (1.0 + cosW) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW
            a2 = 1.0 - alpha
        }

        // Pre-normalize by a0
        return BiquadCoefficients(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
}

/// Per-channel delay-line state for one biquad section.
struct BiquadState {
    var x1: Float = 0 // x[n-1]
    var x2: Float = 0 // x[n-2]
    var y1: Float = 0 // y[n-1]
    var y2: Float = 0 // y[n-2]
}

/// A single biquad filter with coefficients and per-channel state.
struct BiquadFilter {
    var coefficients: BiquadCoefficients = BiquadCoefficients()
    var stateL: BiquadState = BiquadState()
    var stateR: BiquadState = BiquadState()

    /// Process a single sample through the biquad (Direct Form I).
    @inline(__always)
    static func processSample(
        input: Float,
        coefficients: BiquadCoefficients,
        state: inout BiquadState
    ) -> Float {
        let output = coefficients.b0 * input
            + coefficients.b1 * state.x1
            + coefficients.b2 * state.x2
            - coefficients.a1 * state.y1
            - coefficients.a2 * state.y2

        state.x2 = state.x1
        state.x1 = input
        state.y2 = state.y1
        state.y1 = output

        return output
    }
}
