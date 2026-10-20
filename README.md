# MakerSlice – kostenlose 3D-Modelle finden, slicen, direkt drucken

iPhone-App (SwiftUI, iOS 17+) für den **Snapmaker U1** und den **Anycubic Kobra S1 mit ACE Pro**.
Modelle aus **MakerWorld** und **Printables** suchen, auf dem iPhone **oder mit dem echten OrcaSlicer in der
Cloud** slicen, Empfehlungen für den perfekten Druck übernehmen und per WLAN an den Drucker schicken.
Gestaltung: ruhig und reduziert im macOS-Stil, mit Expertenmodus – jede Einstellung ist mit ⓘ erklärt.

**Installation aufs iPhone:** siehe [INSTALL.md](INSTALL.md) (Xcode, Sideloadly/AltStore oder TestFlight).

## Funktionen

| Bereich | Was geht |
|---|---|
| **Entdecken** | Suche über **Printables** und **MakerWorld** (über deinen Login im eingebauten Browser), nur kostenlose Modelle, Sortierung nach Relevanz, Beliebtheit, Neu oder Bewertung. „Drucken“ lädt herunter und öffnet das Projekt. |
| **Vorbereiten** | 3D-Vorschau, Drucker (U1 / Kobra S1), 4 Material-Slots, Objekte je Slot, drehen, flach legen, skalieren, duplizieren, anordnen. MakerWorld-3MF (Bambu-Projekte inkl. Platten) werden auf Bauraum, Material und Profil deines Druckers umgerechnet. |
| **Teilen** | Zu große Objekte per Schnittebene (X/Y/Z) mit Live-Vorschau teilen – mit **Zapfen** oder **Dübeln** (0,2 mm Spiel). „Automatisch passend teilen“ zerlegt so oft wie nötig. |
| **Empfehlungen** | Vor jedem Druck, mit einem Tipp übernehmen: Stützen, Brim, Glätten, Füllmuster, Schichthöhe, Platte, Reinigungsturm, eingelegtes Filament – plus druckerspezifische Hinweise aus Hersteller- und Community-Erfahrung: TPU nicht über die ACE Pro, kurzer Rückzug bei TPU (Werkzeugwechsel-Staus am U1), Trocknen bei feuchtem Filament (Feuchte aus der ACE Pro), PETG-Fäden und Elefantenfuß, passgenaue Steckverbinder, Düsenspitze am Kobra, Vasenmodus-Prüfung. |
| **Slicer (iPhone)** | Wände (Reihenfolge innen/außen), Naht (hinten / in Ecken / zufällig), Ober-/Unterseiten (monoton, Linien, konzentrisch), Füllung (Gitter, Linien, Dreiecke, Kubisch, Gyroid), Brückenerkennung, Ironing, Stützen, Brim/Skirt, Elefantenfuß-Ausgleich, **Vasenmodus** (durchgehende Spirale), **Fuzzy Skin**, Z-Hop, Rückzug, Pressure Advance, Flussbegrenzung, Abkühl-Verlangsamung, Werkzeugwechsel, Reinigungsturm für die ACE Pro. Schicht-Vorschau. |
| **Profi-Slicing (Cloud)** | Optional: Der **echte OrcaSlicer** (2.4) rechnet auf GitHub Actions mit den offiziellen Profilen von Snapmaker/Anycubic und deinen Einstellungen; der G-Code kommt nach 1–3 Minuten zurück – inklusive Schicht-Vorschau. Einrichtung in der App unter *Einstellungen → Profi-Slicing*. |
| **Erklärungen** | Jede Einstellung (Slicer und Filament) hat ein ⓘ: was sie bewirkt, was mehr/weniger bedeutet, Praxistipp mit Werten für U1/Kobra. Auf Wunsch direkt unter jeder Einstellung eingeblendet. |
| **Filamente** | **325 Profile** aus den offiziellen OrcaSlicer-Daten (25 Kobra S1, 59 U1, 241 Markenfilamente). Auswahl lädt die empfohlenen Werte; im Expertenmodus feinjustierbar mit „Auf Empfehlung zurücksetzen“. Eingelegtes Material (RFID am U1, ACE Pro am Kobra) wird erkannt. |
| **Drucker-Display** | Der G-Code enthält Vorschaubilder (U1: 48 und 300 px, Kobra: 230×110 px) sowie Druckzeit, Filament je Slot und Temperaturen im OrcaSlicer-Format, damit Drucker und Moonraker sie anzeigen. |
| **Drucker** | Live-Daten: Fortschritt, Restzeit, Schicht, Temperaturen, Lüfter, Licht, Filament je Slot, ACE-Feuchte und Trocknen, Kamerabild (U1). Pause/Fortsetzen/Abbrechen, Vorheizen. |
| **Kalibrierung & Protokoll** | Bett-Mesh als Farbkarte, Z-Offset, Pressure Advance, Input Shaper (U1); Fehler- und Ereignislog, exportierbar. |

## Drucker verbinden

| Drucker | Verbindung | Am Drucker |
|---|---|---|
| Snapmaker U1 | Moonraker (Port 7125), wird per Bonjour gefunden | im WLAN; die Snapmaker-Cloud-Anbindung darf aktiv bleiben |
| Anycubic Kobra S1 | **LAN-Modus**: lokales MQTT/TLS + HTTP-Upload | *Einstellungen → Netzwerk → LAN-Modus an*. Achtung: Im LAN-Modus ist der Drucker **nicht** mit Anycubic-Cloud/App verbunden |
| Kobra S1 mit Rinkhals | Moonraker | Community-Firmware Rinkhals |

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
- **72 automatische Tests im Swift-Paket** (davon 5 mit virtuellen Druckern; Import, Slicer-Funktionen, G-Code, Empfehlungen, Protokolle, Cloud-Client gegen nachgebaute GitHub-API).

Lokal: `cd Packages/MakerSliceCore && swift test`; virtuelle Drucker siehe `tools/virtualprinters/`.

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
- iPhone-Slicer: keine Baumstützen, variable Schichthöhe, Arachne-Wände und Farbbemalung – dafür gibt es das Cloud-Slicing
  mit OrcaSlicer (Farbbemalung aus MakerWorld-Projekten wird aber auch dort nicht übernommen, jedes Objekt hat einen Slot).
- Die Druckzeit-Schätzung des iPhone-Slicers enthält Aufheizen/Leveln und Werkzeugwechsel und liegt daher meist über der von OrcaSlicer.
- Kamera des Kobra S1 (FLV-Stream) wird nicht angezeigt; das Bett-Mesh liefert der Kobra nur mit Rinkhals.
- GitHub Actions: Bei privaten Repositories zählen macOS-Minuten zehnfach (2000 Freiminuten/Monat). Cloud-Slicing läuft auf
  Linux (ca. 1–3 Minuten je Auftrag); der App-Build nur bei Bedarf.

## Lizenzen und Quellen

Druckprofile aus OrcaSlicer (AGPL-3.0, nur als Daten übernommen), Clipper2 (Boost), u1sim aus u1-companion (MIT, nur im
Test), Snapmaker Moonraker (GPL-3.0, nur im Test geladen). Kobra-LAN-Protokoll nach anycubic-lan, anycubic_ha_local,
kobra-lan-cli und Rinkhals.
