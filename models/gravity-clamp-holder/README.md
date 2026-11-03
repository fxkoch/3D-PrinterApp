# Schwerkraft-Klemmhalter (Zahnbürste / Rasierer)

Eigene, parametrische Nachkonstruktion des Prinzips aus
[diesem Video](https://youtu.be/sRcxLJ-Aem0): Das Gerät steht in einem Fußring,
sein Gewicht zieht einen Schlitten nach unten und der Schlitten klappt zwei
seitliche Backen gegen das Gerät. Hebt man das Gerät heraus, öffnen die Backen
wieder.

![Montage](assembly.png)

Moderne Optik: rundum abgerundete Formen, angefaste Sichtkanten, weiche
Backen mit großen Radien und bündig versenkte Schrauben in Abdeckscheiben.
Farbvorschlag: Wandplatte weiß, Schlitten hellgrau, Arme und Scheiben
anthrazit (matt), z. B. PETG oder PLA Matte.

Links: offen (Schlitten oben). Rechts: leer/geschlossen (Schlitten unten).

![Mechanik](mechanism_open_vs_closed.png)

## Fertige Varianten für deine Geräte

![Mijia und OneBlade](presets_mijia_oneblade.png)

| Variante | Gemessen (Unterseite) | Fußmulde | Klemmbereich | Ordner |
|---|---|---|---|---|
| Xiaomi Mijia Zahnbürste | 28,4 × 29,2 mm, rund | 30,6 × 31,4 mm, rund | ca. 24–45 mm | `stl/mijia/` |
| Philips OneBlade Pro 360 (QP6541) | 34,7 × 33,2 mm, abgerundet-eckig | 36,8 × 35,3 mm, Eckradius 9 mm | ca. 30–50 mm | `stl/oneblade/` |

In jedem Ordner liegen alle Einzelteile und eine komplette Druckplatte
(`print_plate_all.stl`). In OpenSCAD wählst du die Variante mit
`preset = "mijia"` oder `preset = "oneblade"` aus. Mit `preset = "custom"`
gelten die eigenen Werte `c_dev_w`, `c_dev_d`, `c_foot_w`, `c_foot_d` und
`c_foot_r`. Die STLs direkt in `stl/` sind die alte 30-mm-Standardvariante.

Die Öffnung im Boden der Fußmulde bleibt frei: Ladebuchse bzw. Ladekontakte
sind erreichbar, und Wasser läuft ab.

## So funktioniert's

- Jeder Arm dreht sich um eine M3-Schraube in der Wandplatte.
- Ein kurzer Hebel (12 mm) zeigt zur Mitte. Sein Zapfen steckt in einem
  waagrechten Langloch im Schlitten.
- Wenn der Schlitten nach unten geht, zieht er die Hebel mit. Die Arme drehen
  sich dadurch und die Backen (ca. 20–35 mm über dem Drehpunkt) schwenken
  nach innen. Übersetzung etwa 1 : 2,5.
- Beim Einsetzen drückt das Gerät die oben angefasten Backen auseinander. Das
  hebt den Schlitten, bis das Gerät im Fußring steht. Dann zieht das Gewicht
  die Backen zu.

## Teile

| Datei | Anzahl | Druckhinweis |
|---|---|---|
| `stl/backplate.stl` | 1 | Rückseite auf dem Druckbett |
| `stl/slider.stl` | 1 | steht auf dem Boden des Fußrings |
| `stl/arm_right.stl` | 1 | flach, Backe zeigt nach oben |
| `stl/arm_left.stl` | 1 | gespiegelt |
| `stl/washer.stl` | 4 | Abdeckscheibe mit Senkung, Senkkopf sitzt bündig |
| `stl/print_plate_all.stl` | – | alles zusammen auf einer Platte (154 × 138 mm) |

Keine Stützstrukturen nötig. Empfehlung: PETG (Bad), 0,2 mm Schichthöhe,
4 Wände, 25 % Infill.

**Schrauben:** M3-Senkkopf (DIN 7991 / ISO 10642): 2 × M3×8 (Drehpunkte
der Arme), 2 × M3×12 (Führung des Schlittens). Sie werden direkt in die 2,6-mm-Bohrungen der Dome geschraubt
(selbstschneidend). Nur so fest anziehen, dass Arme und Schlitten noch leicht
laufen.

**Wand:** doppelseitiges Klebeband (z. B. 3M VHB) auf der Rückseite, oder
`wall_screws = true` setzen. Dann gibt es zwei Senkbohrungen.

## Zusammenbau

1. Schlitten auf die beiden unteren Dome stecken (die Langlöcher zeigen nach
   unten) und mit Abdeckscheibe + M3×12 sichern.
2. Arme auf die Drehpunkt-Dome stecken, sodass die Zapfen in den waagrechten
   Langlöchern des Schlittens sitzen. Mit Abdeckscheibe + M3×8 sichern.
3. Prüfen: Schlitten hochschieben → Backen öffnen; loslassen → Backen schließen.

## Anpassen (OpenSCAD)

Die Parameter oben in `gravity_clamp_holder.scad` sind auch im Customizer
einstellbar:

| Parameter | Standard | Bedeutung |
|---|---|---|
| `preset` | custom | `mijia`, `oneblade` oder `custom` |
| `c_dev_w` | 30 | Breite des Geräts auf Klemmhöhe |
| `c_dev_d` | 30 | Tiefe des Geräts |
| `c_foot_w` / `c_foot_d` | 32 / 32 | Innenmaß der Fußmulde |
| `c_foot_r` | 16 | Eckradius der Fußmulde (halbe Breite = rund) |
| `pad_h` | 30 | Höhe der Backen |
| `edge` | 1,2 | Fase an den Sichtkanten |
| `travel_up` / `travel_down` | 4 / 3 | Schlittenweg (öffnen / schließen) |

Mit den Standardwerten klemmt der Halter Geräte mit 26–40 mm Breite. Am besten
vor dem Drucken die eigene Bürste bzw. den OneBlade messen: Breite auf ca.
4–6 cm Höhe und den Durchmesser des Fußes.

Einzelteil exportieren:

```sh
openscad -D 'part="slider"' -D dev_w=32 -o slider.stl gravity_clamp_holder.scad
```

Für die Ansicht `part="assembly"` wählen. Mit `s` (−4 … 3) bewegt man den
Schlitten.

## Geprüft

Alle Teile wurden in drei Schlittenstellungen (offen, neutral, geschlossen) auf
Überschneidungen geprüft. Dabei waren die Abdeckscheiben und ein
eingesetztes Gerät mit drin, für die Standardvariante sowie für Mijia und
OneBlade: keine Kollisionen. Alle STLs sind
geschlossen (watertight) und liegen flach auf dem Druckbett.

Nicht geprüft ist ein echter Druck. Die Klemmkraft hängt von Reibung und
Spiel ab. Wenn die Backen zu schwach greifen, `lever` verkleinern oder die
Backen mit einem Streifen TPU/Gummi bekleben.
