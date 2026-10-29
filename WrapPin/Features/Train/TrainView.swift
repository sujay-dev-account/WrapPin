#if WRAPPIN_SBB_EDITION
import MapKit
import SwiftUI

struct TrainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = TrainModel()
    @State private var token = ""
    @State private var showsPairing = false
    @State private var showsSettings = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Text("Experimental train simulation. Your original WrapPin installation is separate.")
                    Text("Timetable replays from departure now. Live mode estimates position from predicted stop times; it is not live train GPS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if app.interruptedSession != nil {
                    Section("Interrupted session") {
                        Text("Train playback is not resumed automatically. Restore the real location before starting again.")
                        Button("Restore real location") {
                            Task { await app.restoreRealLocationFromInterruptedSession() }
                        }
                        .disabled(app.isRestoringInterruptedSession)
                        Button("Location is already restored") { app.dismissInterruptedSessionRecovery() }
                            .disabled(app.isRestoringInterruptedSession)
                        if let error = app.interruptedSessionError { Text(verbatim: error) }
                    }
                }
                Section("Open transport data access") {
                    SecureField("OJP 2.0 API token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(model.hasToken ? "Replace API token" : "Use API token") {
                        model.configure(token: token)
                        token = ""
                    }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("The token stays in memory for this app session. Obtain your own OJP 2.0 key from opentransportdata.swiss.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Searches send station names, selected stations and travel times to the official data platform.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Open data platform", destination: URL(string: "https://api-manager.opentransportdata.swiss/")!)
                }.disabled(model.locksControls || model.isLoading)

                Section("Stations") {
                    TextField("From station", text: $model.originQuery)
                    TextField("To station", text: $model.destinationQuery)
                    Button("Search stations") { Task { await model.searchStations() } }
                        .disabled(!model.hasToken || model.originQuery.isEmpty || model.destinationQuery.isEmpty)
                    if !model.originResults.isEmpty {
                        stationPicker(title: "From", results: model.originResults, selected: $model.origin)
                    }
                    if !model.destinationResults.isEmpty {
                        stationPicker(title: "To", results: model.destinationResults, selected: $model.destination)
                    }
                    DatePicker("Departure", selection: $model.departure, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, TimeZone(identifier: "Europe/Zurich")!)
                    Picker("Simulation mode", selection: $model.mode) {
                        Text("Timetable").tag(RailSimulationMode.timetable)
                        Text("Live estimate").tag(RailSimulationMode.realtime)
                    }
                    Button("Find direct trains") { Task { await model.findConnections() } }
                        .disabled(model.origin == nil || model.destination == nil || model.origin?.id == model.destination?.id)
                    Text("MVP: direct rail connections with detailed route geometry. Transfers are not supported yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(model.locksControls || model.isLoading)
                .onChange(of: model.originQuery) { _, _ in model.invalidateStations() }
                .onChange(of: model.destinationQuery) { _, _ in model.invalidateStations() }
                .onChange(of: model.origin?.id) { _, _ in model.clearConnections() }
                .onChange(of: model.destination?.id) { _, _ in model.clearConnections() }
                .onChange(of: model.mode) { _, _ in model.clearConnections() }
                .onChange(of: model.departure) { _, _ in model.clearConnections() }

                if model.isLoading { ProgressView() }
                if !model.journeys.isEmpty {
                    Section("Connections") {
                        ForEach(model.journeys) { journey in
                            Button {
                                model.selectedID = journey.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(verbatim: journey.serviceName)
                                        Text(verbatim: connectionTimes(journey))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if journey.id == model.selectedID {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                        }
                    }.disabled(model.locksControls)
                }
                if let journey = model.selectedJourney {
                    Section("Rail route") {
                        routeMap(journey)
                            .frame(height: 230).listRowInsets(EdgeInsets())
                        ForEach(Array(journey.stops.enumerated()), id: \.offset) { _, stop in
                            HStack {
                                Text(verbatim: stop.name)
                                Spacer()
                                VStack(alignment: .trailing) {
                                    HStack {
                                        Text("Scheduled")
                                        Text(verbatim: stopTimes(stop, estimated: false))
                                    }
                                    if model.mode == .realtime,
                                       stop.estimatedArrival != nil || stop.estimatedDeparture != nil {
                                        HStack {
                                            Text("Forecast")
                                            Text(verbatim: stopTimes(stop, estimated: true))
                                        }.foregroundStyle(.orange)
                                    }
                                }.font(.caption)
                            }
                        }
                        Text(verbatim: journey.geometrySource).font(.caption)
                    }
                }
                Section("Train session") {
                    if let sample = model.sample {
                        LabeledContent("Speed", value: String(format: "%.0f km/h", model.renderedSpeed * 3.6))
                        LabeledContent("State", value: phaseText(model.renderedSpeed > 0.2 ? .moving : sample.phase))
                        if let name = sample.stopName { Text(verbatim: name) }
                        if model.mode == .realtime {
                            Text("Estimated position from real-time stop forecasts")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if model.locksControls {
                        if model.isPreparing { ProgressView("Connecting to this iPhone") }
                        if model.isStopping { ProgressView("Restoring real location") }
                        Button("Stop and restore real location", role: .destructive) { model.stop(using: app) }
                            .disabled(model.isStopping)
                    } else {
                        Button("Start train simulation") { Task { await model.start(using: app) } }
                            .disabled(model.selectedJourney == nil || model.isLoading || app.interruptedSession != nil)
                    }
                    if let message = model.message { Text(verbatim: message).foregroundStyle(.orange) }
                    if let warning = model.refreshWarning { Text(verbatim: warning).foregroundStyle(.orange) }
                    Text("Keep the app in the foreground for the first test. Background and lock-screen operation are not verified. A detected interruption stops playback and requests real-location restoration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Link("Data: opentransportdata.swiss", destination: URL(string: "https://opentransportdata.swiss/")!)
                    Text("Independent experimental variant; not an official SBB app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("WrapPin SBB")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Device setup") { showsPairing = true }
                        .disabled(model.locksControls)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings") { showsSettings = true }
                        .disabled(model.locksControls)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let guidance = app.deviceSession.mobileDataGuidance {
                    MobileDataGuidanceView(
                        guidance: guidance, tunnelHandoffApp: app.tunnelHandoffApp,
                        usesBuiltInTunnel: false,
                        isUsingMobileData: app.deviceSession.isUsingMobileDataForStartup,
                        onOpenTunnelApp: app.deviceSession.openSelectedTunnelApp,
                        onRetry: app.deviceSession.retryConnection,
                        onUseMobileData: app.deviceSession.useMobileDataGuidance,
                        onMobileDataOff: app.deviceSession.confirmMobileDataIsOff,
                        onCancel: { model.stop(using: app) },
                        onDone: {
                            if app.isRestoringInterruptedSession {
                                app.completeInterruptedSessionRestorationAfterMobileData()
                            } else { app.deviceSession.dismissMobileDataGuidance() }
                        }
                    ).padding().background(.regularMaterial)
                }
            }
            .sheet(isPresented: $showsPairing) { PairingSetupView().environment(app) }
            .sheet(isPresented: $showsSettings) { SettingsView().environment(app) }
            .task { await app.restorePairingStatus() }
            .onChange(of: app.deviceSession.phase) { _, phase in model.handleDevicePhase(phase) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { app.deviceSession.appDidBecomeActive() }
            }
        }
    }

    private func stationPicker(title: LocalizedStringKey, results: [OJPStation], selected: Binding<OJPStation?>) -> some View {
        Picker(title, selection: Binding(
            get: { selected.wrappedValue?.id ?? "" },
            set: { id in selected.wrappedValue = results.first { $0.id == id } }
        )) {
            ForEach(results) { station in Text(verbatim: station.name).tag(station.id) }
        }
    }

    private func routeMap(_ journey: RailJourney) -> some View {
        Map {
            MapPolyline(coordinates: journey.geometry.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }).stroke(.blue, lineWidth: 4)
            ForEach(Array(journey.stops.enumerated()), id: \.offset) { _, stop in
                Marker(stop.name, coordinate: CLLocationCoordinate2D(
                    latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude
                ))
            }
            if let point = model.renderedCoordinate {
                Annotation("Simulated train", coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude, longitude: point.longitude
                )) {
                    Image(systemName: "tram.circle.fill").font(.title).foregroundStyle(.red)
                }
            }
        }.id(journey.id)
    }

    private func connectionTimes(_ journey: RailJourney) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        let start = journey.stops.first?.scheduledDeparture.map { formatter.string(from: $0) } ?? "?"
        let end = journey.stops.last?.scheduledArrival.map { formatter.string(from: $0) } ?? "?"
        return "\(start) – \(end) · " + String(
            format: NSLocalizedString("%lld stops", comment: "Train stops"), journey.stops.count
        )
    }

    private func stopTimes(_ stop: RailStop, estimated: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Europe/Zurich")
        let arrival = estimated ? stop.estimatedArrival : stop.scheduledArrival
        let departure = estimated ? stop.estimatedDeparture : stop.scheduledDeparture
        return [arrival, departure].compactMap { $0 }.map { formatter.string(from: $0) }.joined(separator: " / ")
    }

    private func phaseText(_ phase: RailSamplePhase) -> String {
        switch phase {
        case .waiting: String(localized: "Waiting for departure")
        case .moving: String(localized: "Moving")
        case .dwelling: String(localized: "Station stop")
        case .arrived: String(localized: "Arrived")
        }
    }
}
#endif
