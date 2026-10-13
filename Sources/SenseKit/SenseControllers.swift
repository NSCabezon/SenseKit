import ARKit
import CoreHaptics
import Foundation
import GameController

/// Entry point: discovers Sense controllers and serves pose, input and haptics, thread-safe.
public final class SenseControllers: @unchecked Sendable {
    private let lock = NSLock()
    private var _configuration: SenseConfiguration

    /// Optional log sink (default off).
    public var logger: ((String) -> Void)?

    public init(configuration: SenseConfiguration = .init()) {
        _configuration = configuration
    }

    /// Live tuning.
    public var configuration: SenseConfiguration {
        get { lock.lock(); defer { lock.unlock() }; return _configuration }
        set { lock.lock(); defer { lock.unlock() }; _configuration = newValue }
    }

    public func makeTrackingProvider() async -> AccessoryTrackingProvider? {
        // TODO(extract)
        return nil
    }

    public func consumeAnchors(from provider: AccessoryTrackingProvider) async {
        // TODO(extract)
    }

    /// Call per frame; true means rebuild the tracking provider.
    public func controllersChanged() -> Bool {
        // TODO(extract)
        return false
    }

    public func forgetPoses() {
        // TODO(extract)
    }

    public func state(_ hand: SenseHand, at time: TimeInterval) -> SenseHandState {
        // TODO(extract)
        return SenseHandState()
    }

    public func ghostSample(_ hand: SenseHand, at time: TimeInterval) -> SenseGhostSample? {
        // TODO(extract)
        return nil
    }

    public func rumble(_ hand: SenseHand, amplitude: Float, seconds: Double) {
        // TODO(extract)
    }

    public func pumpHaptics() {
        // TODO(extract)
    }
}
