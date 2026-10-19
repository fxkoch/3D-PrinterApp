# MakerSlice – kostenlose 3D-Modelle finden, auf dem iPhone slicen, direkt drucken

iPhone-App (SwiftUI, iOS 17+) für den **Snapmaker U1** und den **Anycubic Kobra S1 mit ACE Pro**.
Modelle aus **MakerWorld** und **Printables** suchen, auf dem Gerät slicen (an den jeweiligen Drucker
angepasst), Empfehlungen für den perfekten Druck übernehmen und per WLAN an den Drucker schicken.
Gestaltung: ruhig und reduziert im macOS-Stil, mit Expertenmodus für alle Parameter.

## Funktionen

| Bereich | Was geht |
|---|---|
| **Entdecken** | Native Suche über **Printables** (offene API) und **MakerWorld** (über deinen Login im eingebauten Browser), nur kostenlose Modelle, Sortierung nach Relevanz, Beliebtheit, Neu oder Bewertung. Detailansicht mit Dateien (Printables) bzw. Druckprofilen (MakerWorld) → „Drucken“ lädt herunter und öffnet das Projekt. |
| **Bibliothek** | Alle Modelle; Import aus Dateien/AirDrop/„Öffnen in …“ (3MF, STL, OBJ); eingebauter Testwürfel. |
| **Vorbereiten** | 3D-Vorschau, Druckerwahl (U1 / Kobra S1), 4 Material-Slots, Objekte je Slot zuweisen, drehen, flach legen, skalieren, duplizieren, anordnen. MakerWorld-3MF (Bambu-Projekte inkl. Platten) werden automatisch auf Bauraum, Material und Profil deines Druckers umgerechnet. |
| **Teilen** | Zu große Objekte per Schnittebene (X/Y/Z) mit Live-Vorschau teilen – mit **Zapfen** (angeformt) oder **Dübeln** (separat gedruckt, 0,2 mm Spiel). „Automatisch passend teilen“ zerlegt so oft wie nötig. |
| **Empfehlungen** | Vor jedem Druck: Stützen ja/nein (nur Bett / überall), Brim bei kleiner Auflagefläche oder verzugsanfälligem Material, Glätten (Ironing) bei flachen Oberseiten, Füllmuster (Gyroid für TPU, Kubisch für hohe Teile), Schichthöhe, PETG-Plattenwarnung, Reinigungsturm bei ACE-Mehrfarbdruck, Abgleich mit dem eingelegten Filament, automatisches Teilen. Mit einem Tipp übernehmen. |
| **Slicer** | Läuft komplett auf dem iPhone: Wände, Ober-/Unterseiten, Füllung (Gitter, Linien, Dreiecke, Kubisch, Gyroid), **Brückenerkennung** (beste Richtung, eigene Geschwindigkeit/Kühlung), **Ironing**, Stützen, Brim/Skirt, Z-Hop, Rückzug, Pressure Advance je Filament, Flussbegrenzung, Abkühl-Verlangsamung, Werkzeugwechsel, **Reinigungsturm** für die ACE Pro. Schicht-für-Schicht-Vorschau. |
| **Filamente** | **325 Profile** aus den offiziellen OrcaSlicer-Daten: 25 für den Kobra S1, 59 für den U1, 241 Markenfilamente (Bambu, Polymaker, eSUN, Elegoo, SUNLU, JAYO, Overture …). Auswahl lädt die empfohlenen Werte; im Expertenmodus feinjustierbar mit „Auf Empfehlung zurücksetzen“. Eingelegtes Material (RFID am U1, ACE Pro am Kobra) wird erkannt und vorgeschlagen. |
| **Drucker** | Live-Daten: Fortschritt, Restzeit, Schicht, Temperaturen (Düsen, Bett, Kammer), Lüfter, Tempo-Modus, Licht, Filament je Slot, ACE-Feuchte/-Temperatur und Trocknen (Kobra), Kamerabild (Moonraker). Pause/Fortsetzen/Abbrechen, Vorheizen. |
| **Kalibrierung** | Bett-Mesh als Farbkarte mit Unebenheit, Z-Offset, Pressure Advance je Kopf, Input Shaper (Moonraker); Gerätefunktionen/Firmware (Kobra LAN-Modus). |
| **Protokoll** | Fehler- und Ereignislog (Verbindungsabbrüche, Druckfehler, Uploads, Drucker-Konsole), filterbar, exportierbar. |

## Drucker verbinden

| Drucker | Verbindung | Vorbereitung am Drucker |
|---|---|---|
| Snapmaker U1 | Moonraker (Port 7125), wird per Bonjour gefunden | im WLAN, IP unter Einstellungen → WLAN |
| Anycubic Kobra S1 | **LAN-Modus** (Original-Firmware): lokales MQTT/TLS + HTTP-Upload | Einstellungen → Netzwerk → **LAN-Modus an** (die Anycubic-Cloud ist dann getrennt) |
| Kobra S1 mit Rinkhals | Moonraker | Community-Firmware Rinkhals installiert |

Beim Kobra S1 wird beim Start die Zuordnung „Slot im Modell → Slot der ACE Pro“ mitgeschickt.

## Installation (Mac mit Xcode 16)

```bash
brew install xcodegen          # einmalig
git clone https://github.com/fxkoch/3D-PrinterApp.git && cd 3D-PrinterApp
git checkout claude/makerslice-ios-app
xcodegen                       # erzeugt MakerSlice.xcodeproj
open MakerSlice.xcodeproj
```

1. Projekt **MakerSlice** → Target **MakerSlice** → *Signing & Capabilities* → dein **Team** wählen
   (kostenloser Apple-Account reicht; die App läuft dann 7 Tage). Bei Bedarf Bundle-ID `de.makerslice.app` ändern.
2. iPhone verbinden, als Ziel wählen, **▶︎ Run**. Für schnelles Slicen: *Product → Scheme → Edit Scheme → Run → Release*.
3. Auf dem iPhone: *Einstellungen → Allgemein → VPN & Geräteverwaltung* → Entwickler vertrauen;
   beim ersten Start **Lokales Netzwerk** erlauben.

## Tests

- `cd Packages/MakerSliceCore && swift test` – 51 Tests: Import (STL/3MF/OBJ, Bambu-Projekte), Slicer, G-Code für beide
  Drucker, Reinigungsturm, Brücken, Ironing, Gyroid, Teilen mit Verbindern, Empfehlungen, Filament-Bibliothek,
  Kobra-LAN-Handshake (MD5/AES), MQTT-Kodierung, Statusauswertung, Moonraker-Kalibrierdaten, Suche.
  Mit `LIVE_NETWORK=1` zusätzlich ein echter Such- und Download-Test gegen Printables.
- GitHub Actions baut die iOS-App, führt UI-Tests im iPhone-Simulator aus (Tabs, Testwürfel für U1 und Kobra S1
  slicen, Materialwahl, Empfehlungen, Drucken ohne Drucker) und legt Screenshots als Artefakt ab.

## Aufbau

```
App/MakerSlice/             SwiftUI-App
  Model/                    AppModel, Bibliothek, Druckerverwaltung, Projekt, Protokoll
  Views/                    Entdecken, Bibliothek, Vorbereiten (+Teilen, Material, Empfehlungen, Experte), Drucker, Einstellungen
App/MakerSliceUITests/      UI-Tests (Simulator)
Packages/MakerSliceCore/    Plattformunabhängiges Swift-Paket
  SliceKit/                 Import, Slicer, Teilen, Empfehlungen, G-Code (U1- und Kobra-Dialekt), Filament-Bibliothek
  PrinterKit/               Moonraker-Client, Kobra-S1-LAN-Client (MQTT/TLS), Status, Kalibrierung, Bonjour
  MakerWorldKit/            MakerWorld- und Printables-Suche/Downloads
  CClipper/, CZip/          Clipper2 (Boost-Lizenz) und zlib-Anbindung
```

## Ehrliche Grenzen

- **Nicht an echten Druckern getestet** (ich habe keinen Zugriff darauf). Alles Protokoll- und G-Code-seitige ist
  gegen die offiziellen Profile und dokumentierte Community-Protokolle gebaut und durch Tests abgesichert. Erster Druck
  bitte mit einem kleinen Teil und dabeistehen. Der Kobra-S1-LAN-Modus ist inoffiziell (reverse-engineered) und kann
  durch Firmware-Updates brechen; Druckstart mit ACE-Zuordnung ist in der Community nur teilweise bestätigt.
- **MakerWorld** hat keine offizielle API; Suche und Downloads laufen über deinen Login im eingebauten Browser. Ändert
  MakerWorld etwas, funktionieren die Download-Knöpfe der Website weiterhin (die App übernimmt die Datei).
- Slicer: kein Niveau von OrcaSlicer bei Baumstützen, variabler Schichthöhe, Arachne-Wänden und Farbbemalung
  (gemalte Mehrfarb-Modelle werden je Objekt einfarbig gedruckt).
- Die Kamera des Kobra S1 (FLV-Stream) wird nicht angezeigt; das Bett-Mesh liefert der Kobra nur mit Rinkhals.
- Eine fertig signierte App (.ipa) kann ich nicht ausliefern – das Signieren erfordert deinen Apple-Account (siehe Installation).
