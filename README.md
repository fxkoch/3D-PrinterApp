# MakerSlice – kostenlose 3D-Modelle finden, slicen, direkt drucken

iPhone-App (SwiftUI, iOS 17+) für den **Snapmaker U1**, den **Anycubic Kobra S1 mit ACE Pro** und den **Bambu Lab P1S (mit AMS)**.
Modelle aus **18 Portalen** (u. a. MakerWorld, Printables, Thingiverse, Anycubic Maker Online, Snapmaker-Bibliothek) holen,
auf dem iPhone **oder mit dem echten OrcaSlicer in der Cloud** slicen, Empfehlungen für den perfekten Druck übernehmen und per
WLAN an den Drucker schicken. Der einfache Modus fragt nur das Nötigste (Qualität, Stabilität, Stützen, Material); der
**Expertenmodus** öffnet alle Einstellungen – jede mit Erklärung und Beispielbild.

**Installation aufs iPhone:** siehe [INSTALL.md](INSTALL.md) (Xcode, Sideloadly/AltStore oder TestFlight).

## Funktionen

| Bereich | Was geht |
|---|---|
| **Entdecken** | Suche über **Printables** und **MakerWorld** (über deinen Login im eingebauten Browser), nur kostenlose Modelle, Sortierung nach Relevanz, Beliebtheit, Neu oder Bewertung. Unter **Portale** öffnen 18 Webseiten im App-Browser – zuerst die des gewählten Druckers (*Anycubic Maker Online*, *Snapmaker Modelle*), dann Thingiverse, Thangs, MyMiniFactory, Cults3D, Creality Cloud, Yeggi, GrabCAD u. a. Logins bleiben gespeichert, jede Datei (STL/3MF/OBJ/ZIP) landet automatisch in der Bibliothek. |
| **Mehrere Platten** | Neue, duplizierte und geteilte Objekte werden automatisch auf die passende Platte gelegt (bei Bedarf gedreht); Platten hinzufügen, Objekte verschieben, alle Platten auf einmal slicen. |
| **Mehrfarbig** | Mehrfarb-Modelle (auch **bemalte** MakerWorld-Modelle) werden erkannt: Farben des Modells → Slot und Filament zuordnen, **Stützmaterial getrennt**, Farbwechsel bei Höhe, Spülmenge und Abfallanzeige. Das empfohlene Profil wird je Filament übernommen und lässt sich anpassen. |
| **Kalibrieren** | Fünf Testdrucke (Temperatur, Fluss, Pressure Advance, Rückzug, max. Fließgeschwindigkeit) werden aus dem Filamentprofil erzeugt, mit Erklärung „was sehe ich – was bedeutet es“. Das Ergebnis wird je Drucker und Filament gespeichert und für alle späteren Drucke genutzt; beim U1 zusätzlich im Drucker (Moonraker-Datenbank). |
| **Vorbereiten** | 3D-Vorschau, Drucker (U1 / Kobra S1), 4 Material-Slots, Objekte je Slot, drehen, flach legen, skalieren, duplizieren, anordnen. MakerWorld-3MF (Bambu-Projekte inkl. Platten) werden auf Bauraum, Material und Profil deines Druckers umgerechnet. |
| **Teilen** | Zu große Objekte per Schnittebene (X/Y/Z) mit Live-Vorschau teilen – mit **Zapfen** oder **Dübeln** (0,2 mm Spiel). „Automatisch passend teilen“ zerlegt so oft wie nötig. |
| **Empfehlungen** | Vor jedem Druck, mit einem Tipp übernehmen: Stützen, Brim, Glätten, Füllmuster, Schichthöhe, Platte, Reinigungsturm, eingelegtes Filament – plus druckerspezifische Hinweise aus Hersteller- und Community-Erfahrung: TPU nicht über die ACE Pro, kurzer Rückzug bei TPU (Werkzeugwechsel-Staus am U1), Trocknen bei feuchtem Filament (Feuchte aus der ACE Pro), PETG-Fäden und Elefantenfuß, passgenaue Steckverbinder, Düsenspitze am Kobra, Vasenmodus-Prüfung. |
| **Slicer (iPhone)** | Wände (Reihenfolge innen/außen), Naht (hinten / in Ecken / zufällig), Ober-/Unterseiten (monoton, Linien, konzentrisch), Füllung (Gitter, Linien, Dreiecke, Kubisch, Gyroid), Brückenerkennung, Ironing, Stützen, Brim/Skirt, Elefantenfuß-Ausgleich, **Vasenmodus** (durchgehende Spirale), **Fuzzy Skin**, Z-Hop, Rückzug, Pressure Advance, Flussbegrenzung, Abkühl-Verlangsamung, Werkzeugwechsel, Reinigungsturm für die ACE Pro. Schicht-Vorschau. |
| **Profi-Slicing (Cloud)** | Optional: Der **echte OrcaSlicer** (2.4) rechnet auf GitHub Actions mit den offiziellen Profilen von Snapmaker/Anycubic und deinen Einstellungen; der G-Code kommt nach 1–3 Minuten zurück – inklusive Schicht-Vorschau. Einrichtung in der App unter *Einstellungen → Profi-Slicing*. |
| **Erklärungen** | Jede Einstellung (Slicer und Filament) hat ein ⓘ: was sie bewirkt, was mehr/weniger bedeutet, Praxistipp mit Werten für U1/Kobra. Auf Wunsch direkt unter jeder Einstellung eingeblendet. |
| **Filamente** | **325 Profile** aus den offiziellen OrcaSlicer-Daten (25 Kobra S1, 59 U1, 241 Markenfilamente). Auswahl lädt die empfohlenen Werte; im Expertenmodus feinjustierbar mit „Auf Empfehlung zurücksetzen“. Eingelegtes Material (RFID am U1, ACE Pro am Kobra) wird erkannt. |
| **Drucker-Display** | Der G-Code enthält Vorschaubilder (U1: 48 und 300 px, Kobra: 230×110 px) sowie Druckzeit, Filament je Slot und Temperaturen im OrcaSlicer-Format, damit Drucker und Moonraker sie anzeigen. |
| **Festigkeit prüfen** | Objektmenü → „Festigkeit prüfen“. Gerechnet wird immer mit dem **Filament des Objekt-Slots** (12 Materialtypen hinterlegt). Befestigung antippen, Last auf eine ganze Fläche oder **an eine beliebige Stelle** setzen (Größe einstellbar, durch erneutes Tippen verschiebbar), Kilogramm und Richtung wählen. Ergebnis: Ampel, Sicherheitsfaktor (kurz/Dauerlast), Verformung, Beanspruchung als Farbe. **Schwachstellen ohne Last**: das Teil wird auf der Unterseite gehalten und oben von drei Seiten gedrückt; die am stärksten beanspruchten Stellen werden gezeigt und erklärt (dünner Steg, Schichtrichtung). **Verbesserungen**: mehr Wände, dichtere Füllung, anders gedreht – oder weniger Material bei gleicher Sicherheit; **Struktur verbessern** verdickt die höchstbelasteten Stellen sanft (höchstens 1,5 mm), prüft das nachgerechnet und übernimmt die Form oder sichert sie als 3MF. Abschätzung (±20 %), kein Bauteilnachweis. |
| **Filament prüfen** | Beim Drucker unter „Filament“ (und automatisch angeboten bei Meldungen wie „abnormaler Filamentrückgang“, leer, verstopft): Ampeln aus dem Live-Status (Meldung, Auftrag, Slots, aktiver Slot, Feuchte, Düse), acht Schritte zum Abhaken, Düse heizen nur nach Bestätigung, „Erneut prüfen“. |
| **Benachrichtigungen** | Einstellungen → Benachrichtigungen: Druck fertig, Fehler, Pause, Filamentproblem, Abbruch. Bei geöffneter App sofort, im Hintergrund über iOS-Hintergrundabruf (etwa alle 15–30 Min., von iOS bestimmt). Echte Push-Mitteilungen bei geschlossener App brauchen einen Server und ein bezahltes Entwicklerkonto – für Drucker im Heimnetz gibt es das nicht. Tippen auf eine Filament-Mitteilung öffnet die Prüfung. |
| **Druckplatten** | Strukturiertes PEI, glattes PEI, Cool Plate und Engineering Plate je Drucker wählbar; die Betttemperatur folgt dem Filament. Der Z-Offset bleibt bei den Einstellungen des Druckers. |
| **Pause / Fehler** | Abbrechen und Fortsetzen in der App. Bei Pause oder Fehler sagt die App, ob Fortsetzen sinnvoll ist (z. B. Filament leer), erst geprüft werden sollte (z. B. Teil kalt) oder besser verworfen wird (z. B. Heizungsfehler, Teil gelöst), mit den Schritten dazwischen. |
| **Werkstatt (ohne Slicer)** | Bibliothek → Modell nach rechts wischen („Prüfen“) oder lange drücken: Festigkeit prüfen, Material und Lage vergleichen, Schwachstellen suchen, Form verstärken – ohne Projekt, Drucker oder Slicer. „Zum Druck vorbereiten“ legt das Ergebnis mit Wänden und Füllung in der Bibliothek ab und öffnet es zum Slicen. |
| **Material- und Lagevergleich** | Nach einer Berechnung: dieselbe Last in PLA, PETG, ABS, ASA, PC, Nylon und den Carbon-Varianten (Festigkeit, Steifigkeit, Gewicht, Hitzefestigkeit, was sich beim Drucken ändert) und in allen sechs Lagen auf dem Bett (Festigkeit, Stützen, Höhe) mit Empfehlung. |
| **3D-Scan** | Bibliothek → + → 3D-Scan: geführte Aufnahme mit dem LiDAR-iPhone oder Fotos/Video aus der Mediathek; das Modell wird auf dem Gerät gerechnet (Apple Object Capture), aufgeräumt (Löcher geschlossen, lose Teile entfernt) und in echter Größe gesichert. Braucht ein iPhone/iPad mit LiDAR (ab A14); nur auf echtem Gerät testbar. |
| **Drucker** | Wird im WLAN **automatisch gefunden** (ohne IP-Eingabe). Live-Daten: Fortschritt, Restzeit, Schicht, Temperaturen, Lüfter, Licht, Filament je Slot, ACE-Feuchte. **Live-Ansicht** mit Kamera (Kobra S1: FLV/H.264, U1: Webcam) und dem aktuellen Schritt (Vorbereiten, Aufheizen, Drucken …). Pause/Fortsetzen/Abbrechen, Vorheizen und Trocknen im Expertenmodus. |
| **Kalibrierung & Protokoll** | Bett-Mesh als Farbkarte, Z-Offset, Pressure Advance, Input Shaper (U1); Fehler- und Ereignislog, exportierbar. |

## Drucker verbinden

| Drucker | Verbindung | Am Drucker |
|---|---|---|
| Snapmaker U1 | Moonraker (Port 7125), wird per Bonjour gefunden | im WLAN; die Snapmaker-Cloud-Anbindung darf aktiv bleiben |
| Anycubic Kobra S1 | **LAN-Modus**: lokales MQTT/TLS + HTTP-Upload | *Einstellungen → Netzwerk → LAN-Modus an*. Achtung: Im LAN-Modus ist der Drucker **nicht** mit Anycubic-Cloud/App verbunden |
| Kobra S1 mit Rinkhals | Moonraker | Community-Firmware Rinkhals |
| Bambu Lab P1S | **LAN-Modus**: lokales MQTT/TLS (Port 8883) + FTPS-Upload (Port 990) | *Einstellungen → WLAN → LAN-Modus an*; Seriennummer (Typenschild) und Zugangscode (Display) in der App eintragen; microSD-Karte einlegen. Das Slicen läuft auf dem iPhone (kein Cloud-Slicer für den P1S) |

**Bambu P1S – ehrlicher Stand:** G-Code, Verbindung, Upload und Druckstart sind gegen einen nachgebauten P1S (`tools/virtualprinters/bambu_p1s_sim.py`) geprüft, nicht gegen echte Hardware. Das erste Mal am echten Gerät bitte daneben stehen und Mehrfarbdruck (AMS) erst nach einem einfarbigen Test nutzen. Kamera-Bild und automatische Suche mit Seriennummer fehlen noch.

Beim Kobra S1 gilt: Slot im Modell = Slot der ACE Pro; die Zuordnung wird beim Start mitgeschickt.

## Getestet – mit virtuellen Druckern

Ohne Zugriff auf die echten Geräte wird alles gegen möglichst echte Gegenstücke geprüft (automatisch in GitHub Actions):

- **Virtueller Snapmaker U1**: der *unveränderte* Moonraker von Snapmaker auf `u1sim` (simulierter Klipper mit vier Köpfen,
  RFID-Filamenten und Druckablauf). Test: Live-Daten, Slicen passend zu den eingelegten Spulen, Upload mit Start,
  Metadaten/Vorschaubild wie vom Drucker gelesen, Pause/Fortsetzen/Abbruch, Temperaturen, Druck bis „Fertig“.
- **Virtueller Kobra S1 mit ACE Pro** (`tools/virtualprinters/kobra_s1_sim.py`): LAN-Handshake mit Signatur und AES,
  MQTT über TLS, Upload, ACE-Slots/Feuchte/Trocknen, Druckablauf, G-Code-Prüfung. Test aus Swift und als UI-Test der App.
- **OrcaSlicer in der Cloud**: Selbsttest bei jeder Änderung – vom Swift-Code exportierte Aufträge (U1 ein-/zweifarbig,
  Kobra zweifarbig mit Steckverbindern) werden mit OrcaSlicer gesliced und geprüft.
- **UI-Tests im iPhone-Simulator** mit Screenshots: Tabs, Suche + Download + Slicen, beide Drucker, Teilen-Werkzeug,
  Druck auf dem virtuellen Kobra.
- **Virtueller Bambu P1S** (`tools/virtualprinters/bambu_p1s_sim.py`): MQTT über TLS, FTPS-Upload, AMS, Druckablauf; geprüft wird auch, dass die hochgeladene `.gcode.3mf` gültig ist und keine Klipper-Befehle enthält.
- **72 automatische Tests im Swift-Paket** (davon 5 mit virtuellen Druckern; Import, Slicer-Funktionen, G-Code, Empfehlungen, Protokolle, Cloud-Client gegen nachgebaute GitHub-API).

Lokal auf dem Mac (ohne GitHub-Minuten): `tools/test-local.sh` – siehe [TESTING.md](TESTING.md), dort auch, wie dein Mac
die GitHub-Läufe kostenlos übernimmt.

## Aufbau

```
App/MakerSlice/             SwiftUI-App (Entdecken, Bibliothek, Vorbereiten, Drucker, Einstellungen)
App/MakerSliceUITests/      UI-Tests (Simulator)
Packages/MakerSliceCore/    Swift-Paket: SliceKit (Slicer, G-Code, 3MF, Empfehlungen, Erklärungen),
                            PrinterKit (U1/Moonraker, Kobra-LAN, Cloud-Slicing), MakerWorldKit (Suche)
tools/cloudslice/           OrcaSlicer-Aufruf und G-Code-Prüfung für den Cloud-Workflow
tools/virtualprinters/      Virtueller U1 (u1sim + Snapmaker Moonraker) und virtueller Kobra S1
tools/profiles/             Erzeugt die Filamentbibliothek aus den OrcaSlicer-Profilen
.github/workflows/          CI, Cloud slice, App release (IPA)
```

## Ehrliche Grenzen

- **Nicht an echten Druckern getestet.** Die virtuellen Drucker bilden die Protokolle nach (beim U1 mit dem originalen
  Moonraker), führen aber keinen G-Code physisch aus. Ersten Druck bitte mit einem kleinen Teil und dabeistehen.
  Der Kobra-S1-LAN-Modus ist inoffiziell (reverse-engineered) und kann durch Firmware-Updates brechen.
- **MakerWorld** hat keine offizielle API; Suche und Downloads laufen über deinen Login im eingebauten Browser.
- iPhone-Slicer: keine Baumstützen, variable Schichthöhe und Arachne-Wände – dafür gibt es das Cloud-Slicing mit OrcaSlicer.
  **Bemalte Mehrfarb-Modelle** (MakerWorld/Bambu Studio) und Farbwechsel bei Höhe slict nur der iPhone-Slicer: Die Bemalung färbt
  die Wandstärke (ca. 1,2 mm) und die Deck-/Bodenschichten; das Innere druckt in der Grundfarbe (das ist die übliche Näherung,
  OrcaSlicers exakte Segmentierung ist feiner). Solche Aufträge laufen deshalb nie über die Cloud.
- Die Druckzeit-Schätzung des iPhone-Slicers enthält Aufheizen/Leveln und Werkzeugwechsel und liegt daher meist über der von OrcaSlicer.
- Das Bett-Mesh liefert der Kobra nur mit Rinkhals. Die Kamera des Kobra S1 (FLV/H.264) zeigt die App in der Live-Ansicht.
- GitHub Actions: Bei privaten Repositories zählen macOS-Minuten zehnfach. Deshalb laufen bei jedem Push nur die Linux-Tests;
  iOS-Tests und App-Build nur auf Wunsch oder auf deinem eigenen Mac (siehe [TESTING.md](TESTING.md)).

## Lizenzen und Quellen

Druckprofile aus OrcaSlicer (AGPL-3.0, nur als Daten übernommen), Clipper2 (Boost), u1sim aus u1-companion (MIT, nur im
Test), Snapmaker Moonraker (GPL-3.0, nur im Test geladen). Kobra-LAN-Protokoll nach anycubic-lan, anycubic_ha_local,
kobra-lan-cli und Rinkhals.
