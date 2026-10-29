import XCTest
@testable import RailCore

final class RailMotionLimiterTests: XCTestCase {
    func testLargeForecastJumpIsApproachedWithinMotionBounds() throws {
        var limiter = RailMotionLimiter()
        var previous = limiter.state
        for _ in 0..<100 {
            let next = try limiter.advance(targetDistanceMetres: 100_000, elapsed: 1)
            XCTAssertGreaterThanOrEqual(next.distanceMetres, previous.distanceMetres)
            XCTAssertLessThanOrEqual(next.speedMetresPerSecond, 320 / 3.6)
            XCTAssertLessThanOrEqual(abs(next.speedMetresPerSecond - previous.speedMetresPerSecond), 0.800001)
            previous = next
        }
        XCTAssertLessThan(limiter.state.distanceMetres, 5_000)
    }

    func testBrakesBeforeFixedDwellTarget() throws {
        var limiter = RailMotionLimiter()
        var previous = limiter.state
        for _ in 0..<200 {
            let next = try limiter.advance(targetDistanceMetres: 100, elapsed: 0.5)
            XCTAssertLessThanOrEqual(next.distanceMetres, 100.000001)
            XCTAssertGreaterThanOrEqual(next.distanceMetres, previous.distanceMetres)
            XCTAssertLessThanOrEqual(abs(next.speedMetresPerSecond - previous.speedMetresPerSecond), 0.400001)
            previous = next
        }
        XCTAssertEqual(limiter.state.distanceMetres, 100, accuracy: 0.01)
        XCTAssertEqual(limiter.state.speedMetresPerSecond, 0, accuracy: 0.01)
    }

    func testBackwardForecastAndSuspensionRequireStop() throws {
        var limiter = RailMotionLimiter(initialDistanceMetres: 100)
        XCTAssertThrowsError(try limiter.advance(targetDistanceMetres: 50, elapsed: 1)) { error in
            XCTAssertEqual(error as? RailMotionLimiterError, .targetBehind)
        }
        XCTAssertThrowsError(try limiter.advance(targetDistanceMetres: 200, elapsed: 6)) { error in
            XCTAssertEqual(error as? RailMotionLimiterError, .invalidTick)
        }
        XCTAssertEqual(limiter.state.distanceMetres, 100)
    }

    func testAbruptForecastCannotForceInstantBraking() throws {
        var limiter = RailMotionLimiter()
        for _ in 0..<10 { _ = try limiter.advance(targetDistanceMetres: 1_000, elapsed: 1) }
        XCTAssertThrowsError(try limiter.advance(targetDistanceMetres: limiter.state.distanceMetres + 1, elapsed: 1)) { error in
            XCTAssertEqual(error as? RailMotionLimiterError, .cannotBrakeSafely)
        }
    }
}
