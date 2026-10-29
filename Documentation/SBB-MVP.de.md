# WrapPin SBB – technischer Stand und Umsetzungsplan

Stand: 29. Oktober 2026. Implementierter Quellcode-MVP, keine veröffentlichte oder auf dem iPhone installierte App. Ein vollständiger iOS-Build und ein erfolgreicher authentifizierter Liveabruf stehen noch aus.

## Ausgangslage und Schutz der vorhandenen Installation

Die vorliegende Arbeitskopie wurde separat von `https://github.com/suversal/WrapPin` angelegt. Basis ist Commit `c36cba9a92648e53cbb108708bfe7159455b299b`, Version 1.0.20 Build 66; Entwicklungsbranch `codex/sbb-train-mvp`. Die vorhandene Nutzerdokumentation beschreibt dagegen die produktiv genutzte Standard-App 1.0.19 Build 63. Diese wurde weder aktualisiert noch erneut signiert oder installiert. Es wurden keine Apple-ID-, Zertifikats-, Provisioning- oder Geräteaktionen ausgeführt.

Die zusätzliche Build-Variante ist von den bestehenden App-Identitäten getrennt:

| Eigenschaft | Experimentelle Variante |
|---|---|
| Xcode-Target | `WrapPinSBB` |
| Shared Scheme | `WrapPin SBB` |
| Produkt | `WrapPinSBB.app` |
| Anzeigename | `WrapPin SBB` |
| Bundle-ID vor einer späteren Signierung | `ch.local.wrappin.sbb.experimental` |
| URL-Rückruf | `wrappinsbb://` |
| Swift-Bedingung | `WRAPPIN_SBB_EDITION` |
| Tunnel | vorhandener externer Gerätekanal, keine eigene Packet-Tunnel-Erweiterung |

`Configuration/SBB.xcconfig` liest nur die gemeinsame Versionsdatei. Die privaten Signatur- und Identitätseinstellungen der Original-App werden nicht eingebunden. Entwicklerteam und Telemetrie sind leer. Die bisherigen Standard-/Tunnel-Targets behalten Bundle-ID, Namen und Rückrufschema. `scripts/check-sbb-isolation.py` prüft diese Eigenschaften einschließlich aller Projektreferenzen.

Eine andere Bundle-ID schützt vor versehentlichem Überschreiben der Original-App. Sie trennt jedoch die **systemweite simulierte Position** nicht: Sobald künftig irgendeine Variante eine LocationSimulation-Sitzung startet oder beendet, betrifft das dieselbe iPhone-Position. Deshalb benötigt ein späterer Gerätetest eine eigene Freigabe und darf nicht parallel zu einer produktiven Sitzung erfolgen. Eine spätere Signierung kann außerdem gemeinsame Apple-Kontingente oder Zertifikate berühren; sie ist hier ausdrücklich nicht Teil des ausgeführten Arbeitsumfangs.

## Repository, Lizenz und Erweiterungspunkt

WrapPin ist eine iPhone-App für iOS 27+ mit SwiftUI und einem vorgebauten Rust-FFI-Framework. Es gibt keine CocoaPods- oder App-SPM-Abhängigkeiten. Die Xcode-Targets verwenden denselben synchronisierten Ordner `WrapPin/`; die neue Zugoberfläche muss daher durch `WRAPPIN_SBB_EDITION` auf die experimentelle Variante begrenzt bleiben.

Die aktuelle Lizenz ist **PolyForm Noncommercial 1.0.0**; es handelt sich damit um quelloffene Einsicht mit Nutzungsbeschränkung und nicht um eine uneingeschränkte MIT-Lizenz. Persönliche nichtkommerzielle Experimente sind im Lizenztext ausdrücklich vorgesehen. Die ältere MIT-Lizenz betrifft Roam Control 0.9.0 Beta 1. `LICENSE`, `LICENSE-BETA1-MIT`, `LICENSING.md`, `NOTICE` und die Drittanbieterhinweise bleiben erhalten. Quelle: [Licensing im Originalrepository](https://github.com/suversal/WrapPin/blob/main/LICENSING.md).

Der wesentliche Ablauf ist:

1. SwiftUI hält App-Zustand über `AppModel`.
2. `LocalDeviceSessionCoordinator` baut über den lokalen Gerätekanal eine Entwicklerverbindung auf.
3. Das Rust-Framework startet die iOS-LocationSimulation-Sitzung.
4. `deviceSession.updateLocation(...)` setzt neue Koordinaten in derselben Sitzung.
5. Stoppen läuft über den vorhandenen Wiederherstellungspfad und löscht die simulierte Position.

Der bestehende `WalkingSimulationController` verwendet diesen Aktualisierungspunkt bereits für Fuß- und Autofahrten. Damit kann eine zusätzliche Zugsteuerung denselben Kanal nutzen. Es ist keine Änderung des nativen Frameworks nötig, um berechnete Zugkoordinaten einzuspeisen. Die übliche Apple-Maps-Autoroute ist als Bahngeometrie ungeeignet.

## Datenentscheidung

Der MVP verwendet die offizielle **OJP-2.0-Schnittstelle** der Open-Data-Plattform Mobilität Schweiz. Der persönliche Token wird zur Laufzeit eingetragen; er wird nicht in Quellcode oder Build-Dateien hinterlegt. Bahnhofsuche, Verbindungssuche und Aktualisierung einer konkreten Fahrt sind getrennte Abfragen. Der API-Client darf keine andere Verbindung als vermeintliches Live-Update unterschieben.

| Wunsch | Umsetzungsansatz | Grenze |
|---|---|---|
| Start-/Zielbahnhof | OJP LocationInformationRequest mit Stop-Filter | Ergebnisse müssen Bahnhöfe bzw. passende Bahnstopps sein |
| Konkrete Verbindung | OJP TripRequest mit Bahnfilter | erster MVP beschränkt sich auf direkte Bahnetappen |
| Fahrplan | ausschließlich Sollzeiten | keine Aussage über tatsächliche Verspätung |
| Echtzeit | Prognosezeiten derselben Fahrt über JourneyRef und Betriebstag | zeitbasierte Schätzung, keine gemessene Zugposition |
| Bahnstrecke | OJP-Streckenprojektion als geordnete Koordinaten | fehlende/grobe Geometrie wird abgelehnt |
| Zwischenhalte | Ein-/Ausfahrzeiten einschließlich Standzeit | ausgefallene Halte oder unplausible Reihenfolge brauchen Fehlerbehandlung |
| 5G ohne PC | HTTPS-Daten plus vorhandene lokale Geräteverbindung | der Gerätekanal ist separat von Internetzugang zu testen |

OJP dokumentiert 50 Anfragen pro Minute und 20'000 pro Tag je Schlüssel. Der Client begrenzt Anfragen mit mindestens 1,25 Sekunden Abstand, die laufende Simulation aktualisiert Prognosen einmal pro Minute. Lokale Positionsupdates laufen ungefähr einmal pro Sekunde. Im Echtzeitmodus führen fehlende bzw. mehr als 120 Sekunden alte Prognosen zum Stopp mit angeforderter Standortwiederherstellung. Es gibt keinen stillen Wechsel in den Fahrplanmodus. Die Frische bezieht sich auf die Datenantwort, nicht auf eine GPS-Messung im Zug.

Schweizer GTFS-Static-Daten enthalten kein `shapes.txt`; der GTFS-RT-Feed liefert keine `VehiclePositions`. Die Daten reichen deshalb nicht für eine punktgenaue Liveposition. SBB-Linienübersichten sind auch nicht automatisch eine befahrbare Gleispolyline. Die vollständige Quellen-, Limit- und Geometrieprüfung steht in [SBB-API-Research.md](SBB-API-Research.md), mit Verweisen auf die offiziellen Dokumentationen.

## Implementierungsplan und erster Kern

1. **Build trennen:** zusätzliches Target und Scheme, eigener Anzeigename/Bundle-ID/Rückruf; keine Einbindung privater Signaturdaten. Dieser Teil ist implementiert und statisch geprüft.
2. **Datenmodell und Simulation:** Foundation-basierte Modelle `RailCoordinate`, `RailStop`, `RailJourney`; `RailSimulation` interpoliert auf einer gelieferten Bahnprojektion. Die Logik ist als separates Swift-Package testbar und benötigt keine Geräteverbindung.
3. **Fahrprofil:** Pro Abschnitt wird eine Beschleunigungs-, Reise- und Bremsphase berechnet. Das Modell begrenzt Beschleunigung auf 0,8 m/s² und Spitzengeschwindigkeit auf 320 km/h. Die Zeiten bestimmen die Fahrt; Standzeiten ergeben Geschwindigkeit null. Unvereinbare Strecke-/Zeitkombinationen werden abgelehnt. Diese Werte sind Plausibilitätsgrenzen, kein physikalisches Modell eines bestimmten Zugtyps oder streckengenauer Tempoplan.
4. **Geometrie prüfen:** ungültige Koordinaten, fehlende Projektion, OJP-Segmente über 3 km (Kernschutz zusätzlich bei 5 km) und Halte mehr als 500 m neben der Projektion werden abgelehnt. Diese Prüfungen erkennen grobe Fehler; sie beweisen weder das richtige Gleis noch eine aktuelle Umleitung. Es wird keine Autoroute oder gerade Stationsverbindung als echte Bahnstrecke ausgegeben.
5. **API anbinden:** Token, XML-Anfragen/-Antworten, Bahnhofsauswahl, direkte Verbindungen, Soll-/Prognosezeiten und Fahrtidentität. Auf HTTP-Fehler und Quotenüberschreitung reagieren. Prognosefrische darf nur bei tatsächlich gelieferten Prognosen angezeigt werden.
6. **Oberfläche und Geräteadapter:** Zugmodus nur in der SBB-Variante; Vorbereitung und Vorschau vor Start. Die Startaktion verwendet den vorhandenen Gerätekanal, WGS84 und den bewährten Stop-/Restore-Pfad. Eine Fahrt darf nicht unbemerkt mit einer anderen laufenden Sitzung konkurrieren. Bewegungen nach Prognoseänderungen müssen ohne Rückwärtssprung abgeglichen werden.
7. **Freigabestufen:** Offline-Tests → erfolgreicher offizieller API-Test mit persönlichem Token → unsigned Xcode-Build/Simulator → erst nach gesonderter Zustimmung Signierung und Testinstallation → reale 5G-/Background-Prüfung. Keine dieser späteren Stufen wird durch einen erfolgreichen Offline-Test ersetzt.

## Tests und ausstehende Nachweise

Abschließende Prüfung am 29. Oktober 2026 mit Swift 6.4.1 unter der vorhandenen WSL-Ubuntu-Umgebung. Die Swift-Werkzeuge und nötigen Laufzeitdateien wurden ausschließlich im Arbeitsordner bereitgestellt; keine globale Installation. Der offizielle Swift-Download wurde per veröffentlichter PGP-Signatur geprüft.

| Prüfung | Ergebnis | Aussagegrenze |
|---|---|---|
| Produktiver Kern und OJP-Parser als Swift-Package | **33 Tests bestanden, 0 Fehler**: 18 Simulation, 4 Bewegungsabgleich, 11 OJP | Offline-Fixtures, darunter veröffentlichte offizielle Bahnhofssuchantwort; keine erfolgreiche Liveabfrage |
| Produktiver `TrainModel` mit echtem OJP-Client und HTTP-Fixtures | **5 Sitzungsgruppen bestanden**, ohne Compilerwarnungen | Gerät/Standortdienst gezielt ersetzt: ungepaart, laufende Sitzung, Start/Updates/Stop, abgebrochener Start, Gerätefehler |
| Ausgehende API-Vorlagen | **Alle 3 Request-Arten gültig**, TripRequest in beiden Modi | Validiert gegen offizielles OJP-2.0-XSD, Commit `2a4253df09ae2c7a3c9d773388ac3a5437992573`; kein Authentifizierungsnachweis |
| Xcode-Projekt und getrennte Identitäten | **Bestanden** | Struktur, Referenzen, Scheme und Konfiguration; kein iOS-Link-/Buildnachweis |
| Lokalisierung | **Bestanden** | 796 zh-Hans-Schlüssel decken 599 UI-Literale und 4 Shortcut-Phrasen; neue Zugoberfläche zusätzlich Deutsch |
| Swift-Syntax von Oberfläche und gemeinsamen Änderungen | **Bestanden** | Parserprüfung mit SBB-Bedingung; SwiftUI-Typprüfung mit Apple-SDK steht aus |
| Änderungen auf Whitespace-/Patchfehler | **Bestanden** | `git diff --check` |

Ein tatsächlich ausgeführter Test fand einen Unterschied beim XML-Parser: eine ungültige Antwort wurde auf Linux zunächst akzeptiert. Der Produktionsparser prüft jetzt zusätzlich Parserfehler, vollständigen Dokumentabschluss und den leeren Elementstapel; DTD-/eigene Entity-Deklarationen werden zurückgewiesen. Anschließend bestanden alle 33 Tests und der Sitzungstest erneut.

Der Quellcode enthält die eigene `TrainView` samt deutscher Übersetzung, `TrainModel`, den offiziellen OJP-Client, den reinen Simulationskern und Tests. Standard und Tunnel erhalten die Zugoberfläche nicht. Der SBB-Build nutzt einen eigenen Keychain-Namensraum, keine privaten Signing-Dateien und keine automatischen Hinweise zum Aktualisieren auf die unveränderte Original-App.

**Bedienung des MVP nach einem späteren Build:** App starten, bestehende Geräteverbindung für diese separate App einrichten, persönlichen OJP-2.0-Schlüssel für die Sitzung eintragen, Start/Ziel suchen und Bahnhofsergebnisse auswählen, Datum/Abfahrt und Modus wählen, direkte Verbindung auswählen, Bahnprojektion und Halte prüfen, Simulation starten. Es wird nicht nach jedem Tastendruck gesucht. Die Abfahrtszeit wird in `Europe/Zurich` angezeigt. Unterstützt werden direkte Schweizer Bahnverbindungen einschließlich anderer Betreiber; ein SBB-exklusiver Betreiberfilter ist noch nicht vorhanden.

Im Fahrplanmodus beginnt die zeitversetzte Wiedergabe mit der geplanten Abfahrt, sobald die lokale Standortverbindung aktiv ist. Im Echtzeitmodus gilt die tatsächliche Uhrzeit. Die Bewegung folgt einer begrenzten Geschwindigkeits-/Bremskurve. Eine zusätzliche Abgleichslogik verhindert Rückwärtssprünge und Teleportieren nach Prognoseänderungen; sie kann der Schätzung kurz nachlaufen. Eine nicht sicher abgleichbare Prognose oder eine geänderte Fahrt/Strecke stoppt die Sitzung. Bei Ankunft wird ebenfalls der echte Standort angefordert.

Der Token bleibt nur im Speicher. Stationssuche, Stationskennungen, Reisezeit und Fahrtreferenz werden an die offizielle Plattform gesendet. Paarungsdaten und simulierte Koordinaten werden durch den Zugclient nicht hochgeladen. Details stehen in den aktualisierten Datenschutzhinweisen.

`Package.swift` enthält einen separaten Testzugang für die produktiven, von Apple-Oberflächen unabhängigen Simulationsquellen. Relevante Fälle sind Halt vor Abfahrt, Beschleunigung/Bremsung, Zwischenhalt mit Standzeit, Ende, Mitternachtswechsel, frische/veraltete Prognosen, Ausfall, fehlerhafte Zeiten und fehlende/grobe Streckenprojektion. API-Parser-Tests müssen außerdem namensraumbehaftetes OJP-XML und die Auswahl der konkreten Fahrt abdecken.

Die konkreten Prüfergebnisse werden unten festgehalten. Auf dem vorhandenen Windows-Rechner stehen Xcode und das iOS-SDK nicht bereit. Deshalb sind vollständige SwiftUI-Builds und reale iPhone-Funktion ausdrücklich unbestätigt. Unter Linux bestandene Foundation-Tests sind kein iOS-Buildnachweis.

Statische Isolation prüfen:

```sh
python scripts/check-sbb-isolation.py
```

Nach Verfügbarkeit einer passenden Swift-Toolchain die Kern-/Parser-Tests ausführen:

```sh
swift test
python3 scripts/test-train-session.py
```

Unsigned-Build auf einem Mac mit Xcode 27+, ohne Installation und ohne Anmeldung:

```sh
xcodebuild -project WrapPin.xcodeproj -scheme "WrapPin SBB" \
  -configuration Debug -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project WrapPin.xcodeproj -scheme "WrapPin SBB" \
  -configuration Release -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO build
```

Änderungen an gemeinsamem Quellcode benötigen zusätzlich Debug-/Release-Builds der ursprünglichen Standard- und Tunnel-Schemes. Native LocationSimulation kann nur auf einem echten iPhone geprüft werden. Ein unsigned Build ist kein installierbares, fertig signiertes IPA.

## Bekannte Betriebsgrenzen

- **Liveposition:** aus Fahrzeiten und Strecke geschätzt. Kein Zugriff auf laufende GPS-Koordinaten des realen Zuges; keine Garantie bei Signalhalt, kurzfristiger Umleitung oder falscher Prognose.
- **Background:** iOS kann App und Timer pausieren oder beenden. Vorhandenes Core-Location-Keepalive ist keine Zusage für stundenlange Fahrt, Sperrbildschirm oder alle Energiesparzustände. Keine künstliche Umgehung durch Audio oder dauerhafte Hintergrundaufgaben.
- **5G:** für die ÖV-API ausreichend; bestehende Pairing-/LocalDevVPN-Verbindung bleibt zusätzlich erforderlich. Das Projekt hat dafür schon eine Mobilfunkführung. Die neue Kombination ist noch nicht auf einem iPhone getestet.
- **Signatur:** eine getrennte App löst Ablauf und Kontingente der verwendeten Signierung nicht. Bestehende Zertifikate werden hier nicht widerrufen oder erneuert.
- **Andere Apps:** übernehmen simulierte Koordinaten möglicherweise unterschiedlich; eine Drittanbieter-App kann die Simulation erkennen oder eigene Daten heranziehen.
- **Wiederherstellung:** bei normalem Stop reale Position aktiv wiederherstellen; nach Absturz muss der vorhandene Recovery-Pfad verwendet werden. Keine automatische Fortsetzung einer Zugfahrt nach Neustart ohne sichtbare Entscheidung.

Apple dokumentiert ausdrücklich, dass iOS Hintergrund-Apps suspendieren und Apps zur Freigabe von Ressourcen beenden kann. Die vorhandene Background-Location-Konfiguration ist deshalb kein Nachweis für einen dauerhaft laufenden Zug-Timer. Wird die App beendet, kann sie in diesem Zustand auch keinen sofortigen Wiederherstellungsbefehl senden: die simulierte Position kann bis zum erneuten Öffnen/Wiederherstellen stehen bleiben. Die Erkennung eines Tick-Abstands über fünf Sekunden greift erst, wenn die App wieder ausgeführt wird. Quelle: [Apple – Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background).

## Nächste umsetzbare Schritte

1. Auf einem Mac mit Xcode 27+ die oben genannten unsigned Builds für SBB sowie die gemeinsam betroffenen Standard-/Tunnel-Schemes ausführen und Compilerbefunde beheben. Dazu sind weder iPhone-Installation noch Apple-Anmeldung nötig.
2. Mit einem eigenen OJP-2.0-Token reale Verbindungen, beispielsweise Aarau–Zürich HB, abrufen: vollständige Gleisprojektion, alle Halte, Aktualisierung derselben Fahrt, Verspätung/Ausfall und Fehlermeldungen prüfen. Die Token-Eingabe ist vorbereitet; hier wurde kein Account erstellt und kein Schlüssel beschafft.
3. Erst nach zusätzlicher ausdrücklicher Zustimmung eine signierte SBB-Testvariante vorbereiten. Zuvor tatsächliche App-Kennung nach Signierung, freie Kontingente und Auswirkungen auf vorhandene Zertifikate prüfen. Die ursprüngliche Installation nicht überschreiben und keine Zertifikate widerrufen.
4. Auf einem freigegebenen Testgerät die lokale Verbindung und Wiederherstellung zuerst im Vordergrund testen, danach 5G ohne PC, Appwechsel, Sperrbildschirm, Netzverlust und Energiesparmodus. Währenddessen keine andere WrapPin-Sitzung betreiben.
5. Erst anhand dieser Ergebnisse dauerhaften mobilen Betrieb bewerten. Danach gegebenenfalls Umstiege, robustere Umleitungsgeometrie und Offline-Fahrplanpakete ergänzen. Eine präzise Livezugposition bleibt ohne eine zusätzliche tatsächliche Fahrzeugpositionsquelle offen.
