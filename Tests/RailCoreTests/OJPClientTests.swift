import XCTest
@testable import RailCore

/// Hand-authored small fixtures follow the official OJP 2.0 cookbook structures.
/// They are not a recorded live service response and prove no live availability.
final class OJPClientTests: XCTestCase {
    func testPublishedOfficialCookbookResponse() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/official-lir-response.xml")
        let stations = try OJPXML.stations(from: Data(contentsOf: fixture))
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations[0].id, "ch:1:sloid:7000")
        XCTAssertEqual(stations[0].name, "Bern")
        XCTAssertEqual(stations[0].coordinate.latitude, 46.94883)
        XCTAssertEqual(stations[0].coordinate.longitude, 7.43913)
    }

    func testRequestRequiresRuntimeTokenAndUsesOfficialEndpoint() throws {
        XCTAssertThrowsError(try OJPClient.request(body: "", token: "  ")) { XCTAssertEqual($0 as? OJPError, .missingToken) }
        let request = try OJPClient.request(body: "<OJPLocationInformationRequest/>", token: "test-only")
        XCTAssertEqual(request.url?.absoluteString, "https://api.opentransportdata.swiss/ojp20")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/xml")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)!
        XCTAssertTrue(body.contains("version=\"2.0\""))
        XCTAssertFalse(body.contains("test-only"))
        XCTAssertEqual(OJPXML.escape("A&B<Z>\"'"), "A&amp;B&lt;Z&gt;&quot;&apos;")
    }

    func testStationParsingWithArbitraryNamespacePrefixesAndPlatformRefs() throws {
        let xml = """
        <x:OJP xmlns:x="http://www.vdv.de/ojp" xmlns:s="http://www.siri.org.uk/siri"><x:OJPResponse>
        <x:PlaceResult><x:Place><x:StopPlace><x:StopPlaceRef>ch:1:sloid:7000</x:StopPlaceRef><x:StopPlaceName><x:Text>Bern</x:Text></x:StopPlaceName></x:StopPlace><x:GeoPosition><s:Longitude>7.44</s:Longitude><s:Latitude>46.95</s:Latitude></x:GeoPosition><x:Mode><x:PtMode>rail</x:PtMode></x:Mode></x:Place></x:PlaceResult>
        <x:PlaceResult><x:Place><x:StopPlace><x:StopPlaceRef>bus1</x:StopPlaceRef></x:StopPlace><x:GeoPosition><s:Longitude>7.44</s:Longitude><s:Latitude>46.95</s:Latitude></x:GeoPosition><x:Mode><x:PtMode>bus</x:PtMode></x:Mode></x:Place></x:PlaceResult>
        </x:OJPResponse></x:OJP>
        """
        let stations = try OJPXML.stations(from: Data(xml.utf8))
        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.name, "Bern")
        XCTAssertEqual(stations.first?.coordinate.longitude, 7.44)
    }

    func testDirectRailJourneyKeepsGeometryStopTimesIdentityAndCancellation() throws {
        let parsed = try OJPXML.journeys(from: Data(trip().utf8), realtime: true)
        let item = try XCTUnwrap(parsed.first)
        XCTAssertEqual(item.reference.journeyRef, "ch:1:sjyid:100001:975-001")
        XCTAssertEqual(item.reference.operatingDay, "2026-10-29")
        XCTAssertEqual(item.journey.stops.map(\.name), ["Bern", "Test Mitte", "Test Ziel"])
        XCTAssertEqual(item.journey.geometry.count, 5)
        XCTAssertEqual(item.journey.serviceName, "IC6 975")
        XCTAssertNotNil(item.journey.stops[1].estimatedArrival)
        XCTAssertNotNil(item.journey.realtimeUpdatedAt)
        XCTAssertEqual(item.journey.geometry[1].longitude, 7.445)
        let namespaced = trip().replacingOccurrences(of: "<OJP>", with: "<OJP xmlns=\"http://www.vdv.de/ojp\" xmlns:siri=\"http://www.siri.org.uk/siri\" version=\"2.0\">")
            .replacingOccurrences(of: "<Longitude>", with: "<siri:Longitude>").replacingOccurrences(of: "</Longitude>", with: "</siri:Longitude>")
            .replacingOccurrences(of: "<Latitude>", with: "<siri:Latitude>").replacingOccurrences(of: "</Latitude>", with: "</siri:Latitude>")
            .replacingOccurrences(of: "<StopPointRef>", with: "<siri:StopPointRef>").replacingOccurrences(of: "</StopPointRef>", with: "</siri:StopPointRef>")
        XCTAssertEqual(try OJPXML.journeys(from: Data(namespaced.utf8), realtime: true)[0].journey.stops, item.journey.stops)
        let timestamped = trip().replacingOccurrences(of: "<OJP>", with: "<OJP><ResponseTimestamp>2026-10-29T12:01:00Z</ResponseTimestamp>")
        XCTAssertEqual(try OJPXML.journeys(from: Data(timestamped.utf8), realtime: true)[0].journey.realtimeUpdatedAt,
                       OJPXML.date("2026-10-29T12:01:00Z"))
        let cancelled = try OJPXML.journeys(from: Data(trip(cancelled: true).utf8), realtime: true)
        XCTAssertTrue(cancelled[0].journey.cancelled)
    }

    func testTimetableModeIgnoresEstimatesAndDoesNotClaimLiveFreshness() throws {
        let planned = try OJPXML.journeys(from: Data(trip().utf8), realtime: false)[0].journey
        XCTAssertNil(planned.stops[1].estimatedArrival)
        XCTAssertNil(planned.realtimeUpdatedAt)
        let noEstimates = trip().replacingOccurrences(of: "<EstimatedTime>2026-10-29T12:02:30Z</EstimatedTime>", with: "")
        XCTAssertNil(try OJPXML.journeys(from: Data(noEstimates.utf8), realtime: true)[0].journey.realtimeUpdatedAt)
    }

    func testMissingOrCoarseGeometryAndTransfersAreExplicitErrors() {
        XCTAssertThrowsError(try OJPXML.journeys(from: Data(trip(geometry: "").utf8), realtime: false)) {
            XCTAssertEqual($0 as? OJPError, .missingGeometry)
        }
        let endpointLine = "<LegTrack><TrackSection><LinkProjection>\(position(7.44))\(position(7.46))</LinkProjection></TrackSection></LegTrack>"
        XCTAssertThrowsError(try OJPXML.journeys(from: Data(trip(geometry: endpointLine).utf8), realtime: false)) {
            XCTAssertEqual($0 as? OJPError, .missingGeometry)
        }
        let transferred = trip().replacingOccurrences(of: "</Trip>", with: "<Leg><TransferLeg/></Leg></Trip>")
        XCTAssertThrowsError(try OJPXML.journeys(from: Data(transferred.utf8), realtime: false)) {
            XCTAssertEqual($0 as? OJPError, .unsupportedConnections)
        }
    }

    func testRefreshPreservesOnlyMatchingServiceShapeAndNeverInventsFreshness() throws {
        let original = try OJPXML.journeys(from: Data(trip().utf8), realtime: true)[0]
        let refreshed = try OJPXML.refreshedJourney(from: Data(info().utf8), original: original.journey, reference: original.reference)
        XCTAssertEqual(refreshed.geometry, original.journey.geometry)
        XCTAssertNil(refreshed.realtimeUpdatedAt)
        XCTAssertEqual(refreshed.id, original.journey.id)
        let changed = info().replacingOccurrences(of: "ch:1:sloid:7001", with: "ch:1:sloid:9999")
        XCTAssertThrowsError(try OJPXML.refreshedJourney(from: Data(changed.utf8), original: original.journey, reference: original.reference))
        let deviated = info().replacingOccurrences(of: "<Mode>", with: "<Deviation>true</Deviation><Mode>")
        XCTAssertThrowsError(try OJPXML.refreshedJourney(from: Data(deviated.utf8), original: original.journey, reference: original.reference)) {
            XCTAssertEqual($0 as? OJPError, .changedJourney)
        }
        let wrongDay = info().replacingOccurrences(of: "<OperatingDayRef>2026-10-29", with: "<OperatingDayRef>2026-10-30")
        XCTAssertThrowsError(try OJPXML.refreshedJourney(from: Data(wrongDay.utf8), original: original.journey, reference: original.reference)) {
            XCTAssertEqual($0 as? OJPError, .changedJourney)
        }
    }

    func testRefreshClipsWholeVehicleJourneyToSelectedSection() throws {
        let original = try OJPXML.journeys(from: Data(trip().utf8), realtime: true)[0]
        let calls = call("PreviousCall", ref: 6999, name: "Vorher", order: 0)
            + call("PreviousCall", ref: 7000, name: "Bern", order: 1)
            + call("OnwardCall", ref: 7001, name: "Test Mitte", order: 2)
            + call("OnwardCall", ref: 7002, name: "Test Ziel", order: 3)
        let geometry = "<JourneyTrack><TrackSection><LinkProjection>\(position(7.435))\(position(7.44))\(position(7.445))\(position(7.45))\(position(7.455))\(position(7.46))\(position(7.465))</LinkProjection></TrackSection></JourneyTrack>"
        let xml = "<OJP><TripInfoResult>\(calls)\(service())\(geometry)</TripInfoResult></OJP>"
        let refreshed = try OJPXML.refreshedJourney(from: Data(xml.utf8), original: original.journey, reference: original.reference)
        XCTAssertEqual(refreshed.stops.count, 3)
        XCTAssertEqual(refreshed.geometry.first?.longitude, 7.44)
        XCTAssertEqual(refreshed.geometry.last?.longitude, 7.46)
    }

    func testCancelledRefreshStopsEvenWhenCallsAndGeometryAreOmitted() throws {
        let original = try OJPXML.journeys(from: Data(trip().utf8), realtime: true)[0]
        let xml = "<OJP><TripInfoResult>\(service(cancelled: true))</TripInfoResult></OJP>"
        let cancelled = try OJPXML.refreshedJourney(from: Data(xml.utf8), original: original.journey, reference: original.reference)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertNil(cancelled.realtimeUpdatedAt)
        XCTAssertThrowsError(try RailSimulation(journey: cancelled, mode: .realtime)) {
            XCTAssertEqual($0 as? RailSimulationError, .cancelled)
        }
    }

    func testWholeJourneySelectsCorrectRepeatedStationOccurrenceByScheduledTime() throws {
        let original = try OJPXML.journeys(from: Data(trip().utf8), realtime: true)[0]
        // This train called at Bern earlier as well. Matching only the base stop
        // ID would pick that first call and erroneously change the selected leg.
        let earlier = call("PreviousCall", ref: 7000, name: "Bern", order: 0)
        let xml = info().replacingOccurrences(of: "<TripInfoResult>", with: "<TripInfoResult>\(earlier)")
        let refreshed = try OJPXML.refreshedJourney(from: Data(xml.utf8), original: original.journey, reference: original.reference)
        XCTAssertEqual(refreshed.stops.map(\.id), original.journey.stops.map(\.id))
        XCTAssertEqual(refreshed.stops.first?.scheduledDeparture, original.journey.stops.first?.scheduledDeparture)
    }

    func testMalformedAndServiceErrorsAndEntitiesAreRejected() {
        for xml in ["<OJP>", "<html/>", "<OJP><Status>false</Status></OJP>", "<!DOCTYPE OJP [<!ENTITY bad 'test'>]><OJP>&bad;</OJP>"] {
            XCTAssertThrowsError(try OJPXML.stations(from: Data(xml.utf8)), "Should reject: \(xml)")
        }
    }

    private func position(_ lon: Double) -> String {
        "<Position><Longitude>\(lon)</Longitude><Latitude>46.95</Latitude></Position>"
    }
    private func call(_ element: String, ref: Int, name: String, order: Int) -> String {
        """
        <\(element)><StopPointRef>ch:1:sloid:\(ref):0:1</StopPointRef><StopPointName><Text>\(name)</Text></StopPointName>
        <ServiceArrival><TimetabledTime>2026-10-29T12:0\(order):00Z</TimetabledTime></ServiceArrival>
        <ServiceDeparture><TimetabledTime>2026-10-29T12:0\(order):30Z</TimetabledTime></ServiceDeparture><Order>\(order)</Order></\(element)>
        """
    }
    private func service(cancelled: Bool = false) -> String {
        """
        <Service><OperatingDayRef>2026-10-29</OperatingDayRef><JourneyRef>ch:1:sjyid:100001:975-001</JourneyRef>
        <Mode><PtMode>rail</PtMode></Mode><PublishedServiceName><Text>IC6</Text></PublishedServiceName><TrainNumber>975</TrainNumber><Cancelled>\(cancelled)</Cancelled></Service>
        """
    }
    private func trip(geometry: String? = nil, cancelled: Bool = false) -> String {
        let places = [(7000, "Bern", 7.44), (7001, "Test Mitte", 7.45), (7002, "Test Ziel", 7.46)].map { id, name, lon in
            "<Place><StopPlace><StopPlaceRef>ch:1:sloid:\(id)</StopPlaceRef><StopPlaceName><Text>\(name)</Text></StopPlaceName></StopPlace><GeoPosition><Longitude>\(lon)</Longitude><Latitude>46.95</Latitude></GeoPosition></Place>"
        }.joined()
        let track = geometry ?? "<LegTrack><TrackSection><LinkProjection>\(position(7.44))\(position(7.445))\(position(7.45))\(position(7.455))\(position(7.46))</LinkProjection></TrackSection></LegTrack>"
        let middle = call("LegIntermediate", ref: 7001, name: "Test Mitte", order: 2)
            .replacingOccurrences(of: "</ServiceArrival>", with: "<EstimatedTime>2026-10-29T12:02:30Z</EstimatedTime></ServiceArrival>")
        let board = call("LegBoard", ref: 7000, name: "Bern", order: 1)
        let alight = call("LegAlight", ref: 7002, name: "Test Ziel", order: 3)
        return "<OJP><TripResponseContext><Places>\(places)</Places></TripResponseContext><TripResult><Trip><Leg><TimedLeg>\(board)\(middle)\(alight)\(service(cancelled: cancelled))\(track)</TimedLeg></Leg></Trip></TripResult></OJP>"
    }
    private func info() -> String {
        let calls = call("PreviousCall", ref: 7000, name: "Bern", order: 1)
            + call("OnwardCall", ref: 7001, name: "Test Mitte", order: 2)
            + call("OnwardCall", ref: 7002, name: "Test Ziel", order: 3)
        return "<OJP><TripInfoResult>\(calls)\(service())</TripInfoResult></OJP>"
    }
}
