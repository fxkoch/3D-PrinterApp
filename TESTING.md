# Testen ohne GitHub-Minuten zu verbrauchen

GitHub rechnet Minuten auf **Mac-Rechnern zehnfach** an (privates Repository). Ein kompletter iOS-Testlauf
(Build + UI-Tests) dauert ca. 12–15 Minuten und kostet damit **120–150 deiner Freiminuten**. Linux-Minuten zählen
einfach. Deshalb ist der Ablauf jetzt so eingestellt:

| Was | Wo | Kosten |
|---|---|---|
| Kern-Tests (Slicer, G-Code, Protokolle) | bei jedem Push, GitHub/Linux | ca. 2 Min. |
| Virtuelle Drucke U1 + Kobra | bei jedem Push, GitHub/Linux | ca. 2–3 Min. |
| Cloud-Slicing (OrcaSlicer) | pro Auftrag, GitHub/Linux | ca. 1–3 Min. |
| iOS-Build + UI-Tests im iPhone-Simulator | **nur auf Wunsch** (siehe unten) | 0 auf deinem Mac, sonst ca. 150 |
| App-Datei (.ipa) bauen | nur auf Wunsch | 0 auf deinem Mac, sonst ca. 30–100 |

Ein normaler Push kostet also ca. 5 Minuten statt ca. 150.

## Möglichkeit 1: Auf deinem Mac testen (empfohlen, kostenlos)

```bash
tools/test-local.sh            # alles: Kern-Tests, virtueller Kobra S1, UI-Tests im iPhone-Simulator (~10 Min.)
tools/test-local.sh --quick    # nur Kern-Tests (~1 Min.)
```

Screenshots der UI-Tests landen in `build/screenshots`.

## Möglichkeit 2: Dein Mac als GitHub-Rechner (kostenlos, automatisch)

GitHub-Läufe auf eigenen Rechnern („self-hosted runner“) verbrauchen keine Freiminuten. Dein Mac führt dann die
iOS-Tests und den App-Build aus, sobald du pushst – solange er eingeschaltet ist.

1. Auf github.com im Repository: **Settings → Actions → Runners → New self-hosted runner → macOS**.
   Die dort angezeigten Befehle im Terminal ausführen (Ordner anlegen, herunterladen, `./config.sh …`).
   Am Ende `./run.sh` starten (oder `./svc.sh install && ./svc.sh start` für den Dauerbetrieb).
2. **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   Name `MAC_RUNNER`, Wert `self-hosted`.
3. Fertig: Ab jetzt laufen iOS-Tests bei jedem Push und das App-Release auf deinem Mac.
   Variable löschen = wieder GitHub-Rechner (dann nur auf Wunsch).

Voraussetzungen auf dem Mac: Xcode mit iPhone-Simulator, Homebrew. Den Rest installiert der Lauf selbst.

## Möglichkeit 3: iOS-Tests gezielt auf GitHub starten

- Commit-Nachricht mit `[ios]` (z. B. `Material-Ansicht verbessert [ios]`) – dann läuft der iOS-Teil bei diesem Push.
- Oder auf github.com: **Actions → CI → Run workflow** (der Knopf erscheint, sobald der Code im Haupt-Branch ist).
- Pull Requests testen immer vollständig.

## Weitere Alternativen (falls du mehr Mac-Minuten brauchst)

| Anbieter | Kostenlos | Bemerkung |
|---|---|---|
| **Repository öffentlich machen** | unbegrenzt, auch Mac | einfachste Lösung – aber Code und Cloud-Slicing-Aufträge sind dann öffentlich sichtbar |
| **Codemagic** | 500 Mac-Minuten/Monat (M2, persönlicher Account) | eigene Konfiguration (`codemagic.yaml`) nötig |
| **Xcode Cloud** | 25 Stunden/Monat | nur mit bezahltem Apple-Entwickler-Account (99 €/Jahr); dafür gleich TestFlight |
| **GitHub Pro** | 3000 Minuten/Monat | kostet; Mac zählt weiterhin zehnfach |
