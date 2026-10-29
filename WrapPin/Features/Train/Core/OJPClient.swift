import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

struct OJPStation: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let coordinate: RailCoordinate
}

typealias TransitStop = OJPStation

enum TransitVehicle: String, Sendable {
    case train, tram, bus, ship, cableway, unknown
}

struct TransitConnection: Identifiable, Sendable {
    let id: String
    let journey: RailJourney
    let vehicle: TransitVehicle
    let departure: Date
    let arrival: Date
}

/// Public Swiss timetable API. It requires no user token and is deliberately
/// separate from the optional official OJP client below.
actor PublicTransitClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: c)
        }
    }

    func searchStops(query: String) async throws -> [TransitStop] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        var c = URLComponents(string: "https://transport.opendata.ch/v1/locations")!
        c.queryItems = [URLQueryItem(name: "query", value: query)]
        let payload: LocationsResponse = try await get(c.url!)
        var seen = Set<String>()
        return payload.stations.compactMap { item in
            guard let id = item.id, let coordinate = item.coordinate,
                  coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                  seen.insert(id).inserted else { return nil }
            return TransitStop(id: id, name: item.name, coordinate: RailCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }

    func connections(from: TransitStop, to: TransitStop, departure: Date) async throws -> [TransitConnection] {
        var c = URLComponents(string: "https://transport.opendata.ch/v1/connections")!
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        c.queryItems = [URLQueryItem(name: "from", value: from.id), URLQueryItem(name: "to", value: to.id), URLQueryItem(name: "date", value: f.string(from: departure)), URLQueryItem(name: "limit", value: "6")]
        let payload: ConnectionsResponse = try await get(c.url!)
        return payload.connections.enumerated().compactMap { index, item in
            guard let dep = item.from.departureDate, let arr = item.to.arrivalDate else { return nil }
            let category = item.sections.first?.journey?.category?.lowercased() ?? ""
            let vehicle: TransitVehicle = category.contains("bus") ? .bus : category.contains("tram") ? .tram : category.contains("ship") ? .ship : category.isEmpty ? .unknown : .train
            let stops = [RailStop(id: from.id, name: from.name, coordinate: from.coordinate, scheduledArrival: nil, scheduledDeparture: dep), RailStop(id: to.id, name: to.name, coordinate: to.coordinate, scheduledArrival: arr, scheduledDeparture: nil)]
            let service = item.sections.first?.journey?.name ?? "Connection"
            let journey = RailJourney(id: "public-\(index)-\(from.id)-\(to.id)", serviceName: "\(vehicle.rawValue.capitalized) · \(service)", stops: stops, geometry: [from.coordinate, to.coordinate], geometrySource: "Public Swiss timetable · simplified connection geometry")
            return TransitConnection(id: journey.id, journey: journey, vehicle: vehicle, departure: dep, arrival: arr)
        }
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw OJPError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct LocationsResponse: Decodable { let stations: [Location] }
    private struct Location: Decodable { let id: String?; let name: String; let coordinate: Coordinate? }
    private struct Coordinate: Decodable { let x: Double; let y: Double; var latitude: Double { y }; var longitude: Double { x } }
    private struct ConnectionsResponse: Decodable { let connections: [Connection] }
    private struct Connection: Decodable { let from: Point; let to: Point; let sections: [Section] }
    private struct Point: Decodable { let departure: String?; let arrival: String?; var departureDate: Date? { PublicTransitClient.parse(departure) }; var arrivalDate: Date? { PublicTransitClient.parse(arrival) } }
    private struct Section: Decodable { let journey: Journey? }
    private struct Journey: Decodable { let name: String?; let category: String? }
    private static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] { f.dateFormat = format; if let date = f.date(from: value) { return date } }
        return nil
    }
}

enum OJPError: Error, LocalizedError, Equatable {
    case missingToken, unauthorized, rateLimited, http(Int), malformedXML
    case serviceError, noConnections, unsupportedConnections, missingGeometry, missingStopCoordinates
    case unknownJourney, changedJourney

    var errorDescription: String? {
        switch self {
        case .missingToken: "Enter your personal OJP 2.0 API token first."
        case .unauthorized: "OJP rejected the API token. Check its OJP 2.0 subscription."
        case .rateLimited: "OJP request limit reached. Wait before trying again."
        case .http(let status): "OJP could not answer the request (HTTP \(status))."
        case .malformedXML: "OJP returned an unreadable response."
        case .serviceError: "OJP reported a service error. Try another date or station."
        case .noConnections: "No train connections were returned for this search."
        case .unsupportedConnections: "This MVP supports direct train connections only. Choose stations linked by one train."
        case .missingGeometry: "No sufficiently detailed rail geometry is available for this connection."
        case .missingStopCoordinates: "OJP did not provide coordinates for every stop."
        case .unknownJourney: "Search this connection again before refreshing it."
        case .changedJourney: "The service or stop sequence changed. Stop and select the connection again."
        }
    }
}

struct OJPJourneyReference: Equatable, Sendable {
    let journeyRef: String
    let operatingDay: String
    let boardingRef: String
    let alightingRef: String
}

struct OJPParsedJourney: Sendable {
    let journey: RailJourney
    let reference: OJPJourneyReference
}

/// Official OJP only. Tokens stay in memory, are never logged or embedded in a build.
actor OJPClient {
    static let endpoint = URL(string: "https://api.opentransportdata.swiss/ojp20")!
    private let token: String
    private let session: URLSession
    private var nextRequestAt = Date.distantPast
    private var references: [String: OJPJourneyReference] = [:]
    private var refreshes: [String: (Date, RailJourney)] = [:]

    init(token: String, session: URLSession? = nil) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func searchStations(named name: String) async throws -> [OJPStation] {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        let body = """
        <OJPLocationInformationRequest><siri:RequestTimestamp>\(OJPXML.timestamp(Date()))</siri:RequestTimestamp>
        <InitialInput><Name>\(OJPXML.escape(name))</Name></InitialInput><Restrictions><Type>stop</Type>
        <Modes><Exclude>false</Exclude><PtMode>rail</PtMode></Modes><NumberOfResults>8</NumberOfResults></Restrictions></OJPLocationInformationRequest>
        """
        return try OJPXML.stations(from: await send(body))
    }

    func connections(from origin: OJPStation, to destination: OJPStation,
                     departure: Date, realtime: Bool) async throws -> [RailJourney] {
        let body = """
        <OJPTripRequest><siri:RequestTimestamp>\(OJPXML.timestamp(Date()))</siri:RequestTimestamp>
        <Origin><PlaceRef><StopPlaceRef>\(OJPXML.escape(origin.id))</StopPlaceRef><Name><Text>\(OJPXML.escape(origin.name))</Text></Name></PlaceRef><DepArrTime>\(OJPXML.timestamp(departure))</DepArrTime></Origin>
        <Destination><PlaceRef><StopPlaceRef>\(OJPXML.escape(destination.id))</StopPlaceRef><Name><Text>\(OJPXML.escape(destination.name))</Text></Name></PlaceRef></Destination>
        <Params><ModeAndModeOfOperationFilter><Exclude>false</Exclude><PtMode>rail</PtMode></ModeAndModeOfOperationFilter>
        <NumberOfResults>5</NumberOfResults><UseRealtimeData>\(realtime ? "explanatory" : "none")</UseRealtimeData><TransferLimit>0</TransferLimit>
        <IncludeTrackSections>true</IncludeTrackSections><IncludeLegProjection>true</IncludeLegProjection><IncludeIntermediateStops>true</IncludeIntermediateStops></Params></OJPTripRequest>
        """
        let parsed = try OJPXML.journeys(from: await send(body), realtime: realtime,
                                         knownStations: [origin, destination])
        for item in parsed { references[item.journey.id] = item.reference }
        return parsed.map(\.journey)
    }

    func refresh(_ journey: RailJourney) async throws -> RailJourney {
        guard let reference = references[journey.id] else { throw OJPError.unknownJourney }
        if let cached = refreshes[journey.id], Date().timeIntervalSince(cached.0) < 30 { return cached.1 }
        let body = """
        <OJPTripInfoRequest><siri:RequestTimestamp>\(OJPXML.timestamp(Date()))</siri:RequestTimestamp>
        <JourneyRef>\(OJPXML.escape(reference.journeyRef))</JourneyRef><OperatingDayRef>\(OJPXML.escape(reference.operatingDay))</OperatingDayRef>
        <Params><UseRealTimeData>explanatory</UseRealTimeData><IncludeCalls>true</IncludeCalls><IncludeService>true</IncludeService>
        <IncludeTrackSections>true</IncludeTrackSections><IncludeTrackProjection>true</IncludeTrackProjection><IncludePlacesContext>true</IncludePlacesContext></Params></OJPTripInfoRequest>
        """
        let updated = try OJPXML.refreshedJourney(from: await send(body), original: journey, reference: reference)
        refreshes[journey.id] = (Date(), updated)
        return updated
    }

    private func send(_ body: String) async throws -> Data {
        let request = try Self.request(body: body, token: token)
        // Actor reserves its slot before suspension, including concurrent callers.
        let slot = max(nextRequestAt, Date())
        nextRequestAt = slot.addingTimeInterval(1.25)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OJPError.http(0) }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw OJPError.unauthorized
        case 429:
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(max(30, min(retry, 3600))))
            throw OJPError.rateLimited
        default: throw OJPError.http(http.statusCode)
        }
        guard data.count <= 12_000_000 else { throw OJPError.malformedXML }
        return data
    }

    static func request(body: String, token: String, now: Date = Date()) throws -> URLRequest {
        let key = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OJPError.missingToken }
        guard !key.contains("\r"), !key.contains("\n") else { throw OJPError.unauthorized }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("WrapPinRailLab/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <OJP xmlns="http://www.vdv.de/ojp" xmlns:siri="http://www.siri.org.uk/siri" version="2.0"><OJPRequest><siri:ServiceRequest>
        <siri:ServiceRequestContext><siri:Language>de</siri:Language></siri:ServiceRequestContext>
        <siri:RequestTimestamp>\(OJPXML.timestamp(now))</siri:RequestTimestamp><siri:RequestorRef>WrapPinRailLab_test</siri:RequestorRef>
        \(body)</siri:ServiceRequest></OJPRequest></OJP>
        """.utf8)
        return request
    }
}

/// Small namespace-tolerant OJP 2.0 parser. It never fabricates rail geometry.
enum OJPXML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func stations(from data: Data) throws -> [OJPStation] {
        let root = try parse(data)
        var seen = Set<String>()
        return root.descendants("PlaceResult").compactMap { result in
            guard let place = result.child("Place"), let station = station(place),
                  seen.insert(station.id).inserted else { return nil }
            let modes = place.descendants("PtMode").map(\.value)
            guard modes.isEmpty || modes.contains("rail") else { return nil }
            return station
        }
    }

    static func journeys(from data: Data, realtime: Bool,
                         knownStations: [OJPStation] = [], receivedAt: Date = Date()) throws -> [OJPParsedJourney] {
        let root = try parse(data)
        let places = placeMap(root, known: knownStations)
        let trips = root.descendants("TripResult").compactMap { $0.child("Trip") }
        guard !trips.isEmpty else { throw OJPError.noConnections }
        var output: [OJPParsedJourney] = []
        var lastError: OJPError = .unsupportedConnections
        for trip in trips {
            let legs = trip.children.filter { $0.name == "Leg" }
            guard legs.count == 1, let timed = legs[0].child("TimedLeg"),
                  let service = timed.child("Service"), service.descendants("PtMode").first?.value == "rail" else { continue }
            do {
                let calls = timed.children.filter { ["LegBoard", "LegIntermediate", "LegAlight"].contains($0.name) }
                let stops = try calls.map { try stop($0, places: places, realtime: realtime) }
                guard stops.count >= 2, let journeyRef = service.text("JourneyRef"),
                      let operatingDay = service.text("OperatingDayRef") else { throw OJPError.serviceError }
                let reference = OJPJourneyReference(journeyRef: journeyRef, operatingDay: operatingDay,
                                                   boardingRef: stops[0].id, alightingRef: stops[stops.count - 1].id)
                let geometry = try checkedGeometry(timed.child("LegTrack"))
                let id = [journeyRef, operatingDay, reference.boardingRef, reference.alightingRef].joined(separator: "|")
                let cancelled = trip.flag("Cancelled") || service.flag("Cancelled")
                let journey = RailJourney(id: id, serviceName: serviceName(service), stops: stops,
                                          geometry: geometry, geometrySource: "opentransportdata.swiss OJP LinkProjection",
                                          realtimeUpdatedAt: hasEstimates(stops) && realtime ? responseDate(root, fallback: receivedAt) : nil,
                                          cancelled: cancelled)
                output.append(OJPParsedJourney(journey: journey, reference: reference))
            } catch let error as OJPError { lastError = error }
        }
        guard !output.isEmpty else { throw lastError }
        return output
    }

    static func refreshedJourney(from data: Data, original: RailJourney, reference: OJPJourneyReference,
                                 receivedAt: Date = Date()) throws -> RailJourney {
        let root = try parse(data)
        guard let result = root.descendants("TripInfoResult").first,
              let service = result.child("Service"),
              service.text("JourneyRef") == reference.journeyRef,
              service.text("OperatingDayRef") == reference.operatingDay,
              service.descendants("PtMode").first?.value == "rail" else { throw OJPError.changedJourney }
        // An explanatory cancellation may omit the now irrelevant calls/track.
        // Propagate it immediately so playback stops, rather than treating it as
        // a temporary parse/network failure until the old forecast expires.
        if service.flag("Cancelled") || result.flag("Cancelled") {
            return RailJourney(id: original.id, serviceName: original.serviceName, stops: original.stops,
                               geometry: original.geometry, geometrySource: original.geometrySource,
                               realtimeUpdatedAt: nil, cancelled: true)
        }
        // A backend may still return the previous projection during a reported
        // deviation. Identical coordinates do not prove the route is unchanged.
        guard !service.flag("Deviation"), !result.flag("Deviation") else { throw OJPError.changedJourney }
        let known = original.stops.map { OJPStation(id: $0.id, name: $0.name, coordinate: $0.coordinate) }
        let places = placeMap(root, known: known)
        let calls = result.children.enumerated().filter { ["PreviousCall", "ThisCall", "OnwardCall"].contains($0.element.name) }
            .sorted { (Int($0.element.text("Order") ?? "") ?? $0.offset) < (Int($1.element.text("Order") ?? "") ?? $1.offset) }
            .map(\.element)
        guard let selectedBoard = original.stops.first, let selectedAlight = original.stops.last,
              let start = calls.firstIndex(where: {
                  sameStop($0.text("StopPointRef") ?? "", reference.boardingRef)
                      && matchesScheduledCall($0, stop: selectedBoard, boarding: true)
              }),
              let end = calls.indices.first(where: {
                  $0 > start && sameStop(calls[$0].text("StopPointRef") ?? "", reference.alightingRef)
                      && matchesScheduledCall(calls[$0], stop: selectedAlight, boarding: false)
              })
        else { throw OJPError.changedJourney }
        let stops = try calls[start...end].map { try stop($0, places: places, realtime: true) }
        let sameSequence = stops.map { baseStop($0.id) } == original.stops.map { baseStop($0.id) }
        let hasProjection = !(result.child("JourneyTrack")?.descendants("LinkProjection").isEmpty ?? true)
        let geometry: [RailCoordinate]
        if hasProjection {
            geometry = try clip(checkedGeometry(result.child("JourneyTrack")), start: stops[0].coordinate,
                                end: stops[stops.count - 1].coordinate)
        } else {
            guard sameSequence, !service.flag("Deviation"), !result.flag("Deviation") else { throw OJPError.changedJourney }
            geometry = original.geometry
        }
        return RailJourney(id: original.id, serviceName: serviceName(service), stops: stops,
                           geometry: geometry, geometrySource: original.geometrySource,
                           realtimeUpdatedAt: hasEstimates(stops) ? responseDate(root, fallback: receivedAt) : nil,
                           cancelled: service.flag("Cancelled") || result.flag("Cancelled"))
    }

    private static func hasEstimates(_ stops: [RailStop]) -> Bool {
        stops.contains { $0.estimatedArrival != nil || $0.estimatedDeparture != nil }
    }
    private static func responseDate(_ root: OJPNode, fallback: Date) -> Date {
        date(root.descendants("ResponseTimestamp").first?.value) ?? fallback
    }
    private static func serviceName(_ service: OJPNode) -> String {
        let published = service.child("PublishedServiceName")?.text("Text") ?? "Train"
        if let number = service.text("TrainNumber"), !published.contains(number) { return "\(published) \(number)" }
        return published
    }
    private static func baseStop(_ ref: String) -> String {
        guard ref.hasPrefix("ch:1:sloid:") else { return ref }
        return ref.split(separator: ":").prefix(4).joined(separator: ":")
    }
    private static func sameStop(_ a: String, _ b: String) -> Bool { baseStop(a) == baseStop(b) }
    private static func matchesScheduledCall(_ node: OJPNode, stop: RailStop, boarding: Bool) -> Bool {
        // A whole vehicle journey can visit one station more than once. Stop ID
        // alone cannot identify the selected occurrence; planned event times can.
        if boarding, let departure = stop.scheduledDeparture {
            return date(node.child("ServiceDeparture")?.text("TimetabledTime")) == departure
        }
        if let arrival = stop.scheduledArrival {
            return date(node.child("ServiceArrival")?.text("TimetabledTime")) == arrival
        }
        if let departure = stop.scheduledDeparture {
            return date(node.child("ServiceDeparture")?.text("TimetabledTime")) == departure
        }
        return false
    }
    private static func coordinate(_ node: OJPNode?) -> RailCoordinate? {
        guard let node, let lat = Double(node.text("Latitude") ?? ""), let lon = Double(node.text("Longitude") ?? ""),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return RailCoordinate(latitude: lat, longitude: lon)
    }
    private static func station(_ place: OJPNode) -> OJPStation? {
        let stopPlace = place.child("StopPlace") ?? place.child("StopPoint")
        guard let ref = stopPlace?.text("StopPlaceRef") ?? stopPlace?.text("StopPointRef"),
              let point = coordinate(place.child("GeoPosition")) else { return nil }
        let name = stopPlace?.child("StopPlaceName")?.text("Text") ?? stopPlace?.child("StopPointName")?.text("Text")
            ?? place.child("Name")?.text("Text") ?? ref
        return OJPStation(id: ref, name: name, coordinate: point)
    }
    private static func placeMap(_ root: OJPNode, known: [OJPStation]) -> [String: OJPStation] {
        var map: [String: OJPStation] = [:]
        for item in known + root.descendants("Place").compactMap({ station($0) }) {
            map[item.id] = item
            if map[baseStop(item.id)] == nil { map[baseStop(item.id)] = item }
        }
        return map
    }
    private static func stop(_ node: OJPNode, places: [String: OJPStation], realtime: Bool) throws -> RailStop {
        guard let ref = node.text("StopPointRef") else { throw OJPError.serviceError }
        guard let point = coordinate(node.child("GeoPosition")) ?? places[ref]?.coordinate ?? places[baseStop(ref)]?.coordinate
        else { throw OJPError.missingStopCoordinates }
        let arrival = node.child("ServiceArrival"), departure = node.child("ServiceDeparture")
        return RailStop(id: ref, name: node.child("StopPointName")?.text("Text") ?? places[ref]?.name ?? ref,
                        coordinate: point, scheduledArrival: date(arrival?.text("TimetabledTime")),
                        scheduledDeparture: date(departure?.text("TimetabledTime")),
                        estimatedArrival: realtime ? date(arrival?.text("EstimatedTime")) : nil,
                        estimatedDeparture: realtime ? date(departure?.text("EstimatedTime")) : nil,
                        cancelled: node.flag("Cancelled") || node.flag("NotServicedStop"))
    }
    private static func checkedGeometry(_ track: OJPNode?) throws -> [RailCoordinate] {
        guard let track else { throw OJPError.missingGeometry }
        let projections = track.descendants("LinkProjection")
        var points: [RailCoordinate] = []
        for projection in projections {
            for position in projection.children.filter({ $0.name == "Position" }) {
                guard let point = coordinate(position) else { throw OJPError.missingGeometry }
                if let last = points.last, distance(last, point) < 0.01 { continue }
                points.append(point)
            }
        }
        // A bare station-to-station line is not a detailed rail route. Also refuse
        // large gaps rather than silently connecting disconnected track sections.
        guard points.count >= 3, zip(points, points.dropFirst()).allSatisfy({ distance($0, $1) <= 3_000 })
        else { throw OJPError.missingGeometry }
        return points
    }
    private static func clip(_ points: [RailCoordinate], start: RailCoordinate, end: RailCoordinate) throws -> [RailCoordinate] {
        guard let first = points.indices.min(by: { distance(points[$0], start) < distance(points[$1], start) }),
              let last = points.indices.filter({ $0 > first }).min(by: { distance(points[$0], end) < distance(points[$1], end) }),
              last - first >= 2, distance(points[first], start) < 1_500, distance(points[last], end) < 1_500
        else { throw OJPError.missingGeometry }
        return Array(points[first...last])
    }
    private static func distance(_ a: RailCoordinate, _ b: RailCoordinate) -> Double {
        let rad = Double.pi / 180
        let h = pow(sin((b.latitude - a.latitude) * rad / 2), 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin((b.longitude - a.longitude) * rad / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }
    private static func parse(_ data: Data) throws -> OJPNode {
        // OJP's UTF-8 payload needs no DTD or custom entities. Reject these
        // declarations before parsing as XMLParser delegate callbacks differ
        // across Foundation platforms.
        guard data.count <= 12_000_000, let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { throw OJPError.malformedXML }
        let delegate = OJPTreeParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil, !delegate.rejected,
              delegate.stack.isEmpty, delegate.finishedDocument,
              let root = delegate.root, root.name == "OJP" else { throw OJPError.malformedXML }
        guard !root.descendants("Status").contains(where: { $0.value.lowercased() == "false" }),
              root.descendants("ErrorCondition").isEmpty else { throw OJPError.serviceError }
        return root
    }
}

private final class OJPNode {
    let name: String
    var rawText = ""
    var children: [OJPNode] = []
    var value: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(_ name: String) { self.name = name.split(separator: ":").last.map(String.init) ?? name }
    func child(_ name: String) -> OJPNode? { children.first { $0.name == name } }
    func text(_ name: String) -> String? { child(name).map(\.value).flatMap { $0.isEmpty ? nil : $0 } }
    func flag(_ name: String) -> Bool { ["true", "1"].contains(text(name)?.lowercased() ?? "") }
    func descendants(_ name: String) -> [OJPNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
}

private final class OJPTreeParser: NSObject, XMLParserDelegate {
    var root: OJPNode?
    var stack: [OJPNode] = []
    var count = 0
    var rejected = false
    var finishedDocument = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 80, count <= 180_000 else { rejected = true; parser.abortParsing(); return }
        let node = OJPNode(elementName)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.rawText.append(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parserDidEndDocument(_ parser: XMLParser) { finishedDocument = true }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { rejected = true }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejected = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejected = true; parser.abortParsing() }
}
