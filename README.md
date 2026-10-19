# MakerSlice – MakerWorld → Snapmaker U1, direkt vom iPhone

iPhone-App (SwiftUI, iOS 17+), die Modelle direkt aus **MakerWorld** lädt, sie **auf dem iPhone slicet** und den
G-Code per WLAN an den **Snapmaker U1** schickt. Bedienung angelehnt an Bambu Handy:
Modell öffnen → „Auf U1 drucken“ → Profil wählen → Slicen → Drucken.

## Funktionen

| Bereich | Was geht |
|---|---|
| **Entdecken** | MakerWorld eingebettet (eigener Login bleibt gespeichert). Auf jeder Modellseite: Button **„Auf U1 drucken“** → Liste der Druckprofile (Zeit, Platten, Gewicht) → 3MF wird geladen. Auch die „Download“-Knöpfe der Website werden abgefangen (3MF/STL). Links lassen sich einfügen. |
| **Bibliothek** | Alle geladenen/importierten Modelle. Import aus der Dateien-App, AirDrop, „Öffnen in …“ (3MF, STL, OBJ). |
| **Vorbereiten** | 3D-Vorschau auf dem 270×270-Bett, Platten-Auswahl bei Bambu-Projekten, Objekte pro **Druckkopf T1–T4** zuweisen, drehen, flach legen, skalieren, duplizieren, automatisch anordnen. Einstellungen aus dem MakerWorld-Projekt (Schichthöhe, Wände, Füllung, Filamenttyp/-farbe) werden übernommen. |
| **Slicer** | Läuft komplett auf dem Gerät: Wände, Ober-/Unterseiten, Füllung (Gitter, Linien, Dreiecke, Kubisch), Stützen (nur vom Bett / überall), Brim, Skirt, Z-Hop, Rückzug, Abkühl-Verlangsamung, Flussbegrenzung je Material, **Werkzeugwechsel zwischen den 4 Köpfen**. Schicht-für-Schicht-Vorschau. |
| **Drucken** | G-Code mit der offiziellen U1-Startsequenz (Auto-Feed, Flusskalibrierung, Düsenreinigung, adaptives Bed-Mesh, Zeitraffer) → Upload & Start über Moonraker. |
| **Drucker** | Live-Status (Fortschritt, Restzeit, Schicht), Kamera-Bild, Pause/Fortsetzen/Abbrechen, Temperaturen, **per RFID erkanntes Filament in jedem Kopf** (wird beim Vorbereiten automatisch übernommen), Drucker-Suche im WLAN (Bonjour). |

## Installation (Mac mit Xcode 15+)

```bash
brew install xcodegen          # einmalig
git clone <dieses Repo> && cd 3D-PrinterApp
xcodegen                       # erzeugt MakerSlice.xcodeproj
open MakerSlice.xcodeproj
```

1. In Xcode links das Projekt **MakerSlice** → Target **MakerSlice** → *Signing & Capabilities* → dein **Team** wählen
   (ein kostenloser Apple-Account reicht; die App läuft dann 7 Tage, danach neu installieren).
   Falls die Bundle-ID schon vergeben ist, `de.makerslice.app` in etwas Eigenes ändern.
2. iPhone per Kabel verbinden, oben als Ziel auswählen, **▶︎ Run**.
3. Auf dem iPhone ggf. *Einstellungen → Allgemein → VPN & Geräteverwaltung* → Entwickler vertrauen.
   Beim ersten Start die Frage nach dem **lokalen Netzwerk** erlauben (sonst findet die App den Drucker nicht).

> Tipp: Für flottes Slicen *Product → Scheme → Edit Scheme → Run → Build Configuration: Release* wählen.

## Drucker verbinden

Tab **Drucker** → „Drucker hinzufügen“. Der U1 erscheint automatisch, wenn er im selben WLAN ist
(er meldet sich per Bonjour als `_snapmaker._tcp`). Alternativ die IP-Adresse eintragen (Port 7125 wird
automatisch genutzt) und „Verbindung testen“.

## Aufbau

```
App/MakerSlice/               SwiftUI-App (Tabs Entdecken / Bibliothek / Drucker, Vorbereiten-Ansicht)
Packages/MakerSliceCore/      Plattformunabhängiges Swift-Paket (auch unter Linux getestet)
  SliceKit/                   3MF/STL/OBJ-Import, Slicer, U1-G-Code-Generator
  PrinterKit/                 Moonraker-Client, Status, Bonjour-Suche
  MakerWorldKit/              MakerWorld-Links, Design-/Profil-Daten
  CClipper/                   Clipper2 (Polygon-Offsets & Boolesche Operationen, Boost-Lizenz)
  CZip/                       zlib-Anbindung zum Entpacken von 3MF
```

Tests: `cd Packages/MakerSliceCore && swift test`. Die CI (GitHub Actions) führt die Tests aus und baut die iOS-App.

Die U1-spezifischen Abläufe (Start-G-Code, Werkzeugwechsel, End-G-Code, Bauraum 270 × 270 × 270 mm)
stammen aus dem offiziellen Snapmaker-U1-Profil in OrcaSlicer; Drucker-Schnittstelle aus Snapmakers
Moonraker-Fork (`print_task_config` für die RFID-Filamentdaten).

## Bekannte Grenzen (ehrlich)

- **Nicht auf echter Hardware getestet.** Der Slicer-Kern ist durch Tests abgesichert, aber der erste Druck
  sollte ein kleines Testobjekt sein, bei dem du danebenstehst.
- **MakerWorld hat keine offizielle API.** Die App nutzt die internen Endpunkte der Website aus dem eingeloggten
  Browser heraus. Ändert MakerWorld etwas, kann „Auf U1 drucken“ ausfallen – der normale Download-Knopf der
  Website funktioniert dann weiterhin. Einige Modelle verlangen eine Anmeldung.
- **Slicer-Qualität:** Solide Grundfunktionen, aber (noch) kein Niveau von OrcaSlicer: keine Baumstützen,
  keine variable Schichthöhe, kein Ironing, keine Arachne-Wände für sehr dünne Details, keine Brücken-Erkennung,
  keine Bemalung (Multi-Color-Painting wird ignoriert – pro Objekt ein Kopf). Kein Prime-Tower; der U1 spült beim
  Werkzeugwechsel selbst (`SM_PRINT_PREEXTRUDE_FILAMENT`).
- Vorschaubilder (Thumbnails) für das Drucker-Display werden noch nicht erzeugt.
