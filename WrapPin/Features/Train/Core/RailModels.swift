import Foundation

struct RailCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    func distance(to other: Self) -> Double {
        let p1 = latitude * .pi / 180
        let p2 = other.latitude * .pi / 180
        let dLat = p2 - p1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(p1) * cos(p2) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
}

struct RailStop: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let coordinate: RailCoordinate
    let scheduledArrival: Date?
    let scheduledDeparture: Date?
    var estimatedArrival: Date? = nil
    var estimatedDeparture: Date? = nil
    var cancelled: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, coordinate, scheduledArrival, scheduledDeparture
        case estimatedArrival, estimatedDeparture, cancelled
    }
}

struct RailJourney: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let serviceName: String
    var stops: [RailStop]
    let geometry: [RailCoordinate]
    let geometrySource: String
    var realtimeUpdatedAt: Date? = nil
    var cancelled: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, serviceName, stops, geometry, geometrySource, realtimeUpdatedAt, cancelled
    }
}

extension RailStop {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        coordinate = try values.decode(RailCoordinate.self, forKey: .coordinate)
        scheduledArrival = try values.decodeIfPresent(Date.self, forKey: .scheduledArrival)
        scheduledDeparture = try values.decodeIfPresent(Date.self, forKey: .scheduledDeparture)
        estimatedArrival = try values.decodeIfPresent(Date.self, forKey: .estimatedArrival)
        estimatedDeparture = try values.decodeIfPresent(Date.self, forKey: .estimatedDeparture)
        cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }
}

extension RailJourney {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        serviceName = try values.decode(String.self, forKey: .serviceName)
        stops = try values.decode([RailStop].self, forKey: .stops)
        geometry = try values.decode([RailCoordinate].self, forKey: .geometry)
        geometrySource = try values.decode(String.self, forKey: .geometrySource)
        realtimeUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .realtimeUpdatedAt)
        cancelled = try values.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
    }
}

enum RailSimulationMode: String, Codable, CaseIterable, Sendable {
    case timetable, realtime
}

enum RailRealtimeStatus: String, Codable, Sendable {
    case timetable
    case estimated
    case unavailableFallback
    case staleFallback
}

enum RailSamplePhase: String, Codable, Sendable {
    case waiting, moving, dwelling, arrived
}

struct RailSample: Equatable, Sendable {
    let coordinate: RailCoordinate
    let distanceMetres: Double
    let speedMetresPerSecond: Double
    let phase: RailSamplePhase
    let stopName: String?
    let realtimeStatus: RailRealtimeStatus
}

enum RailSimulationError: Error, Equatable, LocalizedError {
    case cancelled
    case missingGeometry
    case invalidCoordinate
    case coarseGeometry
    case missingTimes
    case invalidChronology
    case stopOffRoute(String)
    case impossibleMotion

    var errorDescription: String? {
        switch self {
        case .cancelled: return "This service or one of its stops is cancelled."
        case .missingGeometry: return "Detailed rail geometry is required before simulation."
        case .invalidCoordinate: return "The journey contains an invalid coordinate."
        case .coarseGeometry: return "The rail geometry has a gap longer than 5 km."
        case .missingTimes: return "The journey is missing a required arrival or departure time."
        case .invalidChronology: return "The journey times are not in chronological order."
        case .stopOffRoute(let name): return "A stop is too far from the rail geometry: \(name)."
        case .impossibleMotion: return "The supplied route and times require an implausible train speed or acceleration."
        }
    }
}
