# Editor und Exporte

Die Dokumentstruktur steht in [MAP_FORMAT.md](MAP_FORMAT.md).

Felder werden am Raster bewegt; Berührung über mindestens eine Rasterlänge erzeugt einen schaltbaren Durchgang. Mehrfachauswahl, Verschieben, Größenänderung, Bildbearbeitung und Rückgängig/Wiederholen erhalten die Feld-IDs.

Rechtsklick öffnet Eigenschaften und Anforderungen. Kleine Weg-/Sonderfelder können ihre Feldart wechseln. Start-/Angriffsfeld sind zusätzliche Eigenschaften; Monster/Boss zeigen diese Optionen nicht. Änderungen werden automatisch gespeichert. Der Host verwaltet Revisionen, Sperren und lokale Wiederherstellung. Das iframe hat kein gemeinsam genutztes Offline-Projekt.

Runen bieten im Rechtsklickmenü „Angriffszahl freischalten“ oder „Boss treffen“. Bei der Trefferwirkung ist die Anzahl von 1 bis 100 einstellbar; sie steht zusätzlich zur Würfelzahl im Feld und im Druckexport. Bestehende Runen bleiben Freischaltfelder.

Der Editor ist für den PC ausgelegt; auf Touchgeräten erscheint ein Hinweis. Spielen und Karten ansehen funktionieren mobil.

## Exporte

- JSON mit eingebetteten Bildern.
- Spielfeld-PNG ohne Ziehpunkte und Durchgangsschalter.
- Drucklayout mit Rahmen, Name/Titelbild, Aufgaben, Lebensanzeige, ausgewählten Powerups und Punktefeldern. Goldmünzen/-säcke erhalten nur die tatsächlich nötige Anzahl Kästchen. Die Diamantenzählung berücksichtigt den erreichbaren Höchstwert.
- PDF über die Browser-Druckansicht.

Vorschauen verwenden dieselbe Grafik. Fog-Partien erhalten eine eigene Vorschau mit der Sicht der ersten Runde. Drucklayout und Feldkoordinaten bleiben unabhängig.
