import Foundation
import MapKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves a timetable connection to open-map geometry before playback. It
/// uses railway ways for rail/tram and an OSRM road route for bus/walking legs.
/// It never substitutes a straight line if an open-data route cannot be found.
actor PublicTransitGeometryResolver {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // Open map servers are a fallback only. Never leave the start
            // button waiting for their often busy public query queues.
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    func resolve(_ journey: RailJourney) async throws -> RailJourney {
        guard journey.geometry.count < 2 else { return journey }
        let legs = journey.legs.isEmpty
            ? [TransitLeg(id: journey.id, vehicle: .train, serviceName: journey.serviceName, stops: journey.stops, isWalkingTransfer: false)]
            : journey.legs
        var shape: [RailCoordinate] = []
        for leg in legs {
            guard leg.stops.count >= 2 else { continue }
            let from = leg.stops[0].coordinate
            let to = leg.stops[leg.stops.count - 1].coordinate
            let segment: [RailCoordinate]
            if leg.isWalkingTransfer {
                segment = try await mapRoute(from: from, to: to, transport: .walking)
            } else {
                do {
                    // Resolve an entire vehicle leg in one request. Resolving
                    // every intermediate stop used to multiply a temporary
                    // maps outage into a minute-long wait at the start button.
                    segment = try await mapRoute(from: from, to: to, transport: .transit)
                } catch {
                    switch leg.vehicle {
                    case .train, .tram, .cableway:
                        segment = try await railRoute(from: from, to: to, tram: leg.vehicle == .tram)
                    case .bus, .ship, .unknown:
                        segment = try await roadRoute(from: from, to: to)
                    }
                }
            }
            append(segment, to: &shape)
        }
        guard shape.count >= 2 else { throw RailSimulationError.missingGeometry }
        return RailJourney(id: journey.id, serviceName: journey.serviceName, stops: journey.stops,
                           geometry: shape,
                           geometrySource: "Apple Maps public-transit routing with OpenStreetMap/OSRM fallback; resolved for this selected timetable connection.",
                           realtimeUpdatedAt: journey.realtimeUpdatedAt, cancelled: journey.cancelled, legs: journey.legs)
    }

    private func roadRoute(from: RailCoordinate, to: RailCoordinate) async throws -> [RailCoordinate] {
        let coordinates = "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
        var components = URLComponents(string: "https://router.project-osrm.org/route/v1/driving/\(coordinates)")!
        components.queryItems = [URLQueryItem(name: "overview", value: "full"), URLQueryItem(name: "geometries", value: "geojson")]
        let response: OSRMResponse = try await get(components.url!)
        guard let points = response.routes.first?.geometry.coordinates.compactMap({ pair -> RailCoordinate? in
            guard pair.count >= 2 else { return nil }
            return RailCoordinate(latitude: pair[1], longitude: pair[0])
        }), points.count >= 2 else { throw RailSimulationError.missingGeometry }
        return points
    }

    private func mapRoute(from: RailCoordinate, to: RailCoordinate, transport: MKDirectionsTransportType) async throws -> [RailCoordinate] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
        request.transportType = transport
        let directions = MKDirections(request: request)
        return try await withThrowingTaskGroup(of: [RailCoordinate].self) { group in
            group.addTask {
                let response = try await directions.calculate()
                guard let polyline = response.routes.first?.polyline, polyline.pointCount >= 2 else {
                    throw RailSimulationError.missingGeometry
                }
                var coordinates = Array(repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
                polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
                let points = coordinates.compactMap { coordinate -> RailCoordinate? in
                    guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                    return RailCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                guard points.count >= 2 else { throw RailSimulationError.missingGeometry }
                return points
            }
            group.addTask {
                try await Task.sleep(for: .seconds(6))
                throw URLError(.timedOut)
            }
            defer {
                group.cancelAll()
                directions.cancel()
            }
            guard let result = try await group.next() else { throw URLError(.unknown) }
            return result
        }
    }

    private func railRoute(from: RailCoordinate, to: RailCoordinate, tram: Bool) async throws -> [RailCoordinate] {
        // A narrow corridor keeps the fallback query small enough for public
        // Overpass servers, while still covering normal Swiss track offsets.
        let padding = max(0.012, min(0.04, from.distance(to: to) / 150_000))
        let south = min(from.latitude, to.latitude) - padding
        let north = max(from.latitude, to.latitude) + padding
        let west = min(from.longitude, to.longitude) - padding
        let east = max(from.longitude, to.longitude) + padding
        let kinds = tram ? "rail|light_rail|tram" : "rail|narrow_gauge|light_rail"
        let query = "[out:json][timeout:25];way[\"railway\"~\"^(\(kinds))$\"](\(south),\(west),\(north),\(east));out geom;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OJPError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        let payload = try JSONDecoder().decode(OverpassResponse.self, from: data)
        var points: [Int64: RailCoordinate] = [:]
        var edges: [Int64: [(Int64, Double)]] = [:]
        for way in payload.elements where way.nodes.count == way.geometry.count {
            for (node, position) in zip(way.nodes, way.geometry) { points[node] = RailCoordinate(latitude: position.lat, longitude: position.lon) }
            for index in 1..<way.nodes.count {
                let a = way.nodes[index - 1], b = way.nodes[index]
                guard let pa = points[a], let pb = points[b] else { continue }
                let cost = pa.distance(to: pb)
                edges[a, default: []].append((b, cost)); edges[b, default: []].append((a, cost))
            }
        }
        guard let start = nearestNode(to: from, in: points), let end = nearestNode(to: to, in: points),
              let route = shortestPath(from: start, to: end, edges: edges), route.count >= 2 else { throw RailSimulationError.missingGeometry }
        guard let startPoint = points[start], let endPoint = points[end],
              from.distance(to: startPoint) <= 500, to.distance(to: endPoint) <= 500 else { throw RailSimulationError.missingGeometry }
        return [from] + route.compactMap { points[$0] } + [to]
    }

    private func nearestNode(to coordinate: RailCoordinate, in points: [Int64: RailCoordinate]) -> Int64? {
        points.min(by: { $0.value.distance(to: coordinate) < $1.value.distance(to: coordinate) })?.key
    }

    private func shortestPath(from start: Int64, to end: Int64, edges: [Int64: [(Int64, Double)]]) -> [Int64]? {
        var frontier: [(node: Int64, cost: Double)] = [(start, 0)]
        var costs: [Int64: Double] = [start: 0]
        var previous: [Int64: Int64] = [:]
        while !frontier.isEmpty {
            let next = frontier.removeFirst()
            guard next.cost == costs[next.node] else { continue }
            if next.node == end {
                var path = [end]; var cursor = end
                while let parent = previous[cursor] { path.append(parent); cursor = parent }
                return path.reversed()
            }
            for (neighbor, edgeCost) in edges[next.node, default: []] {
                let candidate = next.cost + edgeCost
                if candidate < (costs[neighbor] ?? .infinity) {
                    costs[neighbor] = candidate; previous[neighbor] = next.node
                    let position = frontier.firstIndex(where: { $0.cost > candidate }) ?? frontier.endIndex
                    frontier.insert((neighbor, candidate), at: position)
                }
            }
        }
        return nil
    }

    private func append(_ segment: [RailCoordinate], to path: inout [RailCoordinate]) {
        guard let first = segment.first else { return }
        if path.last?.distance(to: first) ?? .infinity > 1 { path.append(first) }
        path.append(contentsOf: segment.dropFirst())
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OJPError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct OSRMResponse: Decodable { let routes: [Route] }
    private struct Route: Decodable { let geometry: Geometry }
    private struct Geometry: Decodable { let coordinates: [[Double]] }
    private struct OverpassResponse: Decodable { let elements: [Way] }
    private struct Way: Decodable { let nodes: [Int64]; let geometry: [Position] }
    private struct Position: Decodable { let lat: Double; let lon: Double }
}
