# MakerSlice aufs iPhone bringen

Apple erlaubt Apps außerhalb des App Stores nur mit einer Signatur über deine Apple-ID. Dafür gibt es
drei Wege – vom einfachsten zum komfortabelsten. Voraussetzung: iPhone mit **iOS 17 oder neuer**.

| Weg | Was du brauchst | Aufwand | Gültigkeit |
|---|---|---|---|
| **A. Xcode** (empfohlen, du hast einen Mac) | Mac mit Xcode, kostenlose Apple-ID | ca. 10 Min. einmalig | 7 Tage, dann erneut ▶︎ drücken |
| **B. Sideloadly / AltStore** | Fertige `.ipa` aus GitHub, kostenlose Apple-ID | ca. 5 Min. | 7 Tage, automatische Verlängerung möglich |
| **C. TestFlight** | Bezahlter Apple-Entwickler-Account (99 €/Jahr) | ca. 30 Min. einmalig | 90 Tage je Build, Updates per Push |

Mit einem bezahlten Entwickler-Account gelten A und B ein Jahr statt sieben Tage.

---

## A. Direkt aus Xcode (am einfachsten mit deinem Mac)

1. Einmalig im Terminal:
   ```bash
   brew install xcodegen
   git clone https://github.com/fxkoch/3D-PrinterApp.git
   cd 3D-PrinterApp
   git checkout claude/makerslice-ios-app     # bzw. main, sobald zusammengeführt
   xcodegen
   open MakerSlice.xcodeproj
   ```
2. In Xcode: links **MakerSlice** (blaues Symbol) → Target **MakerSlice** → **Signing & Capabilities**
   → bei *Team* deine Apple-ID wählen (*Add an Account…*, falls noch keine eingetragen ist).
   Meldet Xcode „Bundle Identifier nicht verfügbar“: `de.makerslice.app` z. B. in `de.deinname.makerslice` ändern.
3. iPhone per Kabel anschließen, oben als Ziel auswählen.
   Beim ersten Mal am iPhone: *Einstellungen → Datenschutz & Sicherheit → Entwicklermodus* einschalten (Neustart).
4. Für schnelles Slicen: *Product → Scheme → Edit Scheme… → Run → Build Configuration: Release*.
5. **▶︎** drücken. Am iPhone: *Einstellungen → Allgemein → VPN & Geräteverwaltung* → deiner Apple-ID vertrauen.
6. Beim ersten Start **„Lokales Netzwerk“ erlauben** – sonst findet die App die Drucker nicht.

Nach 7 Tagen startet die App nicht mehr: iPhone anschließen und in Xcode erneut ▶︎ drücken (Daten bleiben erhalten).

## B. Fertige App-Datei (.ipa) mit Sideloadly oder AltStore

Die fertige Datei baut GitHub für dich:

1. Auf github.com im Repository → **Actions** → **App release** → **Run workflow** (Version z. B. `1.0`).
   Nach ca. 10 Minuten liegt unter **Releases** die Datei `MakerSlice-1.0.ipa`
   (alternativ ein Tag `v1.0` pushen). Da das Repository privat ist, musst du dafür bei GitHub angemeldet sein.
2. **Sideloadly** (Mac oder Windows, sideloadly.io): iPhone per Kabel anschließen, die `.ipa` ins Fenster
   ziehen, Apple-ID eingeben, **Start**. Danach wie oben der Apple-ID vertrauen und den Entwicklermodus einschalten.
   Mit *Automatic refresh* verlängert Sideloadly die App selbst, solange Mac und iPhone im selben WLAN sind.
3. **AltStore** (altstore.io): AltServer auf dem Mac installieren, darüber AltStore aufs iPhone bringen,
   dann die `.ipa` am iPhone mit *Teilen → AltStore* öffnen. AltStore verlängert im Hintergrund über das WLAN.

## C. TestFlight (komfortabel, mit bezahltem Entwickler-Account)

1. Im Apple Developer Portal eine App-ID (z. B. `de.deinname.makerslice`) und in App Store Connect eine App anlegen.
2. In Xcode (Weg A) das Team auf den bezahlten Account stellen, *Product → Archive* → *Distribute App* →
   *TestFlight & App Store*.
3. Am iPhone die TestFlight-App installieren und die Einladung annehmen. Updates kommen dann automatisch.

---

## Nach der Installation

- **Drucker** → **＋**: Snapmaker U1 wird automatisch im WLAN gefunden. Beim Kobra S1 die IP-Adresse eintragen
  (am Drucker unter *Einstellungen → Netzwerk*) und dort den **LAN-Modus** einschalten.
  Hinweis: Im LAN-Modus ist der Kobra S1 nicht mit der Anycubic-Cloud/App verbunden; der U1 bleibt mit der
  Snapmaker-Cloud verbunden und ist trotzdem lokal erreichbar.
- **Einstellungen → Profi-Slicing** (optional): OrcaSlicer in der Cloud einrichten (Anleitung in der App).
- Fehler oder Verbindungsabbrüche stehen unter **Drucker → Protokoll**.
