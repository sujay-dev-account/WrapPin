import Foundation

struct RailMotionState: Equatable, Sendable {
    let distanceMetres: Double
    let speedMetresPerSecond: Double
}

enum RailMotionLimiterError: Error, Equatable {
    case invalidTick
    case targetBehind
    case cannotBrakeSafely
}

/// Reconciles changed timing forecasts without jumping or reversing. It can lag
/// a prediction while catching up. A forecast that cannot be reached within the
/// braking bound requires stopping/restoring the device session, not teleporting.
struct RailMotionLimiter: Sendable {
    private(set) var state: RailMotionState
    let maxSpeedMetresPerSecond: Double
    let maxAccelerationMetresPerSecondSquared: Double

    init(initialDistanceMetres: Double = 0, maxSpeedMetresPerSecond: Double = 320 / 3.6,
         maxAccelerationMetresPerSecondSquared: Double = 0.8) {
        state = RailMotionState(distanceMetres: max(0, initialDistanceMetres), speedMetresPerSecond: 0)
        self.maxSpeedMetresPerSecond = maxSpeedMetresPerSecond
        self.maxAccelerationMetresPerSecondSquared = maxAccelerationMetresPerSecondSquared
    }

    mutating func advance(targetDistanceMetres target: Double, elapsed: TimeInterval) throws -> RailMotionState {
        guard target.isFinite, elapsed.isFinite, elapsed > 0, elapsed <= 5,
              state.distanceMetres.isFinite, maxSpeedMetresPerSecond > 0,
              maxAccelerationMetresPerSecondSquared > 0 else {
            throw RailMotionLimiterError.invalidTick
        }
        let gap = target - state.distanceMetres
        guard gap >= -0.01 else { throw RailMotionLimiterError.targetBehind }
        let a = maxAccelerationMetresPerSecondSquared
        let speed = state.speedMetresPerSecond
        guard gap + 1e-7 >= speed * speed / (2 * a) else {
            throw RailMotionLimiterError.cannotBrakeSafely
        }
        let minimumNextSpeed = max(0, speed - a * elapsed)
        // Reserve braking distance after this tick. This solves
        // (v + nextV)/2 * dt + nextV^2/(2*a) <= gap.
        let radicand = pow(a * elapsed / 2, 2) + 2 * a * max(0, gap) - a * elapsed * speed
        guard radicand >= 0 else { throw RailMotionLimiterError.cannotBrakeSafely }
        let safeNextSpeed = max(0, sqrt(radicand) - a * elapsed / 2)
        guard safeNextSpeed + 1e-8 >= minimumNextSpeed else {
            throw RailMotionLimiterError.cannotBrakeSafely
        }
        let nextSpeed = min(maxSpeedMetresPerSecond, speed + a * elapsed, safeNextSpeed)
        // A low-speed stop may occur before the tick ends. Integrate only
        // until rest; averaging across the entire tick would overshoot.
        let travelled: Double
        if nextSpeed == 0, speed <= a * elapsed {
            travelled = speed * speed / (2 * a)
        } else {
            travelled = (speed + nextSpeed) * elapsed / 2
        }
        guard travelled <= max(0, gap) + 1e-7 else { throw RailMotionLimiterError.cannotBrakeSafely }
        state = RailMotionState(
            distanceMetres: state.distanceMetres + travelled,
            speedMetresPerSecond: nextSpeed
        )
        return state
    }
}
