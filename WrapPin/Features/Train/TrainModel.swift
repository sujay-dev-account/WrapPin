#if WRAPPIN_SBB_EDITION
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// Owns the rail session. The existing AppModel retains pairing, recovery and
/// the native location service; neither the Rust bridge nor its protocol changes.
@MainActor @Observable
final class TrainModel {
    var originQuery = "Aarau"
    var destinationQuery = "Zürich HB"
    var origin: TransitStop?
    var destination: TransitStop?
    private(set) var originResults: [TransitStop] = []
    private(set) var destinationResults: [TransitStop] = []
    var departure = Date.now
    var mode: RailSimulationMode = .timetable
    private(set) var journeys: [RailJourney] = []
    var selectedID: String?
    private(set) var isLoading = false
    private(set) var isRunning = false
    private(set) var isPreparing = false
    private(set) var isStopping = false
    private(set) var message: String?
    private(set) var sample: RailSample?
    private(set) var renderedCoordinate: RailCoordinate?
    private(set) var renderedSpeed = 0.0
    private(set) var refreshWarning: String?

    @ObservationIgnored private var client = PublicTransitClient()
    @ObservationIgnored private var geometryResolver = PublicTransitGeometryResolver()
    @ObservationIgnored private var movementTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var engine: RailSimulation?
    @ObservationIgnored private var activeJourney: RailJourney?
    @ObservationIgnored private var clockOffset: TimeInterval = 0
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var renderedDistance = 0.0
    @ObservationIgnored private var motion = RailMotionLimiter()
    @ObservationIgnored private var originSearchTask: Task<Void, Never>?
    @ObservationIgnored private var destinationSearchTask: Task<Void, Never>?

    var selectedJourney: RailJourney? { journeys.first { $0.id == selectedID } }
    var locksControls: Bool { isRunning || isPreparing || isStopping }

    func searchStations(forOrigin: Bool) async {
        guard !isLoading, !locksControls else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let query = forOrigin ? originQuery : destinationQuery
            let result = try await client.searchStops(query: query)
            guard query == (forOrigin ? originQuery : destinationQuery) else { return }
            if forOrigin { originResults = result } else { destinationResults = result }
            if result.isEmpty { message = String(localized: "No stops found. Try another name.") }
        } catch { message = error.localizedDescription }
    }

    func scheduleStationSearch(forOrigin: Bool) {
        let query = (forOrigin ? originQuery : destinationQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if forOrigin {
                originSearchTask?.cancel()
                originSearchTask = nil
                originResults = []
            } else {
                destinationSearchTask?.cancel()
                destinationSearchTask = nil
                destinationResults = []
            }
            return
        }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.searchStations(forOrigin: forOrigin)
        }
        if forOrigin {
            originSearchTask?.cancel()
            originSearchTask = task
        } else {
            destinationSearchTask?.cancel()
            destinationSearchTask = task
        }
    }

    func findConnections() async {
        guard let origin, let destination,
              origin.id != destination.id, !isLoading, !locksControls else { return }
        isLoading = true
        message = nil
        journeys = []
        selectedID = nil
        defer { isLoading = false }
        do {
            journeys = try await client.connections(from: origin, to: destination, departure: departure).map(\.journey)
            selectedID = journeys.first?.id
        } catch { message = error.localizedDescription }
    }

    func clearConnections() {
        guard !locksControls else { return }
        journeys = []
        selectedID = nil
        sample = nil
        renderedCoordinate = nil
    }

    func invalidateStation(forOrigin: Bool) {
        guard !locksControls else { return }
        if forOrigin {
            origin = nil
            originResults = []
        } else {
            destination = nil
            destinationResults = []
        }
        clearConnections()
    }

    func start(using app: AppModel) async {
        guard let journey = selectedJourney, !locksControls, !isLoading else { return }
        guard case .paired = app.pairingStatus else {
            message = String(localized: "Pair this iPhone before starting a route session.")
            return
        }
        guard !app.isStartingLocationSession, !app.isRestoringInterruptedSession,
              app.interruptedSession == nil else { return }
        switch app.deviceSession.phase {
        case .idle, .failed: break
        default:
            message = String(localized: "Stop the existing location session before starting a train.")
            return
        }
        isPreparing = true
        var openedLocationSession = false
        defer {
            if !openedLocationSession { isPreparing = false }
        }
        do {
            message = String(localized: "Loading route geometry from open map data…")
            let resolvedJourney = try await geometryResolver.resolve(journey)
            guard !Task.isCancelled, selectedID == journey.id else { return }
            if let index = journeys.firstIndex(where: { $0.id == journey.id }) { journeys[index] = resolvedJourney }
            let now = Date.now
            let newEngine = try RailSimulation(journey: resolvedJourney, mode: mode, now: now)
            // Timetable is replayed from its first planned departure. Live mode
            // stays on the actual clock and is always labelled as an estimate.
            let firstDeparture = resolvedJourney.stops.first?.scheduledDeparture
                ?? resolvedJourney.stops.first?.scheduledArrival ?? now
            clockOffset = mode == .timetable ? firstDeparture.timeIntervalSince(now) : 0
            let initial = newEngine.sample(at: now.addingTimeInterval(clockOffset))
            if mode == .realtime, initial.realtimeStatus != .estimated {
                message = String(localized: "Fresh predictions are unavailable. Choose timetable mode explicitly.")
                return
            }
            engine = newEngine
            activeJourney = resolvedJourney
            sample = initial
            renderedCoordinate = initial.coordinate
            renderedDistance = initial.distanceMetres
            motion = RailMotionLimiter(initialDistanceMetres: initial.distanceMetres)
            renderedSpeed = 0
            refreshWarning = nil
            message = nil
            await app.startLocationSession(at: target(initial.coordinate), coordinateMode: .wgs84)
            guard isPreparing else { return }
            openedLocationSession = true
            beginTicks(using: app)
            if mode == .realtime { beginRefresh(using: app) }
        } catch { message = error.localizedDescription }
    }

    func stop(using app: AppModel) {
        movementTask?.cancel()
        refreshTask?.cancel()
        movementTask = nil
        refreshTask = nil
        isRunning = false
        isPreparing = false
        isStopping = true
        app.stopLocationSession()
        handleDevicePhase(app.deviceSession.phase)
    }

    func handleDevicePhase(_ phase: DeviceSessionPhase) {
        if case .idle = phase, isStopping { isStopping = false }
        if case .failed(let failure) = phase, locksControls {
            movementTask?.cancel()
            refreshTask?.cancel()
            isRunning = false
            isPreparing = false
            isStopping = false
            message = failure
        }
    }

    private func fail(_ reason: String, using app: AppModel) {
        message = reason
        stop(using: app)
    }

    private func beginTicks(using app: AppModel) {
        movementTask?.cancel()
        lastTick = nil
        movementTask = Task { @MainActor [weak self, weak app] in
            while !Task.isCancelled {
                guard let self, let app else { return }
                switch app.deviceSession.phase {
                case .active:
                    if self.isPreparing {
                        self.isPreparing = false
                        self.isRunning = true
                        self.lastTick = Date.now
                        if self.mode == .timetable,
                           let first = self.activeJourney?.stops.first,
                           let departure = first.scheduledDeparture ?? first.scheduledArrival {
                            self.clockOffset = departure.timeIntervalSince(.now)
                        }
                    }
                    self.tick(using: app)
                case .failed(let error):
                    self.fail(error, using: app)
                    return
                case .idle:
                    if !app.isStartingLocationSession {
                        self.fail(String(localized: "The train location session ended."), using: app)
                        return
                    }
                case .stopping:
                    self.stop(using: app)
                    return
                case .openingLocalDevVPN, .discovering, .connecting: break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func tick(using app: AppModel) {
        guard let engine, let activeJourney else { return }
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastTick ?? now)
        lastTick = now
        // iOS may suspend the task despite background location keep-alive.
        // Restore instead of silently jumping along the route on resumption.
        guard elapsed >= 0, elapsed <= 5 else {
            fail(String(localized: "Train simulation was interrupted. Real location is being restored."), using: app)
            return
        }
        if mode == .realtime {
            guard let updated = activeJourney.realtimeUpdatedAt,
                  now.timeIntervalSince(updated) <= 120 else {
                fail(String(localized: "Live predictions expired. Real location is being restored."), using: app)
                return
            }
        }
        let next = engine.sample(at: now.addingTimeInterval(clockOffset))
        sample = next
        // A new forecast must never cause a teleport or a reversal. The tested
        // limiter bounds speed, acceleration and braking; unsafe changes stop.
        do {
            if elapsed > 0 {
                let motionState = try motion.advance(targetDistanceMetres: next.distanceMetres, elapsed: elapsed)
                renderedDistance = motionState.distanceMetres
                renderedSpeed = motionState.speedMetresPerSecond
            }
        } catch {
            fail(String(localized: "The forecast changed too abruptly. Real location is being restored."), using: app)
            return
        }
        let coordinate = engine.coordinate(atDistanceMetres: renderedDistance)
        renderedCoordinate = coordinate
        guard app.deviceSession.updateLocation(
            target(coordinate), simulationCoordinates: SimulationCoordinates(
                latitude: coordinate.latitude, longitude: coordinate.longitude
            )
        ) == .updated else {
            fail(String(localized: "The train location session ended."), using: app)
            return
        }
        if next.phase == .arrived, abs(next.distanceMetres - renderedDistance) < 1 {
            message = String(localized: "Train arrived. Real location is being restored.")
            stop(using: app)
        }
    }

    private func beginRefresh(using app: AppModel) {
        // The public endpoint provides timetable connections without a token.
        // It has no stable journey-refresh contract, so playback remains on the
        // selected timetable and is labelled as an estimate in the UI.
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func target(_ point: RailCoordinate) -> LocationTarget {
        LocationTarget(
            name: activeJourney?.serviceName ?? "Train",
            subtitle: "opentransportdata.swiss · estimated rail simulation",
            latitude: point.latitude, longitude: point.longitude
        )
    }
}
#endif
