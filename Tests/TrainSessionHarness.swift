import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
// Corelibs Foundation does not expose Apple's localized-string initializer.
extension String { init(localized value: String) { self = value } }
#endif

enum DeviceSessionPhase: Equatable {
    case idle, active, stopping, openingLocalDevVPN, discovering, connecting
    case failed(String)
}
enum PairingStatus { case paired, notPaired }
enum FixedCoordinateMode { case wgs84 }
struct SimulationCoordinates { let latitude: Double; let longitude: Double }
struct LocationTarget { let name: String; let subtitle: String; let latitude: Double; let longitude: Double }
enum UpdateResult { case updated, unavailable }

@MainActor final class StubDeviceSession {
    var phase: DeviceSessionPhase = .idle
    var updates = 0
    func updateLocation(_ target: LocationTarget, simulationCoordinates: SimulationCoordinates) -> UpdateResult {
        guard phase == .active else { return .unavailable }
        precondition(target.latitude.isFinite && target.longitude.isFinite)
        updates += 1
        return .updated
    }
}

@MainActor final class AppModel {
    var pairingStatus: PairingStatus = .paired
    var isStartingLocationSession = false
    var isRestoringInterruptedSession = false
    var interruptedSession: String?
    let deviceSession = StubDeviceSession()
    var startCalls = 0
    var stopCalls = 0
    var startupDelay: UInt64 = 0
    private var generation = 0

    func startLocationSession(at target: LocationTarget, coordinateMode: FixedCoordinateMode) async {
        startCalls += 1
        generation += 1
        let startGeneration = generation
        isStartingLocationSession = true
        if startupDelay > 0 { try? await Task.sleep(nanoseconds: startupDelay) }
        guard generation == startGeneration else { return }
        isStartingLocationSession = false
        deviceSession.phase = .active
    }

    func stopLocationSession() {
        generation += 1
        stopCalls += 1
        isStartingLocationSession = false
        deviceSession.phase = .idle
    }
}

final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var result = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            body = result
        }
        let xml = String(data: body ?? Data(), encoding: .utf8) ?? ""
        let response: String
        if xml.contains("OJPLocationInformationRequest") {
            response = Self.station(origin: xml.contains("Aarau"))
        } else {
            response = Self.trip()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func station(origin: Bool) -> String {
        let id = origin ? "7000" : "7002"
        let lon = origin ? "7.44" : "7.46"
        return "<OJP><PlaceResult><Place><StopPlace><StopPlaceRef>ch:1:sloid:\(id)</StopPlaceRef><StopPlaceName><Text>Fixture \(id)</Text></StopPlaceName></StopPlace><GeoPosition><Longitude>\(lon)</Longitude><Latitude>46.95</Latitude></GeoPosition><Mode><PtMode>rail</PtMode></Mode></Place></PlaceResult></OJP>"
    }

    private static func trip() -> String {
        let base = Date().addingTimeInterval(-30)
        let formatter = ISO8601DateFormatter()
        func time(_ delta: Double) -> String { formatter.string(from: base.addingTimeInterval(delta)) }
        let places = [(7000, 7.44), (7001, 7.45), (7002, 7.46)].map { id, lon in
            "<Place><StopPlace><StopPlaceRef>ch:1:sloid:\(id)</StopPlaceRef><StopPlaceName><Text>Fixture \(id)</Text></StopPlaceName></StopPlace><GeoPosition><Longitude>\(lon)</Longitude><Latitude>46.95</Latitude></GeoPosition></Place>"
        }.joined()
        func call(_ element: String, id: Int, arrival: Double, departure: Double) -> String {
            "<\(element)><StopPointRef>ch:1:sloid:\(id):0:1</StopPointRef><StopPointName><Text>Fixture \(id)</Text></StopPointName><ServiceArrival><TimetabledTime>\(time(arrival))</TimetabledTime></ServiceArrival><ServiceDeparture><TimetabledTime>\(time(departure))</TimetabledTime></ServiceDeparture></\(element)>"
        }
        let calls = call("LegBoard", id: 7000, arrival: 0, departure: 0)
            + call("LegIntermediate", id: 7001, arrival: 120, departure: 180)
            + call("LegAlight", id: 7002, arrival: 300, departure: 300)
        let track = [7.44, 7.445, 7.45, 7.455, 7.46].map {
            "<Position><Longitude>\($0)</Longitude><Latitude>46.95</Latitude></Position>"
        }.joined()
        return "<OJP><TripResponseContext><Places>\(places)</Places></TripResponseContext><TripResult><Trip><Leg><TimedLeg>\(calls)<Service><OperatingDayRef>2026-10-29</OperatingDayRef><JourneyRef>test-only</JourneyRef><Mode><PtMode>rail</PtMode></Mode><PublishedServiceName><Text>Fixture IR</Text></PublishedServiceName></Service><LegTrack><TrackSection><LinkProjection>\(track)</LinkProjection></TrackSection></LegTrack></TimedLeg></Leg></Trip></TripResult></OJP>"
    }
}

@main @MainActor struct TrainSessionHarness {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = TrainModel()
        model.configure(token: "offline-test-only", session: session)
        await model.searchStations()
        precondition(model.origin != nil && model.destination != nil, "Fixture stations must load")
        await model.findConnections()
        precondition(model.selectedJourney != nil, "Fixture connection must load")
        let app = AppModel()

        app.pairingStatus = .notPaired
        await model.start(using: app)
        precondition(app.startCalls == 0 && !model.locksControls, "Unpaired startup must not start a session")

        app.pairingStatus = .paired
        app.deviceSession.phase = .active
        await model.start(using: app)
        precondition(app.startCalls == 0 && !model.locksControls, "Busy session must not be replaced")

        app.deviceSession.phase = .idle
        await model.start(using: app)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.isRunning && app.startCalls == 1 && app.deviceSession.updates > 0,
                     "Paired idle startup must begin coordinate updates")
        model.stop(using: app)
        let updatesAfterStop = app.deviceSession.updates
        try await Task.sleep(nanoseconds: 1_100_000_000)
        precondition(!model.locksControls && app.stopCalls == 1 && app.deviceSession.updates == updatesAfterStop,
                     "Stop must cancel all later movement updates")

        app.startupDelay = 300_000_000
        let pendingStart = Task { await model.start(using: app) }
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(model.isPreparing, "Delayed startup must expose preparing state")
        model.stop(using: app)
        await pendingStart.value
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!model.locksControls && app.deviceSession.phase == .idle,
                     "Cancelled preparation must not resume coordinate updates")

        app.startupDelay = 0
        await model.start(using: app)
        try await Task.sleep(nanoseconds: 100_000_000)
        app.deviceSession.phase = .failed("fixture failure")
        model.handleDevicePhase(app.deviceSession.phase)
        let updatesAfterFailure = app.deviceSession.updates
        try await Task.sleep(nanoseconds: 1_100_000_000)
        precondition(!model.locksControls && app.deviceSession.updates == updatesAfterFailure,
                     "Device failure must cancel later movement updates")
        print("PASS: actual TrainModel lifecycle, actual OJP client with offline fixtures, actual rail core; 5 scenarios")
    }
}
