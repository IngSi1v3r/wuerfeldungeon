# Kartenformat · Würfeldungeon 1.0.2

Aktuell: `dungeon-layout-v7`. Die Releaseversion ist unabhängig von der Formatversion. Vorhandene JSON-Dateien bleiben importierbar.

Das Dokument enthält `rooms`, `closedDoors`, `nextId`, `background`, optional `previewImage`, `printLayout`, `rules` und `allowedPowerups`. Online stehen Bilder als `asset:<pfad>`-Referenzen; portable Exporte enthalten Base64-Bilddaten.

## Felder

Jedes Feld besitzt eine numerische dauerhafte `id`, `type`, Rasterposition `x/y`, Größe `w/h`, Anforderung `number` sowie die unabhängigen booleschen Eigenschaften `start` und `dimmed`. Auch Sonderfelder können beide Eigenschaften haben. Monster und Bosse dürfen keine davon besitzen. Bonusaufgaben gelten erst nach allen nötigen Treffern als erreicht.

| Typ | Weitere Daten |
| --- | --- |
| `normal` | Zahl 2–12 oder `doubles` für beliebigen Pasch; 4×4 |
| `doubleSum` | Gerade Summe 2–12; ausschließlich passender Pasch; 4×4 |
| `rune` | `runeEffect`: `unlock` (Vorgabe) oder `hits`; `runeHits`: ganze Trefferzahl 1–100 (Vorgabe 3) |
| `diamond`, `goldSack`, `goldCoin`, `chest` | Anforderung; variable Größe |
| `portal` | Genau zwei Portale je Anforderung |
| `trap` | `trapKind` (`diamonds`/`life`), positiver `trapCost` |
| `crazy` | Pool `requirements`; jede Runde ein gemeinsamer Zufallswert |
| `monster`, `boss`, `bonus` | `name`, `hits`, `attacks`, `rewardFirst/rewardLater`, lebendes/besiegtes Bild und Bildposition/-größe |

Angriffe sind `{number,state}` mit `active` oder `locked`. Graue Felder benötigen einen offenen Kontakt zu Monster/Boss. Der Compiler verknüpft ihre Anforderungen mit gesperrten Angriffszahlen. Graue Würfel-/Bonusaufgabenfelder verlinken ihre möglichen Anforderungen; Erreichen schaltet diese frei.

Runen ohne neue Eigenschaften behalten ihre Freischaltwirkung. `unlock` verknüpft die eigene Würfelzahl aus der Ferne mit den Bossangriffen. `hits` erzeugt Einträge in `rules.bossHits`: `{sourceCellId,targetCellId,hits}`. Diese Liste wird beim Veröffentlichen serverseitig aus den Feldern erzeugt. Sie trifft jedes Bossfeld einmal beim erstmaligen Erreichen der Rune auf dem eigenen Brett, auch im Fackelweg. Treffer werden auf die Lebensanzahl begrenzt und nutzen dieselbe Belohnungs- und Abschlusslogik wie gewöhnliche Angriffe. Ein zusätzlich gesetztes graues Angriffsfeld bleibt eine unabhängige Eigenschaft für direkt angrenzende Gegner.

## Verbindungen und Aufgaben

Berührung über mindestens eine Rasterlänge erzeugt eine Verbindung. `closedDoors` schließt sie mit sortiertem Schlüssel `id:id`. Portale ergänzen den Laufgraphen.

`rules.version` ist `2`. `unlocks`, `bossHits` und `portalPairs` werden neu berechnet. Die zwei Aufgaben liegen in `goals`: Typ, Ziel-IDs/Feldart, optionale `requiredCount`, Diamantenziel und Belohnung `{first,later}`. Ohne `requiredCount` werden alle Ziele benötigt. Verbindungsaufgaben benötigen zwei Endpunkte; Gegnerkombinationen besitzen einen eigenen Wettlauf.

Veröffentlichte Karten werden nicht nachträglich verändert oder neu kompiliert. Weiterbearbeitung erfolgt über eine Kopie.
