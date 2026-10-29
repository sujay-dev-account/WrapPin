import Foundation

/// A timing-based estimate on a supplied railway polyline, never a live GPS fix.
/// Geometry provenance must be established by the provider; proximity alone
/// cannot prove that a polyline follows the correct track or service.
struct RailSimulation: Sendable {
    let journey: RailJourney
    let realtimeStatus: RailRealtimeStatus
    let totalDistanceMetres: Double
    private let shape: RailShape
    private let stops: [TimedStop]
    private let legs: [MotionLeg]

    init(
        journey: RailJourney,
        mode: RailSimulationMode,
        now: Date = Date(),
        realtimeMaxAge: TimeInterval = 120
    ) throws {
        guard !journey.cancelled, !journey.stops.contains(where: \.cancelled) else {
            throw RailSimulationError.cancelled
        }
        guard journey.stops.count >= 2,
              !journey.geometrySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RailSimulationError.missingGeometry
        }
        let shape = try RailShape(points: journey.geometry)
        guard journey.stops.allSatisfy({ $0.coordinate.isValid }) else {
            throw RailSimulationError.invalidCoordinate
        }
        let status: RailRealtimeStatus
        if mode == .timetable {
            status = .timetable
        } else if let updated = journey.realtimeUpdatedAt,
                  now.timeIntervalSince(updated) >= -30,
                  now.timeIntervalSince(updated) <= realtimeMaxAge {
            status = journey.stops.contains(where: { $0.estimatedArrival != nil || $0.estimatedDeparture != nil })
                ? .estimated : .unavailableFallback
        } else if journey.realtimeUpdatedAt != nil {
            status = .staleFallback
        } else {
            status = .unavailableFallback
        }

        var timedStops: [TimedStop] = []
        var previousDistance = 0.0
        for (index, stop) in journey.stops.enumerated() {
            let projection = shape.project(stop.coordinate, minimumDistance: previousDistance)
            guard let projection, projection.offset <= 500 else {
                throw RailSimulationError.stopOffRoute(stop.name)
            }
            guard let plannedArrival = stop.scheduledArrival ?? (index == 0 ? stop.scheduledDeparture : nil),
                  let plannedDeparture = stop.scheduledDeparture ?? (index == journey.stops.count - 1 ? stop.scheduledArrival : nil) else {
                throw RailSimulationError.missingTimes
            }
            guard plannedArrival.timeIntervalSince1970.isFinite,
                  plannedDeparture.timeIntervalSince1970.isFinite,
                  plannedArrival <= plannedDeparture else {
                throw RailSimulationError.invalidChronology
            }
            var arrival = plannedArrival
            var departure = plannedDeparture
            if status == .estimated {
                // When only one event is forecast, carry its delay across the
                // same stop rather than inventing a negative dwell interval.
                if let estimated = stop.estimatedArrival {
                    arrival = estimated
                    departure = stop.estimatedDeparture
                        ?? plannedDeparture.addingTimeInterval(estimated.timeIntervalSince(plannedArrival))
                } else if let estimated = stop.estimatedDeparture {
                    departure = estimated
                    arrival = plannedArrival.addingTimeInterval(estimated.timeIntervalSince(plannedDeparture))
                }
            }
            guard arrival.timeIntervalSince1970.isFinite, departure.timeIntervalSince1970.isFinite,
                  arrival <= departure else { throw RailSimulationError.invalidChronology }
            if let previous = timedStops.last {
                guard previous.departure < arrival, projection.distance > previous.distance else {
                    throw RailSimulationError.invalidChronology
                }
            }
            timedStops.append(TimedStop(name: stop.name, arrival: arrival, departure: departure, distance: projection.distance))
            previousDistance = projection.distance
        }

        var motionLegs: [MotionLeg] = []
        for index in 1..<timedStops.count {
            let from = timedStops[index - 1]
            let to = timedStops[index]
            motionLegs.append(try MotionLeg(
                departure: from.departure,
                duration: to.arrival.timeIntervalSince(from.departure),
                startDistance: from.distance,
                distance: to.distance - from.distance
            ))
        }
        self.journey = journey
        self.shape = shape
        self.stops = timedStops
        self.legs = motionLegs
        self.realtimeStatus = status
        self.totalDistanceMetres = (timedStops.last?.distance ?? 0) - (timedStops.first?.distance ?? 0)
    }

    func sample(at date: Date) -> RailSample {
        let first = stops[0]
        let last = stops[stops.count - 1]
        func result(_ distance: Double, _ speed: Double, _ phase: RailSamplePhase, _ name: String?) -> RailSample {
            RailSample(
                coordinate: shape.coordinate(at: distance),
                distanceMetres: distance - first.distance,
                speedMetresPerSecond: speed,
                phase: phase,
                stopName: name,
                realtimeStatus: realtimeStatus
            )
        }
        if date < first.departure { return result(first.distance, 0, .waiting, first.name) }
        if date >= last.arrival { return result(last.distance, 0, .arrived, last.name) }
        for (index, leg) in legs.enumerated() {
            let destination = stops[index + 1]
            if date < destination.arrival {
                let motion = leg.sample(elapsed: date.timeIntervalSince(leg.departure))
                return result(leg.startDistance + motion.distance, motion.speed, .moving, nil)
            }
            if date < destination.departure {
                return result(destination.distance, 0, .dwelling, destination.name)
            }
        }
        return result(last.distance, 0, .arrived, last.name)
    }

    /// For a controller applying a forward-only, speed-bounded reconciliation
    /// after a forecast refresh. Distance is relative to the first selected stop.
    func coordinate(atDistanceMetres distance: Double) -> RailCoordinate {
        shape.coordinate(at: stops[0].distance + min(max(distance, 0), totalDistanceMetres))
    }
}

private struct TimedStop: Sendable {
    let name: String
    let arrival: Date
    let departure: Date
    let distance: Double
}

private struct MotionLeg: Sendable {
    let departure: Date
    let duration: Double
    let startDistance: Double
    let distance: Double
    let rampDuration: Double
    let peakSpeed: Double

    init(departure: Date, duration: Double, startDistance: Double, distance: Double) throws {
        let accelerationLimit = 0.8
        guard duration > 0, distance > 0, duration.isFinite, distance.isFinite,
              distance <= accelerationLimit * duration * duration / 4 else {
            throw RailSimulationError.impossibleMotion
        }
        let minimumRamp = (duration - sqrt(max(0, duration * duration - 4 * distance / accelerationLimit))) / 2
        let ramp = min(duration / 2, max(min(duration * 0.15, 30), minimumRamp))
        let peak = distance / (duration - ramp)
        guard ramp > 0, peak <= 320 / 3.6, peak / ramp <= accelerationLimit + 1e-9 else {
            throw RailSimulationError.impossibleMotion
        }
        self.departure = departure
        self.duration = duration
        self.startDistance = startDistance
        self.distance = distance
        self.rampDuration = ramp
        self.peakSpeed = peak
    }

    func sample(elapsed: Double) -> (distance: Double, speed: Double) {
        let t = min(max(elapsed, 0), duration)
        let acceleration = peakSpeed / rampDuration
        if t < rampDuration {
            return (0.5 * acceleration * t * t, acceleration * t)
        }
        if t > duration - rampDuration {
            let remaining = duration - t
            return (distance - 0.5 * acceleration * remaining * remaining, acceleration * remaining)
        }
        return (0.5 * peakSpeed * rampDuration + peakSpeed * (t - rampDuration), peakSpeed)
    }
}

private struct RailShape: Sendable {
    let points: [RailCoordinate]
    let cumulative: [Double]

    init(points: [RailCoordinate]) throws {
        guard points.count >= 2 else { throw RailSimulationError.missingGeometry }
        guard points.allSatisfy(\.isValid) else { throw RailSimulationError.invalidCoordinate }
        var distances = [0.0]
        for index in 1..<points.count {
            let distance = points[index - 1].distance(to: points[index])
            guard distance <= 5_000 else { throw RailSimulationError.coarseGeometry }
            distances.append(distances[index - 1] + distance)
        }
        guard distances.last! > 1 else { throw RailSimulationError.missingGeometry }
        self.points = points
        self.cumulative = distances
    }

    func coordinate(at distance: Double) -> RailCoordinate {
        if distance <= 0 { return points[0] }
        if distance >= cumulative.last! { return points.last! }
        var low = 1
        var high = cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] < distance { low = middle + 1 } else { high = middle }
        }
        let length = cumulative[low] - cumulative[low - 1]
        let fraction = length > 0 ? (distance - cumulative[low - 1]) / length : 0
        return interpolate(points[low - 1], points[low], fraction)
    }

    func project(_ point: RailCoordinate, minimumDistance: Double) -> (distance: Double, offset: Double)? {
        var best: (distance: Double, offset: Double)?
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let scale = cos(point.latitude * .pi / 180)
            let dx = (b.longitude - a.longitude) * scale
            let dy = b.latitude - a.latitude
            let denominator = dx * dx + dy * dy
            guard denominator > 0 else { continue }
            let fraction = min(1, max(0,
                ((point.longitude - a.longitude) * scale * dx + (point.latitude - a.latitude) * dy) / denominator
            ))
            let distance = cumulative[index - 1] + fraction * (cumulative[index] - cumulative[index - 1])
            guard distance + 0.001 >= minimumDistance else { continue }
            let offset = point.distance(to: interpolate(a, b, fraction))
            if best == nil || offset < best!.offset {
                best = (distance, offset)
            }
        }
        return best
    }

    private func interpolate(_ a: RailCoordinate, _ b: RailCoordinate, _ fraction: Double) -> RailCoordinate {
        RailCoordinate(
            latitude: a.latitude + (b.latitude - a.latitude) * fraction,
            longitude: a.longitude + (b.longitude - a.longitude) * fraction
        )
    }
}
