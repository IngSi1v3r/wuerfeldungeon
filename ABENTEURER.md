# Wie die Abenteurer in Version 1.2.0 entscheiden

Ein Abenteurer bewertet die Wirkung seines aktuellen Zuges und untersucht anschließend zwei mögliche Folgerunden. Es handelt sich um eine regelbasierte Planung mit Würfelstichproben. Es wird nichts trainiert und kein externer KI-Dienst aufgerufen.

## Ablauf einer Entscheidung

1. Der Server liefert die erlaubten aktuellen Züge, Ressourcen, Aufgaben, die sichtbaren Felder und bekannten Belohnungen. Nur bei offenen Karten kommen fremde Fortschritte hinzu.
2. Alle erlaubten Züge werden berücksichtigt. Roter Würfel, Fackelweg und Doppelhit sind eigene Varianten. Wenn nur Zusatzmittel helfen, ist auch der Verlust eines Lebens eine Alternative.
3. Die Simulation führt jeden Kandidaten aus. Sie berücksichtigt Treffer, Beute, Portale, Runen, Freischaltungen, Fallen, Bonusaufgaben, Lebensfelder und den Verbrauch von Hilfsmitteln. Bei einer Truhe wird eine passende verfügbare Verbesserung angenommen. Sobald alle nötigen Gegner erledigt sind, gibt es keine fiktiven weiteren Züge mehr.
4. Für alle aktuellen Kandidaten werden **dieselben** zukünftigen Würfelstichproben benutzt. Pro erster Folgerunde werden bis zu drei gute Fortsetzungen untersucht. Für jede davon wird über drei Würfe der zweiten Folgerunde gemittelt. Erst danach wird die beste erste Fortsetzung ausgewählt. Der Abenteurer kennt den zweiten Wurf also nicht bereits bei seiner ersten simulierten Entscheidung.
5. Der erwartete Nutzen wird mit der sofortigen Wirkung kombiniert. Seltene Zahlen bekommen einen kleinen Gelegenheitsbonus. Nur der Glücksritter hat zusätzlich einen reproduzierbaren Zufallsanteil.
6. Der vorgeschlagene Zug wird vom Server vollständig geprüft. Nur ein angenommener Zug erhält ein dauerhaftes Analyseprotokoll; wiederholte Anfragen erzeugen keinen Doppelzug.

Je nach Anzahl aktueller Kandidaten werden drei bis acht Würfe der ersten Folgerunde untersucht. Die zweite Folgerunde hat jeweils drei Stichproben. Das ist eine begrenzte Erwartungswertsuche, keine vollständige Berechnung aller Würfelfolgen. Jeder aktuelle Kandidat bekommt dieselbe Stichprobengröße. Die Zukunft anderer Spieler wird nicht vollständig simuliert.

## Bewertung

Bewertet wird der Zustand des Bretts, nicht immer wieder die Auszahlung derselben hypothetischen Belohnung. In der Anzeige steht:

**Gesamt = Veränderung jetzt + erwarteter weiterer Gewinn × 0,8 + Gelegenheitsbonus + Charakterzufall.**

Die Zustandsbewertung enthält:

- Nettopunkte einschließlich Gold, Lebensabzügen und möglicher Boss-Dreiergruppen.
- Kampffortschritt, erledigte Gegner und Abschluss des Labyrinths.
- Erkundete Wege, neue erreichbare Felder und Nähe zu lohnenden Zielen. Wegkosten berücksichtigen benötigte Treffer und die Wahrscheinlichkeit passender Zahlen.
- Fortschritt bei Bonusaufgaben.
- Sicherheit, insbesondere die Gefahr auszuscheiden.
- Den Restwert unbenutzter Hilfsmittel.
- Bei offenen Karten Konkurrenz um Erstbelohnungen. Abschlüsse in derselben Runde teilen weiterhin die Erstbelohnung.

Das sind **interne Vergleichswerte**, keine Diamanten oder echten Spielpunkte. Die nachstehenden Faktoren verändern die Gewichtung dieser Bereiche. Ein Faktor 1,5 bedeutet 50 % mehr Gewicht für diesen Teil.

| Charakter | Punkte | Kampf | Wege | Aufgaben | Sicherheit | Hilfsmittel | Konkurrenz | Zufallsanteil |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Berserkerin | 1 | 1,5 | 1 | 0,9 | 0,75 | 0,65 | 0,6 | 0 |
| Wächter | 1 | 1 | 1 | 1 | 1,8 | 1,6 | 0,4 | 0 |
| Schatzjägerin | 1,4 | 0,85 | 1 | 1,3 | 1,1 | 1 | 0,7 | 0 |
| Rivale | 1,1 | 1,1 | 1 | 1 | 1 | 0,8 | 2,4 | 0 |
| Glücksritter | 1 | 1,05 | 1,15 | 1 | 0,7 | 0,7 | 0,8 | ±1,8 |

Der Rivale kann bei verdeckten Karten keine fremden Teiltreffer auswerten. Auch das Fernglas erlaubt keinen Blick durch unbesiegte Monster. Die Planung unter Nebel bleibt auf die derzeit bekannten Felder beschränkt; unbekannte Räume werden nicht erfunden.

## Dateien und Protokolle

| Datei | Aufgabe |
| --- | --- |
| `web/js/games/adventurers.js` | Charaktere, Farben, Markierungen und Gewichtungen |
| `web/js/games/ai-simulation.js` | Reine Simulation von Zügen und Spielfolgen |
| `web/js/games/ai.js` | Bewertung, Würfelstichproben und zwei Folgerunden |
| `web/js/games/ai-worker.js` / `ai-planner.js` | Berechnung im Browser-Hintergrund |
| `web/js/games/ai-controller.js` | Serverbefehle, Wiederholungsschutz, Schrittmodus |
| `web/js/views/ai-lab.js` | Abenteurerprobe, Zeitleiste und Analyse |
| `supabase/migrations/034_adventurers.sql` | Charakterdaten und private Analyse-RPCs |

Das Analyseprotokoll enthält Algorithmusversion, Charakter, Runde, tatsächlichen Wurf, Zustand vor dem Zug, Kandidaten mit Teilbewertungen und gewählten Zug. Zusammen mit den bestehenden Replay-Schnappschüssen lässt sich der damalige Ablauf darstellen. Die Anzeige berechnet alte Entscheidungen nicht mit möglicherweise später geänderten Gewichtungen neu.

Die Testreihen verwenden echte serverseitige Würfe. Die zufälligen Zukunftsstichproben sind pro Abenteurer und Runde reproduzierbar; sie beeinflussen die tatsächlichen Würfe nicht. Statistische Unterschiede zwischen Charakteren sollte man über mehrere Partien betrachten.

Die Abenteuerwertung und ihre Formel bleiben gegenüber Version 1.1.0 unverändert. Auch Gegner in Mehrspielerpartien mit echten Spielern werden in diesem Schritt nicht ergänzt.
