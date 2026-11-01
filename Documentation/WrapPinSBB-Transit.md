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

The public endpoint currently returns stop coordinates and timetable/prognosis
data, but does not return a route polyline or track/road shape. Public
connections therefore intentionally contain an empty geometry and the Start
button is disabled. No straight-line route is drawn and no GPS-style vehicle
location is inferred from the stop sequence.

The optional token-based OJP path remains the only implemented playback source:
it accepts detailed OJP `LinkProjection` geometry and stop-time forecasts, and
will refuse a missing or coarse projection. It does not claim that estimates
are live vehicle GPS. A public, licensed source with routable rail/bus/tram
polylines is still required before token-free playback can be enabled without
inventing positions.

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
