# WrapPin SBB: transit data boundary

## Implemented on `codex/sbb-train-mvp`

The token-free client uses `transport.opendata.ch/v1/locations` for stop search
and `transport.opendata.ch/v1/connections` for connections. Its coordinates are
decoded as `x = latitude` and `y = longitude`. Connection searches pass the
chosen Swiss local date as `date=YYYY-MM-DD` and time as `time=HH:mm`.

Every public connection is retained as a sequence of vehicle legs. Each leg
keeps its category (train, bus, tram, ship or cableway), service label and
published pass list. Adjacent calls at an interchange are merged only in the
connection-wide stop list so the arrival from one vehicle and departure of the
next remain visible. The UI presents the legs and all stops. API prognosis
arrival/departure values are shown as forecasts when returned.

## Geometry and playback

The public endpoint returns stop coordinates and timetable/prognosis data, but
does not return a route polyline. Before a selected connection starts, the app
resolves its geometry from open map data: OpenStreetMap railway ways are used
for train/tram legs and OSRM road routing is used for bus and walking legs.
If any segment cannot be resolved, playback stops with an error instead of
falling back to a straight-line route. The displayed position remains a
timetable simulation, not live vehicle GPS.

The optional token-based OJP path can instead provide detailed OJP
`LinkProjection` geometry and stop-time forecasts. It remains preferable where
available because it supplies the service-specific projection directly. Neither
source claims that estimates are live vehicle GPS.

## Verification

`OJPClientTests.testPublicTimetableUsesSwissDateTimeCoordinatesAndAllVehicleLegs`
uses a local URL protocol fixture. It checks Swiss request date/time fields,
coordinate order, train-plus-bus transfer preservation, pass-list stops,
forecasts, and the no-fabricated-geometry rule. Existing OJP parser tests still
cover OJP request construction, detailed track projections, cancellations and
refresh handling.

The branch carries a GitHub Actions workflow that creates an unsigned
`WrapPin-SBB-unsigned.ipa` from the isolated `WrapPin SBB` scheme with code
signing disabled. This source tree and workflow neither install an app nor use
an Apple ID, certificate or provisioning profile.
