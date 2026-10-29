import Foundation
import XCTest
@testable import RailCore

final class RailSimulationTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_793_228_000)
    private let points = [
        RailCoordinate(latitude: 47.0, longitude: 8.0),
        RailCoordinate(latitude: 47.005, longitude: 8.005),
        RailCoordinate(latitude: 47.0, longitude: 8.01),
        RailCoordinate(latitude: 47.005, longitude: 8.015),
        RailCoordinate(latitude: 47.0, longitude: 8.02)
    ]

    private func journey() -> RailJourney {
        RailJourney(
            id: "test-service", serviceName: "Test IR",
            stops: [
                RailStop(id: "a", name: "A", coordinate: points[0], scheduledArrival: nil, scheduledDeparture: epoch),
                RailStop(id: "b", name: "B", coordinate: points[2], scheduledArrival: epoch.addingTimeInterval(120), scheduledDeparture: epoch.addingTimeInterval(180)),
                RailStop(id: "c", name: "C", coordinate: points[4], scheduledArrival: epoch.addingTimeInterval(300), scheduledDeparture: nil)
            ], geometry: points, geometrySource: "Synthetic bent rail fixture; not a real service"
        )
    }

    func testEndpointsAndWaiting() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        let waiting = engine.sample(at: epoch.addingTimeInterval(-1))
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.coordinate, points[0])
        XCTAssertEqual(waiting.speedMetresPerSecond, 0)
        let end = engine.sample(at: epoch.addingTimeInterval(300))
        XCTAssertEqual(end.phase, .arrived)
        XCTAssertEqual(end.coordinate, points[4])
        XCTAssertEqual(end.speedMetresPerSecond, 0)
        XCTAssertEqual(end.distanceMetres, engine.totalDistanceMetres, accuracy: 0.001)
    }

    func testIntermediateStopDwellAndDeparture() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        for seconds in [120.0, 150, 179.999] {
            let sample = engine.sample(at: epoch.addingTimeInterval(seconds))
            XCTAssertEqual(sample.phase, .dwelling)
            XCTAssertEqual(sample.coordinate, points[2])
            XCTAssertEqual(sample.stopName, "B")
            XCTAssertEqual(sample.speedMetresPerSecond, 0)
        }
        let departure = engine.sample(at: epoch.addingTimeInterval(180))
        XCTAssertEqual(departure.phase, .moving)
        XCTAssertEqual(departure.speedMetresPerSecond, 0)
    }

    func testFollowsBentGeometryInsteadOfStationChord() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        let halfway = engine.sample(at: epoch.addingTimeInterval(60))
        XCTAssertEqual(halfway.coordinate.latitude, points[1].latitude, accuracy: 0.000001)
        XCTAssertGreaterThan(halfway.coordinate.latitude, 47.004)
    }

    func testSpeedAccelerationAndMonotonicDistance() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        var previous = engine.sample(at: epoch)
        for tick in 1...3000 {
            let sample = engine.sample(at: epoch.addingTimeInterval(Double(tick) / 10))
            XCTAssertGreaterThanOrEqual(sample.distanceMetres + 0.00001, previous.distanceMetres)
            XCTAssertLessThanOrEqual(sample.speedMetresPerSecond, 320 / 3.6)
            XCTAssertLessThanOrEqual(abs(sample.speedMetresPerSecond - previous.speedMetresPerSecond) / 0.1, 0.80001)
            previous = sample
        }
        XCTAssertLessThan(engine.sample(at: epoch.addingTimeInterval(1)).speedMetresPerSecond,
                          engine.sample(at: epoch.addingTimeInterval(30)).speedMetresPerSecond)
        XCTAssertLessThan(engine.sample(at: epoch.addingTimeInterval(119)).speedMetresPerSecond,
                          engine.sample(at: epoch.addingTimeInterval(90)).speedMetresPerSecond)
    }

    func testMissingAndDegenerateGeometryRejected() {
        let base = journey()
        for shape in [[], [points[0]], [points[0], points[0]]] {
            let bad = RailJourney(id: base.id, serviceName: base.serviceName, stops: base.stops,
                                  geometry: shape, geometrySource: base.geometrySource)
            XCTAssertThrowsError(try RailSimulation(journey: bad, mode: .timetable))
        }
    }

    func testCoarseGeometryAndInvalidCoordinateRejected() {
        let base = journey()
        let coarse = RailJourney(id: base.id, serviceName: base.serviceName, stops: base.stops,
                                 geometry: [points[0], RailCoordinate(latitude: 48, longitude: 8)], geometrySource: "Test")
        XCTAssertThrowsError(try RailSimulation(journey: coarse, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .coarseGeometry)
        }
        let invalid = RailJourney(id: base.id, serviceName: base.serviceName, stops: base.stops,
                                  geometry: [points[0], RailCoordinate(latitude: .nan, longitude: 8)], geometrySource: "Test")
        XCTAssertThrowsError(try RailSimulation(journey: invalid, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .invalidCoordinate)
        }
    }

    func testStopOffRouteRejected() {
        var base = journey()
        base.stops[1] = RailStop(id: "off", name: "Off Route", coordinate: RailCoordinate(latitude: 47.2, longitude: 8),
                                scheduledArrival: epoch.addingTimeInterval(120), scheduledDeparture: epoch.addingTimeInterval(180))
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .stopOffRoute("Off Route"))
        }
    }

    func testReverseStopOrderRejected() {
        var base = journey()
        base.stops.swapAt(1, 2)
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable))
    }

    func testImpossibleMotionRejected() {
        var base = journey()
        base.stops[1] = RailStop(id: "b", name: "B", coordinate: points[2],
                                scheduledArrival: epoch.addingTimeInterval(1), scheduledDeparture: epoch.addingTimeInterval(180))
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .impossibleMotion)
        }
    }

    func testInvalidDwellAndMissingTimesRejected() {
        var base = journey()
        base.stops[1] = RailStop(id: "b", name: "B", coordinate: points[2],
                                scheduledArrival: epoch.addingTimeInterval(200), scheduledDeparture: epoch.addingTimeInterval(180))
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .invalidChronology)
        }
        base.stops[1] = RailStop(id: "b", name: "B", coordinate: points[2], scheduledArrival: nil, scheduledDeparture: nil)
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable)) { error in
            XCTAssertEqual(error as? RailSimulationError, .missingTimes)
        }
    }

    func testCancellationRejected() {
        var base = journey()
        base.cancelled = true
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .realtime)) { error in
            XCTAssertEqual(error as? RailSimulationError, .cancelled)
        }
        base.cancelled = false
        base.stops[1].cancelled = true
        XCTAssertThrowsError(try RailSimulation(journey: base, mode: .timetable))
    }

    func testRealtimeAppliesDelayWithoutChangingPlannedMode() throws {
        var base = journey()
        base.realtimeUpdatedAt = epoch
        for index in base.stops.indices {
            base.stops[index].estimatedArrival = base.stops[index].scheduledArrival?.addingTimeInterval(60)
            base.stops[index].estimatedDeparture = base.stops[index].scheduledDeparture?.addingTimeInterval(60)
        }
        let live = try RailSimulation(journey: base, mode: .realtime, now: epoch)
        let planned = try RailSimulation(journey: base, mode: .timetable, now: epoch)
        XCTAssertEqual(live.realtimeStatus, .estimated)
        XCTAssertEqual(live.sample(at: epoch.addingTimeInterval(30)).phase, .waiting)
        XCTAssertEqual(planned.sample(at: epoch.addingTimeInterval(30)).phase, .moving)
    }

    func testStaleAndUnavailableRealtimeAreExplicit() throws {
        var base = journey()
        let missing = try RailSimulation(journey: base, mode: .realtime, now: epoch)
        XCTAssertEqual(missing.realtimeStatus, .unavailableFallback)
        base.realtimeUpdatedAt = epoch.addingTimeInterval(-121)
        base.stops[0].estimatedDeparture = epoch.addingTimeInterval(60)
        let stale = try RailSimulation(journey: base, mode: .realtime, now: epoch)
        XCTAssertEqual(stale.realtimeStatus, .staleFallback)
        XCTAssertEqual(stale.sample(at: epoch.addingTimeInterval(30)).phase, .moving)
        base.realtimeUpdatedAt = epoch.addingTimeInterval(31)
        XCTAssertEqual(try RailSimulation(journey: base, mode: .realtime, now: epoch).realtimeStatus, .staleFallback)
    }

    func testMidnightUsesAbsoluteDates() throws {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-29T23:59:00+01:00")!
        var base = journey()
        base.stops = base.stops.map { stop in
            RailStop(id: stop.id, name: stop.name, coordinate: stop.coordinate,
                     scheduledArrival: stop.scheduledArrival.map { midnight.addingTimeInterval($0.timeIntervalSince(epoch)) },
                     scheduledDeparture: stop.scheduledDeparture.map { midnight.addingTimeInterval($0.timeIntervalSince(epoch)) })
        }
        let engine = try RailSimulation(journey: base, mode: .timetable, now: midnight)
        XCTAssertEqual(engine.sample(at: midnight.addingTimeInterval(150)).phase, .dwelling)
        XCTAssertEqual(engine.sample(at: midnight.addingTimeInterval(300)).phase, .arrived)
    }

    func testCoordinateDistanceHelperClampsToJourney() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        XCTAssertEqual(engine.coordinate(atDistanceMetres: -100), points[0])
        XCTAssertEqual(engine.coordinate(atDistanceMetres: engine.totalDistanceMetres + 100), points[4])
    }

    func testLimiterCanFollowNormalJourneyThroughDwellAndArrival() throws {
        let engine = try RailSimulation(journey: journey(), mode: .timetable)
        var limiter = RailMotionLimiter()
        for tick in 1...1600 {
            let desired = engine.sample(at: epoch.addingTimeInterval(Double(tick) / 4))
            _ = try limiter.advance(targetDistanceMetres: desired.distanceMetres, elapsed: 0.25)
            XCTAssertLessThanOrEqual(limiter.state.distanceMetres, desired.distanceMetres + 0.0001)
        }
        XCTAssertEqual(limiter.state.distanceMetres, engine.totalDistanceMetres, accuracy: 0.001)
        XCTAssertEqual(limiter.state.speedMetresPerSecond, 0, accuracy: 0.001)
    }

    func testCodableRoundtrip() throws {
        let base = journey()
        let data = try JSONEncoder().encode(base)
        XCTAssertEqual(try JSONDecoder().decode(RailJourney.self, from: data), base)
    }

    func testOptionalCancellationAndRealtimeFieldsMayBeOmitted() throws {
        let data = Data("""
        {"id":"fixture","serviceName":"Test","geometrySource":"Test","geometry":[],
         "stops":[{"id":"a","name":"A","coordinate":{"latitude":47,"longitude":8}}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(RailJourney.self, from: data)
        XCTAssertFalse(decoded.cancelled)
        XCTAssertFalse(decoded.stops[0].cancelled)
        XCTAssertNil(decoded.realtimeUpdatedAt)
    }
}
