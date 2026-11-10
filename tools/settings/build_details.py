#!/usr/bin/env python3
"""Writes SlicerOptionDetails.generated.swift: a longer German explanation (meaning, more, less, example) and a
picture kind for every setting that has no hand-written entry in SlicerOptionDetails.swift."""
import os, re

HERE = os.path.dirname(__file__)
OUT = os.path.join(HERE, '../../Packages/MakerSliceCore/Sources/SliceKit/Settings/SlicerOptionDetails.generated.swift')
D = {}


def E(key, meaning, more=None, less=None, example=None, diagram=None):
    D[key] = (meaning, more, less, example, diagram)


# ---- Templates ---------------------------------------------------------------------------------------------------
def speed(key, what, example=None, extra=''):
    E(key, f"Geschwindigkeit, mit der {what} gedruckt wird.{extra}",
      "Kürzere Druckzeit, aber gröbere Oberfläche, mehr Vibrationen (Ringing) und schlechtere Schichthaftung.",
      "Sauberere Oberfläche und festere Verbindung, dafür dauert der Druck länger.", example, 'speed')


def accel(key, what, example=None):
    E(key, f"Wie schnell der Druckkopf bei {what} auf Tempo kommt und wieder abbremst (mm/s²).",
      "Kürzere Druckzeit, aber Wellen („Ghosting“/Ringing) hinter Ecken und mehr Vibration.",
      "Sauberere Ecken und leiserer Druck, dafür länger.", example or "Bei hohen Geschwindigkeiten zuerst die Beschleunigung für die Außenwand senken.", 'acceleration')


def jerk(key, what):
    E(key, f"Wie abrupt sich die Geschwindigkeit in Ecken bei {what} ändern darf (Ruck, „Jerk“). Bei Klipper-Druckern wird dies meist über die Junction Deviation geregelt.",
      "Schnellere Ecken, aber Vibrationen und Ringing.", "Sanftere Ecken, dafür etwas länger.", None, 'jerk')


def width(key, what, example=None):
    E(key, f"Breite der Kunststofflinie für {what}.",
      "Stabiler und schneller, aber weniger Details.", "Feiner und genauer, dafür länger und etwas schwächer.",
      example or "100–120 % des Düsendurchmessers sind üblich (0,4–0,48 mm bei einer 0,4-mm-Düse).", 'lineWidth')


# ---- Quality -----------------------------------------------------------------------------------------------------
E('initial_layer_print_height', "Höhe der allerersten Schicht. Sie bestimmt, wie fest der Kunststoff auf das Druckbett gedrückt wird.",
  "Dickere erste Schicht verzeiht ein nicht ganz perfektes Bett.", "Dünnere erste Schicht ergibt eine sehr glatte Unterseite, braucht aber ein gut eingestelltes Bett.",
  "0,2 mm bei einer 0,4-mm-Düse sind ein guter Standard.", 'layerHeight')
width('initial_layer_line_width', 'die erste Schicht', "Etwas breiter als normal (z. B. 0,5 mm) haftet besser auf dem Bett.")
width('outer_wall_line_width', 'die sichtbare Außenwand', "Schmal (0,4 mm) ergibt scharfe Details, breiter eine robustere Wand.")
width('inner_wall_line_width', 'die Innenwände', "Breitere Innenwände sparen Zeit, weil weniger Linien nötig sind.")
width('top_surface_line_width', 'die oberste Fläche', "Schmale Linien (ca. 0,4 mm) ergeben eine feinere Deckfläche.")
width('sparse_infill_line_width', 'die Füllung (Infill)', "Breit (0,45–0,5 mm) füllt schneller.")
width('internal_solid_infill_line_width', 'die innere Vollfüllung (feste Schichten unter der Deckfläche)')
width('support_line_width', 'die Stützstruktur (Support)', "Dünn halten, damit sich der Support leichter lösen lässt.")
E('scarf_angle_threshold', "Ab diesem Winkel (Außenwand-Knick) wird keine Schrägnaht mehr genutzt, weil die Naht sonst in einer Ecke läge.",
  "Schrägnähte werden auch an stärker gekrümmten Wänden genutzt.", "Schrägnähte nur an sehr glatten Wänden.", None, 'scarfSeam')
E('scarf_overhang_threshold', "Ab diesem Überhang-Anteil wird die Schrägnaht abgeschaltet, weil die Linie sonst in der Luft hängt.",
  "Schrägnaht auch an überhängenden Stellen.", "Schrägnaht nur dort, wo sicher Material darunter liegt.", None, 'scarfSeam')
speed('scarf_joint_speed', 'die Schrägnaht')
E('seam_slope_start_height', "Wie hoch (in % der Schichthöhe) die Schrägnaht beginnt. Bei 100 % beginnt sie ganz oben, bei kleineren Werten flacher.",
  "Höherer Start: Nahtstufe fällt stärker auf.", "Niedrigerer Start: weicherer Übergang, nahezu unsichtbar.", "Üblich sind 10 % der Schichthöhe.", 'scarfSeam')
E('seam_slope_entire_loop', "Zieht die Schrägnaht über die ganze Wandschleife, statt nur über ein Stück.",
  "Übergang ist extrem sanft und fast unsichtbar.", "Schrägnaht nur über die eingestellte Länge.", None, 'scarfSeam')
E('seam_slope_min_length', "Mindestlänge der Schrägnaht in Millimetern. Je länger, desto flacher läuft die Wand aus.",
  "Flacherer Übergang, weniger sichtbar.", "Kurze Naht, die stärker auffällt.", "Standard sind ca. 10 mm.", 'scarfSeam')
E('seam_slope_steps', "In wie viele Stufen die Schrägnaht unterteilt wird.",
  "Feinerer, glatterer Übergang.", "Gröber, schneller zu berechnen.", "10 Stufen sind üblich.", 'scarfSeam')
E('scarf_joint_flow_ratio', "Fluss in der Schrägnaht. Weniger Fluss verhindert eine Verdickung an der Nahtstelle.",
  "Mehr Material, kleine Beule möglich.", "Weniger Material, kleine Delle möglich.", "Bei 1,0 starten; bei Beulen auf 0,95 senken.", 'scarfSeam')
E('seam_slope_inner_walls', "Nutzt die Schrägnaht auch für die Innenwände, nicht nur für die Außenwand.",
  "Gleichmäßigere Festigkeit und glattere Innenwände.", "Schneller zu slicen, Innenwände behalten abrupte Nähte.", None, 'scarfSeam')
E('role_based_wipe_speed', "Das Abwischen (Wipe) am Ende der Wand richtet sich nach der Geschwindigkeit der jeweiligen Wand statt nach einem festen Wert.",
  "Abwischen passt automatisch zum Tempo der Wand.", "Feste Abwisch-Geschwindigkeit.", None, 'wipe')
speed('wipe_speed', 'das Abwischen (Wipe) am Ende einer Wand', extra=" Gilt, wenn das Abwischen nicht nach Wandart geregelt ist.")
E('wipe_before_external_loop', "Vor dem Druck der Außenwand fährt der Kopf zuerst auf der Innenwand an und wischt dort ab. Dadurch landen Tröpfchen und Naht innen, nicht außen.",
  "Außenwand ist an der Naht sauberer.", "Außenwand beginnt direkt, die Naht kann Spuren zeigen.", "Besonders sinnvoll mit der Reihenfolge Innen → Außen.", 'wipe')
E('slice_closing_radius', "Schließt beim Slicen sehr feine Spalte im Modell (Löcher im 3D-Netz). Gaps kleiner als dieser Radius werden zugezogen.",
  "Kleine Risse im Modell werden zugezogen – aber echte feine Spalten ebenfalls.", "Feine Spalten bleiben erhalten, fehlerhafte Netze machen mehr Probleme.", "0,049 mm ist ein sinnvoller Standard.", 'minFeature')
E('elefant_foot_compensation_layers', "Über wie viele Schichten der Elefantenfuß-Ausgleich wirkt.",
  "Weicherer Übergang an der Unterkante.", "Nur die erste Schicht wird verkleinert.", "Bei 1 Schicht ist der Ausgleich am wirksamsten, bei höheren Werten wird er sanfter verteilt.", 'elephantFoot')
E('precise_z_height', "Rechnet die Schichten so, dass die Gesamthöhe des Teils exakt dem Modell entspricht.",
  "Höhe stimmt präzise, die letzte Schicht kann dünner werden.", "Letzte Schicht hat die normale Dicke; Höhe weicht um weniger als eine Schicht ab.", None, 'layerHeight')
E('hole_to_polyhole_threshold', "Löcher bis zu diesem Durchmesser werden zu Polyholes. Größere bleiben normal rund.",
  "Auch größere Löcher werden zum Vieleck.", "Nur kleine Löcher werden angepasst.", None, 'polyhole')
E('hole_to_polyhole_twisted', "Dreht das Polyhole schichtweise leicht. So fügen sich Schraubengewinde (selbstschneidend) besser ein.",
  "Gewindeschrauben schneiden sich leichter ein.", "Gerades Vieleck, mehr Spiel für Stifte.", None, 'polyhole')
speed('ironing_speed', 'die Düse beim Bügeln (Ironing) über die Oberseite fährt', "Langsam (15–30 mm/s) glättet am besten.")
E('ironing_flow', "Wie viel Material beim Bügeln nachgelegt wird, in Prozent eines normalen Flusses. Wenige Prozent füllen nur Lücken.",
  "Mehr Material: Oberfläche geschlossener, aber Gefahr von Beulen und Fäden.", "Weniger Material: nur glätten, aber kleine Löcher bleiben.", "10–15 % sind üblich.", 'ironing')
E('ironing_spacing', "Abstand zwischen den Bügelbahnen.",
  "Weniger Bahnen, schneller, aber Streifen möglich.", "Dichtere Bahnen, sehr glatt, dafür deutlich länger.", "0,1–0,15 mm sind üblich.", 'ironing')
E('ironing_inset', "Abstand vom Rand der Fläche, bis zu dem gebügelt wird. So vermeidet man, dass die Düse über die Kante fährt.",
  "Randstreifen bleiben ungebügelt.", "Bügeln bis fast zur Kante – Gefahr, dass Material über den Rand läuft.", None, 'ironing')
E('ironing_angle', "Richtung der Bügelbahnen in Grad. Das Muster dreht sich um den Winkel.",
  "Anderer Winkel verändert die Struktur der Fläche.", "Mit 0° und dem Winkel der Deckfläche entsteht ein ruhiges Muster.", "Gegenüber den Linien der Deckfläche um 90° drehen verdeckt Linien am besten.", 'ironing')
E('wall_transition_angle', "Beim Arachne-Wandgenerator: Ab diesem Winkel wird zwischen einer Wand und einer anderen Zahl von Wänden gewechselt, wenn das Teil dünner wird.",
  "Wechsel erfolgt später, weniger Übergänge.", "Wechsel erfolgt früher.", None, 'thinWall')
E('wall_transition_filter_deviation', "Verhindert kleine, zappelige Übergänge zwischen Wandanzahlen bei Arachne.",
  "Weniger Zappeln, aber ungenauere Wände.", "Genauere Wände, mehr Übergänge.", None, 'thinWall')
E('wall_transition_length', "Wie lang der Übergang zwischen unterschiedlichen Wandanzahlen bei Arachne ist (in % der Düse).",
  "Sanftere, längere Übergänge.", "Kürzere, abruptere Übergänge.", None, 'thinWall')
E('wall_distribution_count', "Über wie viele Wände die Breitenänderung bei Arachne verteilt wird.",
  "Gleichmäßigere Wände bei dünnen Stellen.", "Weniger Wände nehmen die Anpassung auf.", None, 'thinWall')
E('initial_layer_min_bead_width', "Kleinste erlaubte Linienbreite der ersten Schicht bei Arachne (in % der Düse).",
  "Dünne Linien in der ersten Schicht werden vermieden.", "Sehr dünne Linien sind erlaubt.", None, 'thinWall')
E('min_bead_width', "Kleinste Linienbreite, die Arachne bei dünnen Wänden verwenden darf (in % der Düse).",
  "Dünne Wände werden gröber.", "Feinere Details, aber Linien können schlecht haften.", None, 'thinWall')
E('min_feature_size', "Kleinste Struktur (in % der Düse), die noch gedruckt wird. Kleinere Details werden weggelassen.",
  "Mehr kleine Details gehen verloren.", "Feine Strukturen bleiben erhalten.", None, 'minFeature')
E('min_length_factor', "Wandsegmente, die kürzer als dieser Faktor mal Düsenbreite sind, werden zusammengefasst oder entfernt.",
  "Weniger kurze Ruckler, aber Details gehen verloren.", "Mehr kurze Wandstücke.", None, 'minFeature')
E('is_infill_first', "Druckt zuerst die Füllung und danach die Wände. Meist wird es umgekehrt gemacht.",
  "Füllung zuerst: Wand kann sich schöner an die Füllung anlegen; Füllung kann an Außenwänden sichtbar werden.", "Wände zuerst: Standard, sauberere Oberfläche.", None, 'wallOrder')
E('wall_direction', "Richtung, in der die Wände gedruckt werden (Uhrzeigersinn / dagegen).",
  "Gegen den Uhrzeigersinn ist der Standard.", "Im Uhrzeigersinn kann bei bestimmten Überhängen oder Naht-Mustern besser sein.", None, 'wallOrder')
E('bottom_solid_infill_flow_ratio', "Fluss für die unterste, feste Schicht. Hilft, wenn Böden Lücken oder Beulen zeigen.",
  "Dichter Boden, aber Gefahr von Beulen.", "Weniger Material, kleine Lücken möglich.", None, 'flow')
E('min_width_top_surface', "Wenn eine obere Fläche schmaler als dieser Wert ist, wird dort nur eine Wand gedruckt.",
  "Mehr schmale Flächen werden mit einer Wand gedruckt.", "Nur sehr schmale Flächen.", None, 'wallCount')
E('only_one_wall_first_layer', "Druckt in der ersten Schicht nur eine Wand. Das spart Zeit und verbessert die Haftung der Füllung.",
  "Schneller, die Füllung haftet besser am Bett.", "Mehrere Wände auch in der ersten Schicht.", None, 'wallCount')
E('max_travel_detour_distance', "Maximale Länge des Umwegs, um Wände nicht zu überfahren. Längere Umwege werden nicht gefahren.",
  "Mehr Umwege, sauberere Oberfläche.", "Kürzere Umwege, schneller, aber mehr Spuren.", None, 'crossingWalls')
E('small_area_infill_flow_compensation', "Gleicht aus, dass bei sehr kleinen Füllflächen zu viel Material liegt. Kleine Flächen werden mit weniger Fluss gedruckt.",
  "Kleine Flächen werden sauberer.", "Standardfluss auch an kleinen Flächen (Beulen möglich).", None, 'flow')
E('internal_bridge_flow', "Fluss für innere Brücken (Füllung unter der Deckfläche).",
  "Dichter, aber Gefahr von Beulen.", "Weniger Material, Gefahr von Lücken.", "0,85–1,0 ist üblich.", 'bridge')
E('bridge_density', "Wie dicht die Linien einer äußeren Brücke gelegt werden.",
  "Geschlossene Brücke, aber stärkeres Durchhängen.", "Offene Brücke mit Spalten, dafür straffer.", None, 'bridgeDensity')
E('internal_bridge_density', "Dichte der inneren Brückenlinien (unter der Deckfläche).",
  "Dichte Unterlage für die Deckfläche – weniger „Pillowing“.", "Lockere Brücke, schneller.", None, 'bridgeDensity')
E('thick_internal_bridges', "Druckt innere Brücken mit dicken Linien (wie ein Düsendurchmesser). Dicke Linien tragen sich besser.",
  "Stabilere innere Brücken.", "Dünne Linien, aber Gefahr von Durchhängen.", None, 'bridge')
E('enable_extra_bridge_layer', "Legt zusätzliche Brückenschichten ein, um die Fläche unter einer Deckfläche besser zu stützen.",
  "Weniger Einsinken der Deckfläche, aber länger.", "Standard-Brücke.", None, 'topShell')
E('dont_filter_internal_bridges', "Legt fest, ob kleine innere Brücken ausgefiltert werden. Gefilterte Brücken werden durch Vollfüllung ersetzt.",
  "Alle Brücken werden gedruckt (Pillowing möglich).", "Kleine Brücken werden gefiltert – glatter.", None, 'bridge')
E('counterbore_hole_bridging', "Brücken über Senkungen: Wie ein Loch mit Absatz (Senkung) überbrückt wird, damit es nicht ohne Stütze hängt.",
  "Senkungen lassen sich ohne Support drucken.", "Ohne Brücke ist Support nötig.", None, 'bridge')
E('make_overhang_printable_angle', "Maximaler Winkel, auf den Überhänge flacher gemacht werden, damit sie ohne Stützen gehen.",
  "Mehr Modell-Änderungen, weniger Stützen.", "Modell bleibt näher am Original.", None, 'overhang')
E('make_overhang_printable_hole_size', "Maximale Fläche von Löchern, die als druckbarer Überhang angepasst werden.",
  "Auch größere Löcher werden verändert.", "Nur kleine Löcher.", None, 'overhang')
E('overhang_reverse', "Dreht die Druckrichtung auf geraden Schichten um. So wird der Überhang auf der „Schlaufe“ besser gestützt.",
  "Saubere Überhänge ohne Stützen.", "Standardrichtung.", None, 'overhang')
E('overhang_reverse_internal_only', "Dreht die Richtung nur für innere Wände um, nicht für die Außenwand.",
  "Außenwand bleibt unverändert.", "Auch die Außenwand wird umgedreht.", None, 'overhang')
E('overhang_reverse_threshold', "Ab welchem Überhang-Anteil die Richtung umgedreht wird.",
  "Nur bei starken Überhängen.", "Schon bei leichten Überhängen.", None, 'overhang')
# ---- Strength ----------------------------------------------------------------------------------------------------
E('alternate_extra_wall', "Fügt jede zweite Schicht eine zusätzliche Wand ein. So verzahnen sich die Wände und die Füllung besser.",
  "Fester und besser verbunden, aber mehr Material.", "Gleichmäßige Wandanzahl.", None, 'wallCount')
E('top_shell_layers', "Wie viele feste Schichten die Oberseite des Teils hat. Sie decken die Füllung ab.",
  "Dichtere Oberseite, besonders bei dünner Schichthöhe nötig.", "Füllungslinien können durchscheinen oder Lücken zeigen.", "Bei 0,2 mm Schichten: 4–5 Schichten.", 'topShell')
E('top_surface_pattern', "Muster der obersten, sichtbaren Fläche.",
  "„Konzentrisch“ sieht rund aus, „Linien“ sieht gleichmäßig und gestreift aus.", None, "Monotone Linien ergeben die gleichmäßigste Oberfläche.", 'surfacePattern')
E('bottom_shell_layers', "Wie viele feste Schichten die Unterseite des Teils hat.",
  "Fester Boden, weniger Löcher unten.", "Weniger Material, Füllung kann unten durchscheinen.", "3–4 Schichten reichen meist.", 'topShell')
E('bottom_shell_thickness', "Mindestdicke des Bodens in Millimetern. Hat Vorrang vor der Schichtzahl, wenn sie mehr Schichten ergibt.",
  "Dichterer Boden.", "Nur die eingestellte Schichtzahl.", None, 'topShell')
E('bottom_surface_pattern', "Muster der untersten Fläche (auf dem Druckbett).",
  "„Konzentrisch“ folgt der Kontur, „Linien“ ist gleichmäßig.", None, None, 'surfacePattern')
E('top_bottom_infill_wall_overlap', "Wie weit die Vollfüllung der Deck- und Bodenschichten in die Wand hineinragt.",
  "Besserer Halt der Deckschichten an der Wand, aber Gefahr von Beulen an der Außenwand.", "Weniger Überlappung, sauberere Wand, aber evtl. kleine Lücken.", None, 'topShell')
E('sparse_infill_pattern', "Muster der Füllung im Inneren des Teils. Es bestimmt Festigkeit, Gewicht und Druckzeit.",
  "Komplexe Muster (Gyroid, Kubisch) sind in alle Richtungen stabil, aber langsamer.", "Einfache Muster (Linien, Gitter) sind schnell, aber nur in einer Richtung stabil.",
  "Gyroid für Funktionsteile, Gitter für schnelle Drucke, Kubisch für gute Festigkeit pro Gramm.", 'infillPattern')
E('infill_anchor_max', "Maximale Länge des Stücks, mit dem sich die Füllung an die Wand anschließt (Anker). Längere Anker verbinden besser.",
  "Fester Verbund Füllung/Wand.", "Weniger Anker, weniger Material.", None, 'infillDensity')
E('internal_solid_infill_pattern', "Muster der inneren Vollfüllung (feste Schichten im Teil, z. B. unter Deckflächen).",
  "„Konzentrisch“ spart Zeit bei schmalen Flächen, „Gerade“ ist Standard.", None, None, 'surfacePattern')
E('gap_fill_target', "Wo schmale Lücken zwischen Wänden mit Kunststoff gefüllt werden: überall, nur oben oder nirgends.",
  "Mehr Lückenfüllung, dichtere Wände.", "Weniger Lückenfüllung, schneller.", None, 'gapFill')
E('filter_out_gap_fill', "Winzige Lücken, die kürzer als dieser Wert sind, werden nicht mit einer eigenen Linie gefüllt.",
  "Weniger kurze Ruckler.", "Mehr Lückenfüllung, auch winzige.", None, 'gapFill')
E('infill_wall_overlap', "Wie weit die Füllung in die Innenwand hineinragt (in % der Linienbreite).",
  "Fester Verbund Füllung/Wand, aber Gefahr von Beulen an der Außenwand.", "Weniger Überlappung, sauberere Wand, evtl. Lücken.", "Üblich sind 15–25 %.", 'infillDensity')
E('infill_direction', "Drehwinkel des Füllmusters in Grad.",
  "Anderer Winkel ändert, in welcher Richtung das Teil am stabilsten ist.", None, "Winkel so wählen, dass die Linien quer zur Belastung liegen.", 'infillPattern')
E('solid_infill_direction', "Drehwinkel der Linien in den festen Schichten (unter Deckflächen).",
  "Anderer Winkel ändert, welche Richtung Muster hat.", None, None, 'surfacePattern')
E('bridge_angle', "Richtung der Brückenlinien. Bei 0 sucht der Slicer die beste Richtung selbst.",
  "Fester Wert: Brücke in einer festen Richtung.", "0 = automatisch (empfohlen).", None, 'bridge')
E('infill_combination', "Druckt die Füllung nur jede zweite (oder dritte) Schicht, dafür aber doppelt so dick. Spart Zeit.",
  "Schneller, weniger Füllungsschichten.", "Normale Füllung in jeder Schicht.", None, 'infillDensity')
E('infill_combination_max_layer_height', "Maximale Dicke der kombinierten Füllschicht (in % der Düse).",
  "Dickere Füllschichten, schneller, aber gröber.", "Dünnere Füllschichten.", None, 'infillDensity')
# ---- Speed -------------------------------------------------------------------------------------------------------
speed('initial_layer_speed', 'die erste Schicht', "20–50 mm/s für sichere Haftung.")
speed('initial_layer_infill_speed', 'die Vollfüllung der ersten Schicht')
E('initial_layer_travel_speed', "Fahrgeschwindigkeit ohne Extrusion in der ersten Schicht.",
  "Schnellere Leerfahrten.", "Langsamer: schont das Bett.", None, 'speed')
E('slow_down_layers', "Anzahl der ersten Schichten, in denen der Druck langsam beginnt und schrittweise auf die normale Geschwindigkeit kommt.",
  "Längere Anlaufphase, sicherer.", "Schneller Start.", None, 'speed')
speed('outer_wall_speed', 'die sichtbare Außenwand', "Langsam (60–150 mm/s) für beste Oberfläche.")
speed('inner_wall_speed', 'die Innenwände', "Darf schneller sein als die Außenwand, da sie nicht sichtbar sind.")
speed('small_perimeter_speed', 'sehr kleine Wände und Details', "Langsam, damit die Düse Details sauber ablegen kann.")
E('small_perimeter_threshold', "Wandlängen unterhalb dieser Grenze zählen als „klein“ und bekommen das Tempo für kleine Strukturen.",
  "Mehr Wände werden langsam gedruckt.", "Nur sehr kleine Wände.", None, 'speed')
speed('sparse_infill_speed', 'die Füllung (Infill)', "Kann sehr schnell sein, da nichts sichtbar ist.")
speed('internal_solid_infill_speed', 'die innere Vollfüllung')
speed('top_surface_speed', 'die oberste Fläche', "Langsamer drucken verbessert die Oberfläche.")
speed('gap_infill_speed', 'die Lückenfüllung', "Langsam, da die Linien schmal sind und sonst reißen.")
speed('support_speed', 'die Stützstruktur (Support)')
speed('support_interface_speed', 'die Kontaktschicht des Supports', "Langsam für glatte Fläche an der Stütze.")
E('enable_overhang_speed', "Verlangsamt den Druck an Überhängen automatisch, je stärker sie überhängen.",
  "Überhänge werden sauberer, Druck dauert etwas länger.", "Gleiches Tempo überall – Überhänge können kräuseln.", None, 'overhang')
E('slowdown_for_curled_perimeters', "Verlangsamt den Druck, wenn sich die Wand an Überhängen aufrollt (Curling) und die Düse dagegen stoßen könnte.",
  "Weniger Kollisionen und Fehldrucke.", "Schneller, aber Aufrollen kann zu Fehlern führen.", None, 'overhang')
speed('travel_speed', 'Leerfahrten (ohne Extrusion)', "300–500 mm/s sind bei CoreXY-Druckern üblich.")
accel('default_acceleration', 'normalem Drucken')
accel('outer_wall_acceleration', 'der Außenwand', "Niedrig halten (z. B. 5000 mm/s²), das verbessert die Oberfläche.")
accel('inner_wall_acceleration', 'Innenwänden')
accel('bridge_acceleration', 'Brücken')
accel('sparse_infill_acceleration', 'der Füllung')
accel('internal_solid_infill_acceleration', 'der inneren Vollfüllung')
accel('initial_layer_acceleration', 'der ersten Schicht')
accel('top_surface_acceleration', 'der obersten Fläche')
accel('travel_acceleration', 'Leerfahrten', "Hoch einstellbar, weil nicht gedruckt wird.")
E('accel_to_decel_enable', "Begrenzt, wie stark das Abbremsen im Vergleich zum Beschleunigen sein darf (Klipper: Accel-to-Decel).",
  "Sanfteres Abbremsen, weniger Vibration.", "Volles Abbremsen, schneller.", None, 'acceleration')
E('accel_to_decel_factor', "Faktor für das Abbremsen im Verhältnis zur Beschleunigung (in %).",
  "Härteres Abbremsen.", "Sanfteres Abbremsen.", None, 'acceleration')
jerk('default_jerk', 'normalem Drucken')
jerk('outer_wall_jerk', 'der Außenwand')
jerk('inner_wall_jerk', 'Innenwänden')
jerk('infill_jerk', 'der Füllung')
jerk('top_surface_jerk', 'der obersten Fläche')
jerk('initial_layer_jerk', 'der ersten Schicht')
jerk('travel_jerk', 'Leerfahrten')
E('max_volumetric_extrusion_rate_slope', "Glättet Sprünge in der Extrusionsmenge (mm³/s²), etwa beim Übergang von langsam zu schnell. Das mildert Druckspitzen in der Düse.",
  "Sanftere Übergänge, gleichmäßigere Linien, aber etwas länger.", "Harte Übergänge, dafür schneller.", None, 'speed')
E('max_volumetric_extrusion_rate_slope_segment_length', "Länge der Teilstücke, in denen die Glättung der Extrusionsrate berechnet wird.",
  "Gröbere Glättung, weniger G-Code.", "Feinere Glättung, mehr G-Code.", None, 'speed')
E('extrusion_rate_smoothing_external_perimeter_only', "Wendet die Glättung der Extrusionsrate nur auf Außenwände an.",
  "Nur die sichtbare Wand wird geglättet, schneller.", "Alle Bahnen werden geglättet.", None, 'speed')
# ---- Support -----------------------------------------------------------------------------------------------------
E('enable_support', "Erzeugt Stützstruktur (Support) unter Überhängen, damit sie nicht in der Luft gedruckt werden müssen.",
  "Überhänge gelingen, aber Spuren am Teil und mehr Material.", "Kein Support, schneller – Überhänge können durchhängen.", None, 'supportType')
E('support_type', "Art des Supports: „Normal“ (Säulen/Wände) oder „Baum“ (verästelte Stützen, weniger Material).",
  "Baum-Support spart Material und löst sich leichter.", "Normaler Support ist stabiler an großen flachen Überhängen.", None, 'supportType')
E('support_style', "Stil des Supports, z. B. Raster, schlank oder organisch.",
  "Organisch/schlank spart Material.", "Raster ist stabil bei ebenen Flächen.", None, 'supportType')
E('support_threshold_angle', "Überhänge, die flacher als dieser Winkel sind, bekommen Support. Je kleiner der Wert, desto mehr Support.",
  "Mehr Support, sicherer.", "Weniger Support – nur steile Überhänge werden gestützt.", "30–45° sind üblich; 0° = Slicer entscheidet selbst.", 'supportType')
E('support_threshold_overlap', "Mindest-Überlappung der Überhang-Fläche mit Material darunter, bevor Support entfällt.",
  "Mehr Support.", "Weniger Support.", None, 'supportType')
E('raft_first_layer_density', "Dichte der ersten Raft-Schicht in Prozent.",
  "Dichtere Haftschicht, besser am Bett.", "Lockerer, leichter abzulösen.", None, 'raft')
E('raft_first_layer_expansion', "Wie weit die erste Raft-Schicht über das Modell hinausragt.",
  "Breiteres Raft, mehr Halt gegen Verzug.", "Schmaleres Raft, spart Material.", None, 'raft')
E('support_on_build_plate_only', "Support nur dort, wo er auf dem Druckbett startet – nicht auf dem Teil selbst.",
  "Keine Spuren auf dem Teil, aber Überhänge über dem Teil bleiben ungestützt.", "Support auch auf dem Modell.", None, 'supportType')
E('support_critical_regions_only', "Stützt nur kritische Bereiche wie Spitzen und Kanten, nicht ganze flache Überhänge.",
  "Weniger Material, weniger Spuren.", "Flächiger Support für alle Überhänge.", None, 'supportType')
E('support_remove_small_overhang', "Entfernt Support unter sehr kleinen Überhängen, die sich auch ohne Stütze drucken lassen.",
  "Weniger unnötiger Support.", "Auch kleine Überhänge werden gestützt.", None, 'supportType')
E('enforce_support_layers', "Erzwingt Support für die angegebene Zahl der untersten Schichten, selbst wenn der Slicer keinen für nötig hält.",
  "Sichere Basis bei schwierigen Teilen.", "Support nur nach Berechnung.", None, 'supportType')
E('raft_layers', "Anzahl der Raft-Schichten – eine Plattform aus mehreren Schichten zwischen Druckbett und Teil.",
  "Besser bei schlechter Bett-Haftung, aber Material, Zeit und raue Unterseite.", "Kein Raft: Teil liegt direkt auf dem Bett.", None, 'raft')
E('raft_contact_distance', "Luftspalt zwischen Raft und Teil.",
  "Raft löst sich leichter, Unterseite wird rauer.", "Besserer Halt, aber schwerer zu lösen.", None, 'raft')
E('support_filament', "Welches Filament den Support druckt (bei Mehrfarbdruck). „Standard“ nutzt das aktuell aktive.",
  "Eigenes Filament spart Spülmaterial.", None, None, 'filamentAssign')
E('support_interface_filament', "Welches Filament die Kontaktschicht des Supports druckt (z. B. ein lösliches Material).",
  "Sauberere Fläche am Teil.", None, None, 'filamentAssign')
E('support_interface_not_for_body', "Nutzt das Kontaktschicht-Filament nicht für den Support-Körper.",
  "Spart teures Spezialmaterial.", "Kontaktschicht-Material auch für den Körper.", None, 'filamentAssign')
E('support_bottom_z_distance', "Luftspalt zwischen Support-Unterseite und Teil (dort, wo Support auf dem Modell steht).",
  "Support löst sich leichter.", "Besserer Halt, aber schwer zu lösen.", None, 'supportGap')
E('tree_support_wall_count', "Anzahl der Wände um jeden Baum-Ast. Mehr Wände machen ihn stabiler.",
  "Stabilere Äste, mehr Material.", "Schlanke Äste, schneller zu drucken.", None, 'supportType')
E('support_base_pattern', "Muster des Support-Körpers (Gerade, Gitter, Wabe …).",
  "Stabilere Muster brauchen mehr Material.", "Einfache Linien sind schnell und leicht zu lösen.", None, 'infillPattern')
E('support_base_pattern_spacing', "Abstand der Linien im Support-Körper.",
  "Lockerer Support: weniger Material, leicht zu lösen.", "Dichter Support: stabiler, schwerer zu lösen.", "2,5 mm sind ein guter Start.", 'supportType')
E('support_angle', "Drehwinkel des Support-Musters in Grad.",
  "Anderer Winkel ändert die Stabilität in verschiedene Richtungen.", None, None, 'supportType')
E('support_interface_top_layers', "Anzahl der dichten Schichten zwischen Support und Teil oben.",
  "Glattere Fläche am Teil.", "Weniger Schichten, schneller und leichter zu lösen.", "2–3 Schichten sind üblich.", 'supportInterface')
E('support_interface_bottom_layers', "Anzahl der dichten Schichten zwischen Support und Teil unten (wenn Support auf dem Teil steht).",
  "Glattere Unterseite.", "Weniger Schichten.", None, 'supportInterface')
E('support_interface_pattern', "Muster der Kontaktschicht des Supports.",
  "Dichte Muster ergeben eine glattere Fläche am Teil.", None, None, 'supportInterface')
E('support_interface_spacing', "Linienabstand der oberen Kontaktschicht des Supports.",
  "Lockerer: leichter zu lösen, raue Fläche.", "Dichter: glatte Fläche, schwerer zu lösen.", "0 ergibt eine geschlossene Fläche.", 'supportInterface')
E('support_bottom_interface_spacing', "Linienabstand der unteren Kontaktschicht des Supports.",
  "Lockerer: leichter zu lösen.", "Dichter: glatter.", None, 'supportInterface')
E('support_expansion', "Verbreitert den Support seitlich über den Überhang hinaus.",
  "Mehr Halt an den Rändern, mehr Material.", "Support endet genau am Überhang.", None, 'supportType')
E('support_interface_loop_pattern', "Legt die Kontaktschicht als Schleifen entlang der Kontur.",
  "Saubere Kante am Überhang.", "Linienmuster innen.", None, 'supportInterface')
E('support_object_first_layer_gap', "Abstand zwischen Support und Teil in der ersten Schicht.",
  "Support löst sich leichter vom Druckbett-nahen Teil.", "Besserer Halt.", None, 'supportGap')
E('bridge_no_support', "Keine Stützen unter Brücken – der Slicer geht davon aus, dass sie frei gebrückt werden können.",
  "Weniger Support unter Brücken.", "Brücken bekommen immer Support.", None, 'bridge')
E('max_bridge_length', "Brücken bis zu dieser Länge werden ohne Support gedruckt.",
  "Längere Brücken ohne Support (Durchhängen möglich).", "Auch kurze Brücken bekommen Support.", None, 'bridge')
E('tree_support_tip_diameter', "Durchmesser der Baum-Äste an der Spitze, dort wo sie das Teil berühren.",
  "Stärkerer Halt, aber größere Spuren.", "Dünne Spitzen: kleine Spuren, aber fragile Stützen.", None, 'supportType')
E('tree_support_branch_distance', "Abstand zwischen den Ast-Spitzen (normaler Baum-Support).",
  "Weniger Stützpunkte, spart Material.", "Mehr Stützpunkte, sicherer.", None, 'supportType')
E('tree_support_branch_distance_organic', "Abstand zwischen den Ast-Spitzen (organischer Baum-Support).",
  "Weniger Stützpunkte.", "Mehr Stützpunkte.", None, 'supportType')
E('tree_support_top_rate', "Dichte der Äste an der Spitze in Prozent.",
  "Dichter gestützte Fläche, mehr Material.", "Lockerer.", None, 'supportType')
E('tree_support_branch_diameter', "Dicke der Äste im Stamm.",
  "Stabilere Äste.", "Schlankere, materialsparende Äste.", None, 'supportType')
E('tree_support_branch_diameter_organic', "Dicke der Äste im Stamm (organisch).",
  "Stabilere Äste.", "Schlankere Äste.", None, 'supportType')
E('tree_support_branch_diameter_angle', "Winkel, mit dem sich die Äste nach unten verdicken.",
  "Schnell dickerer Stamm.", "Gleichmäßig schlank.", None, 'supportType')
E('tree_support_branch_angle', "Maximaler Neigungswinkel der Äste.",
  "Flachere Äste können weitere Wege überbrücken.", "Steilere Äste stehen stabiler.", None, 'supportType')
E('tree_support_branch_angle_organic', "Maximaler Neigungswinkel der Äste (organisch).",
  "Flachere Äste können weiter ausladen.", "Steile, senkrechte Äste.", None, 'supportType')
E('tree_support_angle_slow', "Bevorzugter Astwinkel, bei dem das Wachstum verlangsamt wird.",
  "Äste neigen stärker.", "Äste bleiben steiler.", None, 'supportType')
E('tree_support_adaptive_layer_height', "Baum-Support nutzt dickere Schichten, wo möglich. Das beschleunigt den Druck.",
  "Schnellerer Support.", "Gleichbleibende Schichtdicke.", None, 'layerHeight')
E('tree_support_auto_brim', "Berechnet die Breite des Randes (Brim) am Baum-Support automatisch.",
  "Gute Haftung der Äste ohne manuelles Einstellen.", "Eigene Randbreite wählbar.", None, 'brim')
E('tree_support_brim_width', "Breite des Randes (Brim) unter dem Baum-Support für bessere Haftung am Bett.",
  "Fester Stand der Äste.", "Weniger Rand, schneller zu lösen.", None, 'brim')
# ---- Multi material ----------------------------------------------------------------------------------------------
E('prime_tower_width', "Breite des Reinigungsturms (Prime Tower), auf dem die Düse bei Farbwechsel ausgespült wird.",
  "Mehr Platz zum Spülen, stabilerer Turm.", "Schmaler: spart Material, aber Spülen schlechter.", None, 'primeTower')
E('prime_volume', "Wie viel Material beim Farbwechsel am Turm gespült wird.",
  "Reinere Farben, mehr Abfall.", "Weniger Abfall, Mischfarben möglich.", None, 'flush')
E('prime_tower_brim_width', "Breite des Randes (Brim) am Reinigungsturm für besseren Halt.",
  "Turm steht fester.", "Weniger Material.", None, 'brim')
E('wipe_tower_rotation_angle', "Dreht den Reinigungsturm um diesen Winkel.", None, None, None, 'primeTower')
E('wipe_tower_bridging', "Maximale Brückenlänge, die der Reinigungsturm ohne Stütze überbrückt.",
  "Weniger Stützen im Turm.", "Mehr Stützen.", None, 'bridge')
E('wipe_tower_cone_angle', "Kegelwinkel unter dem Turm; ein Kegel stabilisiert hohe Türme.",
  "Standfester Turm.", "Weniger Material.", None, 'primeTower')
E('wipe_tower_extra_spacing', "Zusätzlicher Abstand zwischen den Spülbahnen am Turm (in %).",
  "Mehr Platz, saubereres Ergebnis.", "Enger, spart Zeit.", None, 'primeTower')
E('wipe_tower_extra_flow', "Zusätzlicher Fluss beim Spülen am Turm (in %).",
  "Dichterer Turm, stabiler.", "Weniger Material.", None, 'primeTower')
E('wipe_tower_max_purge_speed', "Maximale Geschwindigkeit beim Spülen am Turm.",
  "Schneller, aber Gefahr von schlechtem Spülen.", "Langsamer, sauberer.", None, 'speed')
E('wipe_tower_no_sparse_layers', "Lässt Schichten am Turm weg, in denen nicht gewechselt wird.",
  "Schlankerer, schneller Turm.", "Turm in jeder Schicht (stabiler).", None, 'primeTower')
E('single_extruder_multi_material_priming', "Spült beim Start alle benutzten Filamente am Turm durch.",
  "Alle Farben sind sofort sauber.", "Spart Material, erste Farbwechsel können unsauber sein.", None, 'flush')
E('wall_filament', "Welches Filament die Wände druckt (bei Mehrfarbdruck).", "Eigenes Material nur für die Wand.", None, None, 'filamentAssign')
E('sparse_infill_filament', "Welches Filament die Füllung druckt.", "Günstiges Material für die Füllung.", None, None, 'filamentAssign')
E('solid_infill_filament', "Welches Filament die feste Füllung (Deck- und Bodenschichten) druckt.", "Eigenes Material für Flächen.", None, None, 'filamentAssign')
E('wipe_tower_filament', "Welches Filament den Reinigungsturm druckt.", "Ein günstiges Material für den Turm spart Kosten.", None, None, 'filamentAssign')
E('ooze_prevention', "Senkt die Temperatur der Düsen, die gerade nicht drucken, damit sie nicht nachsickern.",
  "Weniger Fäden und Kleckse bei Mehrfarbdruck.", "Düsen bleiben heiß (kürzere Wechselzeit, aber Sicker-Gefahr).", None, 'preheat')
E('standby_temperature_delta', "Um wie viel Grad die inaktive Düse abgesenkt wird.",
  "Stärker abgesenkt: weniger Sickern, aber längeres Aufheizen.", "Kleiner Abstand: schnellerer Wechsel.", "−5 bis −30 °C sind üblich.", 'preheat')
E('preheat_time', "Wie viele Sekunden vor dem Werkzeugwechsel die nächste Düse vorheizt.",
  "Weniger Wartezeit nach dem Wechsel.", "Kein Vorheizen: Wechsel dauert länger.", None, 'preheat')
E('preheat_steps', "Anzahl der Vorheiz-Befehle (nur für Prusa XL relevant).", None, None, "Für andere Drucker auf 1 lassen.", 'gcodeText')
E('flush_into_infill', "Spült beim Farbwechsel in die Füllung des Objekts, statt in den Reinigungsturm.",
  "Weniger Abfall.", "Alles geht in den Turm.", None, 'flush')
E('flush_into_objects', "Spült in anderen Objekten der Platte statt im Turm.",
  "Weniger Abfall, Farbe kann durchscheinen.", "Spülen nur im Turm.", None, 'flush')
E('flush_into_support', "Spült in den Support.", "Weniger Abfall.", "Spülen nur im Turm.", None, 'flush')
E('interlocking_beam', "Verzahnt Bereiche verschiedener Materialien mit Balken, damit sie sich mechanisch halten.",
  "Starke Verbindung zwischen Farben/Materialien.", "Glatte Grenze, Verbindung nur durch Haftung.", None, 'interlocking')
E('interface_shells', "Erzeugt Wände zwischen verschiedenen Materialien, damit sie sauber getrennt bleiben.",
  "Saubere Trennung, aber mehr Material.", "Materialien grenzen direkt aneinander.", None, 'interlocking')
E('mmu_segmented_region_max_width', "Maximale Breite eines farbigen Bereichs.", "Breitere Bereiche erlaubt.", "Schmalere Bereiche.", None, 'interlocking')
E('mmu_segmented_region_interlocking_depth', "Tiefe der Verzahnung in farbigen Bereichen.", "Tiefere Verzahnung, fester.", "Flachere Verzahnung.", None, 'interlocking')
E('interlocking_beam_width', "Breite der verzahnenden Balken.", "Breitere Balken, stabiler.", "Schmalere Balken.", None, 'interlocking')
E('interlocking_orientation', "Winkel, in dem die Balken liegen.", None, None, None, 'interlocking')
E('interlocking_beam_layer_count', "Wie viele Schichten hoch ein Balken ist.", "Höhere Balken, stabilere Verbindung.", "Niedrigere Balken.", None, 'interlocking')
E('interlocking_depth', "Wie tief die Balken in das andere Material ragen.", "Tiefere Verzahnung.", "Flachere.", None, 'interlocking')
E('interlocking_boundary_avoidance', "Abstand zur Außenkante, in dem keine Verzahnung erzeugt wird.", "Sauberere Außenkante.", "Verzahnung bis an den Rand.", None, 'interlocking')
# ---- Others ------------------------------------------------------------------------------------------------------
E('skirt_loops', "Anzahl der Linien, die vor dem Druck als Schürze (Skirt) um das Teil gelegt werden. Sie spülen die Düse an, berühren das Teil aber nicht.",
  "Düse ist bei Druckbeginn sicher gefüllt.", "Keine Schürze: Düse kann am Start leer sein.", None, 'skirt')
E('skirt_type', "Art der Schürze: um alle Objekte gemeinsam oder um jedes einzeln.",
  None, None, None, 'skirt')
E('min_skirt_length', "Mindestlänge des Filaments, die für die Schürze gedruckt wird.",
  "Düse ist länger vorgespült.", "Kurze Schürze.", None, 'skirt')
E('skirt_distance', "Abstand zwischen Schürze und Teil.",
  "Mehr Platz, Schürze berührt nicht.", "Nah am Teil, spart Platz.", "3–6 mm sind üblich.", 'skirt')
E('skirt_start_angle', "Winkel, an dem die Schürze beginnt (Position des Anfangspunkts).", None, None, None, 'skirt')
E('skirt_height', "Anzahl der Schichten, über die die Schürze hochgezogen wird.",
  "Höherer Windschutz-Effekt.", "Nur in den untersten Schichten.", None, 'skirt')
speed('skirt_speed', 'die Schürze')
E('brim_width', "Breite des Haftrands (Brim) in Millimetern.",
  "Mehr Haftfläche, weniger Verzug, aber mehr Nacharbeit.", "Schmaler: leichter zu entfernen.", "5–8 mm für Teile, die zum Abheben neigen.", 'brim')
E('brim_ears_max_angle', "Brim-Ohren erscheinen nur an Ecken, die schärfer sind als dieser Winkel.",
  "Ohren auch an sanften Ecken.", "Nur an spitzen Ecken.", None, 'brim')
E('brim_ears_detection_length', "Länge, über die Ecken für Brim-Ohren erkannt werden.",
  "Mehr Ecken werden erkannt.", "Nur klare Ecken.", None, 'brim')
E('slicing_mode', "Wie das Modell in Schichten zerlegt wird: normal, mit Lochausgleich oder geschlossen.",
  "„Geschlossen“ stopft Löcher im Netz.", "„Normal“ ist Standard.", None, 'minFeature')
E('print_sequence', "Reihenfolge, in der mehrere Objekte gedruckt werden: alle Objekte Schicht für Schicht, oder ein Objekt nach dem anderen.",
  "Objekt für Objekt ist sicher bei Fehldrucken, erfordert aber niedrige Objekte (Druckkopf-Kollision).", "Schicht für Schicht ist der Standard.", None, 'printSequence')
E('print_order', "Reihenfolge von Wänden, Füllung und Support innerhalb einer Schicht.", None, None, None, 'wallOrder')
E('spiral_mode_smooth', "Glättet die Spirale im Vasenmodus, damit keine Stufen entstehen.",
  "Glattere Vase.", "Mit Stufen.", None, 'spiralVase')
E('spiral_mode_max_xy_smoothing', "Wie weit die Kontur im Vasenmodus geglättet werden darf (XY).",
  "Glattere Spirale, Details gehen verloren.", "Genaue Kontur.", None, 'spiralVase')
E('spiral_starting_flow_ratio', "Fluss am Anfang der Spirale im Vasenmodus.",
  "Dickerer Start.", "Dünnerer Start.", None, 'spiralVase')
E('spiral_finishing_flow_ratio', "Fluss am Ende der Spirale, damit die Vase sauber ausläuft.",
  "Dickerer Abschluss.", "Dünnerer Abschluss.", None, 'spiralVase')
E('timelapse_type', "Art der Zeitrafferaufnahme: „Traditionell“ parkt den Kopf zu jeder Aufnahme, „Fließend“ bewegt sich weniger.",
  "Fließend: weniger Verzögerung und Spuren, Kopf bleibt im Bild.", "Traditionell: saubere Bilder, aber Druckspuren durch das Parken.", None, 'gcodeText')
E('fuzzy_skin_noise_type', "Art des Zufallsmusters für Fuzzy Skin (z. B. Perlin, Simplex).", "Anderes Muster, andere Optik.", None, None, 'fuzzySkin')
E('fuzzy_skin_point_distance', "Abstand zwischen den „Zitterpunkten“ der Fuzzy Skin.",
  "Gröbere Textur.", "Feinere Textur.", None, 'fuzzySkin')
E('fuzzy_skin_scale', "Größe der Struktur der Fuzzy Skin.", "Gröbere, wellige Textur.", "Feine Textur.", None, 'fuzzySkin')
E('fuzzy_skin_octaves', "Wie viele Rauschschichten übereinander gelegt werden.", "Komplexere Textur.", "Einfachere Textur.", None, 'fuzzySkin')
E('fuzzy_skin_persistence', "Wie stark höhere Rauschschichten wirken.", "Unruhigere Textur.", "Ruhigere Textur.", None, 'fuzzySkin')
E('fuzzy_skin_first_layer', "Wendet Fuzzy Skin auch auf die erste Schicht an.",
  "Raue Optik auch unten (Haftung kann leiden).", "Erste Schicht bleibt glatt – bessere Haftung.", None, 'fuzzySkin')
E('gcode_add_line_number', "Nummeriert jede G-Code-Zeile durch. Hilfreich für Fehlersuche, macht die Datei größer.",
  "Leichtere Fehlersuche.", "Kleinere Datei.", None, 'gcodeText')
E('gcode_comments', "Schreibt Kommentare in den G-Code (z. B. „Außenwand“).",
  "Leichter lesbar, größere Datei.", "Kompakter.", None, 'gcodeText')
E('gcode_label_objects', "Markiert im G-Code, welches Objekt gerade gedruckt wird – nötig, um einzelne Objekte abzubrechen.",
  "„Objekt abbrechen“ möglich.", "Keine Markierung.", None, 'gcodeText')
E('exclude_object', "Fügt Befehle ein, mit denen der Drucker einzelne Objekte ausschließen kann (Klipper).",
  "Fehlerhafte Objekte können beim Druck übersprungen werden.", "Keine Funktion zum Überspringen.", None, 'gcodeText')
E('fill_multiline', "Druckt das Füllmuster mehrfach nebeneinander (mehrere Linien).",
  "Fester, aber länger.", "Eine Linie, schnell.", None, 'infillPattern')
E('sparse_infill_rotate_template', "Vorlage für das Drehen der Füllung pro Schicht (Winkelfolge).", None, None, None, 'infillPattern')
E('skin_infill_density', "Dichte der Füllung in der äußeren „Haut“ des Teils.", "Festere Haut.", "Leichtere Haut.", None, 'infillDensity')
E('skeleton_infill_density', "Dichte der Füllung im inneren „Skelett“ des Teils.", "Festerer Kern.", "Leichterer Kern.", None, 'infillDensity')
E('infill_lock_depth', "Tiefe, in der die Haut der Füllung in das Skelett greift.", "Besserer Halt.", "Weniger Material.", None, 'infillDensity')
E('skin_infill_depth', "Dicke der dichten Haut außen.", "Dickere Haut.", "Dünnere Haut.", None, 'infillDensity')
E('skin_infill_line_width', "Linienbreite der Haut-Füllung.", "Stabiler.", "Feiner.", None, 'lineWidth')
E('skeleton_infill_line_width', "Linienbreite der Kern-Füllung.", "Stabiler.", "Feiner.", None, 'lineWidth')
E('symmetric_infill_y_axis', "Macht die Füllung spiegelsymmetrisch zur Y-Achse.", "Gleichmäßiger bei symmetrischen Teilen.", None, None, 'infillPattern')
E('infill_shift_step', "Wie weit sich das Füllmuster pro Schicht verschiebt.", "Mehr Versatz.", "Weniger Versatz.", None, 'infillPattern')
E('lateral_lattice_angle_1', "Erster Winkel des Gitter-Füllmusters.", None, None, None, 'infillPattern')
E('lateral_lattice_angle_2', "Zweiter Winkel des Gitter-Füllmusters.", None, None, None, 'infillPattern')
E('infill_overhang_angle', "Winkel, bis zu dem die Füllung Überhänge stützt.", "Mehr stützende Füllung.", "Weniger.", None, 'overhang')
E('solid_infill_rotate_template', "Vorlage für das Drehen der Vollfüllung pro Schicht.", None, None, None, 'surfacePattern')
E('align_infill_direction_to_model', "Richtet die Füllung an der Ausrichtung des Modells aus.", "Füllung folgt der Modellrichtung.", "Füllung folgt der Platte.", None, 'infillPattern')
E('extra_solid_infills', "Fügt in angegebenen Schichten zusätzliche Vollfüllung ein.", "Festigkeit in bestimmten Höhen.", None, None, 'topShell')
E('default_junction_deviation', "Toleranz an Ecken (Klipper: Junction Deviation). Größer = schnellere Ecken.",
  "Schnellere Ecken, mehr Vibration.", "Sanftere Ecken.", None, 'jerk')
E('support_ironing', "Bügelt die Oberfläche der Support-Kontaktschicht. So wird die Fläche am Teil glatter.",
  "Glattere Fläche am Teil, längere Druckzeit.", "Normale Kontaktschicht.", None, 'ironing')
E('support_ironing_pattern', "Muster beim Bügeln der Support-Kontaktschicht.", None, None, None, 'ironing')
E('support_ironing_flow', "Fluss beim Bügeln der Support-Kontaktschicht.", "Dichtere Fläche.", "Nur glätten.", None, 'ironing')
E('support_ironing_spacing', "Linienabstand beim Bügeln der Support-Kontaktschicht.", "Schneller.", "Glatter.", None, 'ironing')
E('prime_tower_brim_chamfer', "Schrägt den Rand am Reinigungsturm Schicht für Schicht ab.", "Spart Material.", "Voller Rand.", None, 'brim')
E('prime_tower_brim_chamfer_max_width', "Maximale Breite der Abschrägung am Turmrand.", "Sanfterer Verlauf.", "Steilerer Verlauf.", None, 'brim')
E('wipe_tower_wall_type', "Aufbau der Turmwand (z. B. Rechteck, Rippen, Dreieck).", "Stabilere Wände mit Rippen.", "Einfache Wand ist schneller.", None, 'primeTower')
E('wipe_tower_extra_rib_length', "Zusätzliche Länge der Rippen am Turm.", "Mehr Stabilität.", "Weniger Material.", None, 'primeTower')
E('wipe_tower_rib_width', "Breite der Rippen am Turm.", "Stabiler.", "Schlanker.", None, 'primeTower')
E('wipe_tower_fillet_wall', "Rundet die Ecken der Turmwand aus.", "Sauberere Ecken, stabiler.", "Eckiger Turm.", None, 'primeTower')
E('single_loop_draft_shield', "Begrenzt die Schürze/den Windschutz nach der ersten Schicht auf eine einzige Wand.",
  "Spart Filament, kann aber instabil werden.", "Mehrere Wände: stabiler.", None, 'skirt')
E('fuzzy_skin_mode', "Wie die raue Struktur (Fuzzy Skin) erzeugt wird: Verschiebung der Düse, Extrusionsmenge oder beides.",
  "Kombiniert: dichte Wände ohne Poren.", "Verschiebung: klassische, raue Oberfläche.", None, 'fuzzySkin')
E('delta_temperature', "Differenz zur Zieltemperatur, auf die die nächste Düse vorgeheizt wird (z. B. −30 °C).", "Kühler vorgeheizt, sickert weniger.", "Näher an der Solltemperatur: schneller bereit.", None, 'preheat')
E('dithering_local_z_mode', "Teilt die Schichthöhe in Mischzonen für feinere Farbübergänge (experimentell).", "Weichere Farbübergänge.", "Normale Schichten.", None, 'filamentAssign')
E('dithering_local_z_whole_objects', "Wendet die Unterteilung auf ganze Farbbereiche an (experimentell).", "Einheitliche Mischzonen.", None, None, 'filamentAssign')
E('dithering_local_z_infill', "Wendet die Unterteilung auch auf die Füllung an (experimentell).", "Bessere Farbmischung innen.", "Füllung in normaler Schichthöhe.", None, 'filamentAssign')

E('rotate_solid_infill_direction', "Dreht die Richtung der Vollfüllung in jeder Schicht um 90°. So kreuzen sich die Linien von Schicht zu Schicht.",
  "Dichtere, gleichmäßigere Deckflächen und Böden.", "Alle Schichten in einer Richtung – schneller zu slicen, Linien können durchscheinen.", None, 'surfacePattern')
E('internal_bridge_angle', "Winkel der inneren Brücken (Füllung unter der Deckfläche). Bei 0 berechnet der Slicer ihn automatisch.",
  "Fester Winkel kann ein Muster erzwingen.", "0 = automatisch (empfohlen).", None, 'bridge')
E('minimum_sparse_infill_area', "Kleine Füllungsflächen unter diesem Wert (mm²) werden durch Vollfüllung ersetzt.",
  "Mehr kleine Inseln werden massiv gedruckt, fester.", "Mehr kleine Füllungsflächen bleiben luftig.", None, 'infillDensity')
E('detect_narrow_internal_solid_infill', "Erkennt schmale innere Vollfüllungs-Bereiche und druckt sie konzentrisch (schneller) statt geradlinig.",
  "Schnellerer Druck bei schmalen Flächen.", "Immer geradlinig.", None, 'surfacePattern')
E('overhang_speed_classic', "Schaltet den klassischen Modus der Überhang-Geschwindigkeit ein: feste Stufen je nach Überhang-Anteil.",
  "Klassische, vorhersehbare Stufen.", "Dynamische Anpassung.", None, 'overhang')
E('independent_support_layer_height', "Der Support hat eine eigene Schichthöhe, unabhängig vom Teil. Das spart Zeit und erlaubt eigene Z-Abstände.",
  "Schnellerer Support, flexible Abstände.", "Support folgt der Schichthöhe des Teils (sauberer Übergang).", "Wird ignoriert, wenn der Reinigungsturm aktiv ist.", 'supportGap')
E('spiral_mode', "Vasenmodus: Die Außenwand wird als eine ununterbrochene Spirale nach oben gedruckt. Das Teil hat nur eine Wand, einen festen Boden und keine Naht.",
  "Glatte, nahtfreie Vasen und Behälter.", "Normaler Druck mit Schichten und Naht.", "Nur für Teile mit einer durchgehenden Außenwand sinnvoll (Vasen, Becher).", 'spiralVase')
E('wipe_tower_wall_gap', "Lässt an den Werkzeugwechsel-Punkten kleine Lücken in der Turmwand, damit Filamentreste dort landen und nicht auf der Außenwand.",
  "Sauberere Turmwand.", "Geschlossene Wand.", None, 'primeTower')


def sw(s):
    if s is None:
        return 'nil'
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


lines = []
for k, (m, more, less, ex, dia) in D.items():
    lines.append(f'        "{k}": SlicerOptionDetail(meaning: {sw(m)}, more: {sw(more)}, less: {sw(less)}, example: {sw(ex)}, diagram: {("." + dia) if dia else "nil"}),')
open(OUT, 'w').write('// Generated by tools/settings/build_details.py – do not edit.\n\nextension SlicerOptionDetails {\n    static let generated: [String: SlicerOptionDetail] = [\n'
                      + '\n'.join(lines) + '\n    ]\n}\n')
print(len(D), 'detailed explanations written')

# Which catalog keys still have neither a hand-written nor a generated entry?
cat = open(os.path.join(HERE, '../../Packages/MakerSliceCore/Sources/SliceKit/Settings/SlicerOptions.generated.swift')).read()
hand = open(os.path.join(HERE, '../../Packages/MakerSliceCore/Sources/SliceKit/Settings/SlicerOptionDetails.swift')).read()
have = set(re.findall(r'^        "([a-z_0-9]+)": d\(', hand, re.M)) | set(D)
missing = [k for k in re.findall(r'SlicerOption\(key: "([^"]+)"', cat) if k not in have]
print('without detail:', missing)
