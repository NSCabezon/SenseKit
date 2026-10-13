import simd

/// Correction from the tracked accessory frame to the grip frame.
public struct SenseGripCorrection: Sendable, Equatable {
    public var tiltDegrees: Float
    public var position: SIMD3<Float>
    public var pivot: SIMD3<Float>
    public var mirrorLeft: Bool

    public init(tiltDegrees: Float = 0,                 // TODO(extract): take the default from KleptonControllers
                position: SIMD3<Float> = .zero,         // TODO(extract): take the default from KleptonControllers
                pivot: SIMD3<Float> = .zero,            // TODO(extract): take the default from KleptonControllers
                mirrorLeft: Bool = true) {              // TODO(extract): take the default from KleptonControllers
        self.tiltDegrees = tiltDegrees
        self.position = position
        self.pivot = pivot
        self.mirrorLeft = mirrorLeft
    }
}

/// Velocity thresholds below which velocities are zeroed.
public struct SenseVelocityGate: Sendable, Equatable {
    public var linear: Float
    public var angular: Float

    public init(linear: Float = 0, angular: Float = 0) { // TODO(extract): take the default from KleptonControllers
        self.linear = linear
        self.angular = angular
    }
}

/// Haptics tuning: gain, continuous or pulse mode, and the minimum pulse length.
public struct SenseHapticsConfiguration: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case continuous, pulse }

    public var gain: Float
    public var mode: Mode
    public var minPulseMs: Double

    public init(gain: Float = 0.25,
                mode: Mode = .continuous,               // TODO(extract): take the default from KleptonControllers
                minPulseMs: Double = 0) {               // TODO(extract): take the default from KleptonControllers
        self.gain = gain
        self.mode = mode
        self.minPulseMs = minPulseMs
    }
}

/// All live-tunable settings of `SenseControllers`.
public struct SenseConfiguration: Sendable, Equatable {
    public var gripCorrection: SenseGripCorrection
    public var predictionCapMs: Double
    public var velocityGate: SenseVelocityGate
    public var haptics: SenseHapticsConfiguration

    public init(gripCorrection: SenseGripCorrection = SenseGripCorrection(),
                predictionCapMs: Double = 0,            // TODO(extract): take the default from KleptonControllers
                velocityGate: SenseVelocityGate = SenseVelocityGate(),
                haptics: SenseHapticsConfiguration = SenseHapticsConfiguration()) {
        self.gripCorrection = gripCorrection
        self.predictionCapMs = predictionCapMs
        self.velocityGate = velocityGate
        self.haptics = haptics
    }
}
