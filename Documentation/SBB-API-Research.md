# Schweizer Zugdaten für WrapPin Rail Lab

Stand der Prüfung: 29. Oktober 2026. Quellen sind Betreiber- und Standarddokumentationen; die Integration wurde noch nicht mit einem persönlichen OJP-Token gegen eine erfolgreiche Live-Antwort geprüft.

## Entscheidung für den MVP

Die offizielle **Open Journey Planner 2.0**-Schnittstelle der Open-Data-Plattform Mobilität Schweiz deckt Bahnhofsuche, konkrete Verbindungen, Zwischenhalte, Soll-/Prognosezeiten und angefragte Streckenprojektionen ab. HTTPS funktioniert unabhängig von WLAN oder Mobilfunk. Das ist jedoch nur die Datenbeschaffung; die lokale iPhone-Entwicklerverbindung von WrapPin hat eigene Voraussetzungen.

- Endpoint: `POST https://api.opentransportdata.swiss/ojp20`
- Header: `Content-Type: application/xml`, `Authorization: Bearer <persönlicher Token>`.
- XML: OJP 2.0, Standardnamensraum `http://www.vdv.de/ojp`, SIRI `http://www.siri.org.uk/siri`.
- Kein Token im Repository oder IPA. Benutzer trägt ihn zur Laufzeit ein. Der MVP nutzt keine in öffentlichen Beispielen sichtbaren Testschlüssel.
- Offizielles Gratislimit: **50 Anfragen/Minute und 20'000/Tag je Schlüssel**. Client reserviert mindestens 1,25 Sekunden zwischen Requests; Echtzeitaktualisierung frühestens alle 30 Sekunden. Bei HTTP 429 pausiert er. Dies ersetzt bei Verteilung mit gemeinsamem Schlüssel keine serverseitige Quotenverwaltung.

Quellen: [OJP Übersicht](https://opentransportdata.swiss/en/cookbook/open-journey-planner-ojp-landing-page/), [API-Zugang](https://api-manager.opentransportdata.swiss/), [Limiten](https://opentransportdata.swiss/en/limits-and-costs/).

## Anfragen und Identität

`OJPLocationInformationRequest`: `InitialInput/Name`, `Restrictions/Type=stop`; Resultate liefern `StopPlaceRef` (SLOID), Name, WGS84 und Verkehrsmittel. Plattform-StopPoint-SLOIDs dürfen gegenüber Bahnhofs-SLOIDs zusätzliche Teile haben.

`OJPTripRequest`: Start/Ziel als PlaceRef, ISO-8601-Abfahrtszeit; `ModeAndModeOfOperationFilter/PtMode=rail`, `IncludeIntermediateStops=true`, `IncludeTrackSections=true`, `IncludeLegProjection=true`. `UseRealtimeData=none` ist Fahrplan, `explanatory` berücksichtigt auch Verspätungen und Ausfälle. Der MVP akzeptiert eine direkte Bahn-Etappe; Umstiege/Fußwege erhalten eine erklärende Grenze.

`OJPTripInfoRequest`: Aktualisiert genau `JourneyRef` plus `OperatingDayRef`, **keine erneute freie Verbindungssuche**. `IncludeCalls`, `IncludeService`, `IncludeTrackSections`, `IncludeTrackProjection` anfordern. Die Antwort betrifft die gesamte Fahrzeugfahrt, deshalb auf den gewählten Ein-/Ausstiegsabschnitt kürzen. `EstimatedTime` ist eine Prognose, kein gemessener Standort. Fehlen Prognosen, bleibt die Frischeanzeige leer. Geänderte Haltefolge oder Umleitung ohne neue brauchbare Geometrie stoppt den nutzbaren Aktualisierungspfad.

Quellen: [Bahnhofsuche](https://opentransportdata.swiss/de/cookbook/open-journey-planner-ojp-landing-page/ojplocationinformationrequest-2-0/), [TripRequest 2.0](https://opentransportdata.swiss/en/cookbook/open-journey-planner-ojp-landing-page/ojptriprequest-2-0/), [TripInfoRequest 2.0](https://opentransportdata.swiss/en/cookbook/open-journey-planner-ojp-landing-page/ojptripinforequest-2-0/), [OJP 2.0 Standardtabellen](https://vdvde.github.io/OJP/release/2.0/documentation-tables/ojp.html).

## Geometrie und echte Liveposition

OJP kann `LegTrack`/`JourneyTrack` mit `TrackSection/LinkProjection/Position` liefern. Das sind geordnete Streckenkoordinaten und **keine aktuelle Fahrzeugposition**. Ihre Vollständigkeit muss je Fahrt geprüft werden. Der MVP erzeugt keine vermeintliche Bahnstrecke aus geraden Verbindungen zwischen Haltestellen und lehnt fehlende bzw. zu grobe Projektionen ab. Selbst eine gültige Projektion garantiert weder das tatsächlich befahrene Gleis noch eine ungeplante Umleitungsstrecke.

Der Schweizer GTFS-Static-Export enthält ausdrücklich **kein `shapes.txt`**. GTFS-RT bietet TripUpdates und ServiceAlerts, aber **keine VehiclePositions**. OJP `IncludePosition` steht ebenfalls nicht zur Verfügung. Eine punktgenaue Livezugposition ist daher mit diesen öffentlichen Daten nicht zugesichert; die App interpoliert eine klar beschriftete Schätzung zwischen Halten auf der angefragten Streckenprojektion.

GTFS-RT ist ein ganzer Protobuf-Feed, an die korrekte `feed_version` des Static-Exports gebunden. Er wird 30 Sekunden gecacht. Die zentrale Limitseite nennt 5/min, das GTFS-RT-Cookbook dagegen 2/min; konservativ höchstens 2/min ansetzen und die tatsächliche API-Manager-Subscription prüfen. Dieser Widerspruch betrifft den OJP-MVP nicht. Roh-JSON ist laut Betreiber nur für Tests gedacht.

Quellen: [GTFS Static und fehlende Shapes](https://opentransportdata.swiss/en/cookbook/timetable-cookbook/gtfs/), [GTFS-RT, Grenzen, Header und Versionsabgleich](https://opentransportdata.swiss/en/cookbook/realtime-prediction-cookbook/gtfs-rt/).

Weitere offizielle Geometriequellen: SBB [`linie`](https://data.sbb.ch/explore/dataset/linie/) und [`linienkilometrierung`](https://data.sbb.ch/explore/dataset/linienkilometrierung/). Der geprüfte Aufruf `https://data.sbb.ch/api/explore/v2.1/catalog/datasets/linie/records?limit=1` lieferte für Lausanne–Iselle lediglich zwei Linienendpunkte: ungeeignet für eine realistische Streckenfahrt. Kilometrierungspunkte sind dichter, benötigen aber eine zusätzliche topologische Zuordnung zur konkreten Fahrt. Sie werden im MVP nicht als Ersatz eingeschleust. Eine spätere Alternative ist ein gepflegtes Bahnnetz mit geprüftem Map-Matching und klarer Datenlizenz.

## Bedingungen und Betrieb

Die Plattformbedingungen gestatten Verarbeitung und Veröffentlichung. `opentransportdata.swiss` muss als Rohdatenquelle genannt, Rohdaten müssen regelmäßig entsprechend ihrer Aktualisierung nachgeführt und bearbeitete Ergebnisse unter eigenem Namen veröffentlicht werden. Die App zeigt Quelle und Schätzcharakter. OSM-basierte Daten brauchen zusätzlich OSM-/ODbL-Attribution; OJP dokumentiert OSM insbesondere für Fußwege. Kein SBB-Logo oder Eindruck eines offiziellen SBB-Produkts.

Quelle: [Nutzungsbedingungen](https://opentransportdata.swiss/en/terms-of-use/), [Geodatenhinweis bei TripRequest](https://opentransportdata.swiss/en/cookbook/open-journey-planner-ojp-landing-page/ojptriprequest-2-0/), [SBB Datenlizenz](https://data.sbb.ch/page/licence/).

## Prüfnachweise der Implementierung

Die drei aus dem Produktionsclient extrahierten ausgehenden XML-Vorlagen (Bahnhofsuche, Verbindungssuche, Journey-Refresh) wurden mit Beispielwerten gegen das vollständige offizielle [VDV-OJP-2.0-XSD](https://github.com/VDVde/OJP/tree/release/2.0), Stand Commit `2a4253df09ae2c7a3c9d773388ac3a5437992573`, geprüft: alle drei sind schema-valide. Dabei wurde eine Schreibweisenabweichung im Cookbook korrigiert: TripInfo verwendet laut XSD `UseRealTimeData`, TripRequest dagegen `UseRealtimeData`. Eine Schema-Prüfung belegt Form und Reihenfolge der Anfragen, nicht die aktuelle Unterstützung aller Optionen beim Schweizer Server.

Der Parsertest enthält zusätzlich zur gezielten synthetischen Zug-Testdatenreihe die vollständig veröffentlichte OJP-2.0-Bahnhofsuchantwort des offiziellen Cookbooks (`Tests/RailCoreTests/Fixtures/official-lir-response.xml`). Sie enthält echte Namespace-Präfixe und Bern/Muri-Beispieldaten; sie ist kein erfolgreicher Liveaufruf dieser Build-Variante.

Der persönliche Token und eine kontrollierte erfolgreiche OJP-Anfrage sind noch erforderlich, um aktuelle Antwortvarianten, reale Geometriequalität und Absagen praktisch zu validieren. Dies benötigt keine Apple-ID-Aktion. Background-Ausführung und eine mobile lokale LocationSimulation-Sitzung müssen später separat auf einem ausdrücklich freigegebenen Testgerät getestet werden. Der Desktop-MVP beweist diese iOS-Eigenschaften nicht.
