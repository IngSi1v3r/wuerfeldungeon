# Würfeldungeon 1.2.0 einspielen

## Update von der funktionierenden Version 1.1.0

1. In Supabase den **SQL Editor** öffnen und **Wuerfeldungeon_SQL_1_2_0.sql** vollständig ausführen. Das ist das Upgrade mit anschließender Prüfung. Alle sieben Ergebnisse sollen **OK** sein. Im Projekt sind dieselben Dateien als `034_adventurers.sql` und `035_check_adventurers.sql` enthalten.
2. Das ZIP entpacken. Den **Inhalt des Ordners `wuerfeldungeon`** in deinen bestehenden lokalen Repository-Ordner kopieren und vorhandene Dateien überschreiben. Die Struktur bleibt wie bei 1.1.0: `web/`, `supabase/`, `tests/`, `scripts/` und der GitHub-Workflow. In GitHub Desktop committen und **Push origin** klicken.
3. Den erfolgreichen GitHub-Actions-Lauf abwarten und die Website mit **Strg+F5** neu laden. Unten steht **1.2.0**.

Spieler, Karten, Partien, Guthaben, Käufe und Bestenlisten bleiben erhalten. Neue Schlüssel, Buckets oder Edge Functions sind nicht erforderlich. Das SQL ist wiederholbar. `install.sql` und `RESET_ALL_DATA.sql` gehören nicht zu diesem Update.

## Abenteurer ausprobieren

**Spielen → Neues Einzelspiel → Karte wählen.** Bei „Mitreisende“ die gewünschte Zahl wählen. Darunter lässt sich pro Platz ein Charakter auswählen: Berserkerin, Wächter, Schatzjägerin, Rivale oder Glücksritter. Der Rotwürfel-Takt ist weiterhin einstellbar. Das Spiel beginnt unmittelbar ohne Warteraum.

Für eine automatische Probe **„Nur Abenteurer spielen · ich schaue zu“** aktivieren. Eine Testreihe kann wie bisher aus 1, 3, 5 oder 10 Partien bestehen. Sie zählt ausschließlich für die eigene Testauswertung, nicht für menschliche Statistik, Guthaben oder Bestenlisten.

Die **Abenteurerprobe · experimentell** bietet:

- Eine gemeinsame Karte mit verschiedenen Farben und Markierungsstilen oder die einzelne Karte eines Abenteurers. Kleine Trefferanzeigen zeigen dessen Kampffortschritt.
- Rundenweise vorwärts und rückwärts, einen abspielbaren Verlauf und **Live**, um zur laufenden Partie zurückzukehren. Das Zurückblättern setzt keine echten Spielzüge zurück.
- **Bewertungen anzeigen:** Der ausgewählte Abenteurer zeigt spielbare Ziele mit Bewertung und Stern beim gewählten Zug. Die Tabelle unterscheidet sofortige Wirkung, Vorausblick und Gesamtwert. Rot, Axt und Fackel erscheinen als eigene Zugvarianten. Ein Klick auf ein Feld schränkt die Tabelle auf dieses Feld ein.
- **Nach jedem Wurf anhalten:** Würfeln geschieht automatisch, anschließend wartet die Probe auf **„Züge dieser Runde ausführen“**. So kannst du die Bewertungen vor dem Zug ansehen.
- Partie pausieren, Tempo ändern und Vollbild. Abgeschlossene Proben lassen sich aus der Liste erneut öffnen; ihre Analysen bleiben erhalten.

Der Host muss die Partie oder Probe im Browser geöffnet lassen, damit die Abenteurer ziehen. Die Berechnung läuft in einem Hintergrund-Worker, der Server prüft jeden Zug. Charaktere und Planung sind experimentell; sie suchen gute Züge und kennen keine verdeckten Felder. Details zum Verfahren und zu den Gewichtungen stehen in [ABENTEURER.md](ABENTEURER.md).

Ältere Partien besitzen ihren vorhandenen Replay-Verlauf. Ihre neuen Zugbewertungen werden erst ab dem Update aufgezeichnet; die fehlende Vorgeschichte wird nicht nachträglich erfunden.

## Freiwillig ein Leben verlieren

Wenn kein direkter Zug ohne Zusatzmittel möglich ist, kannst du auf die **Lebensanzeige** klicken und nach der Warnung ein Leben verlieren. Der Zug endet und rote Würfel sowie Fackeln bleiben erhalten. Auch Enter oder Leertaste funktionieren auf der fokussierten Anzeige. Bei einem möglichen direkten kostenlosen Zug lässt der Server dies weiterhin nicht zu. Ein drohendes Ausscheiden wird in der Warnung genannt.

## Vollständig neues Projekt

Nur in einer leeren Datenbank `supabase/install.sql` ausführen, danach `035_check_adventurers.sql`. Projektwerte stehen in `web/js/config.js` und `supabase/config.toml`. Die vorhandenen Anleitungen zu Bild-Uploads und Realtime gelten weiter. Im Browser ausschließlich den öffentlichen Publishable Key verwenden.

## Registrierung mit optionalem Zugangscode

Die Registrierung bleibt ohne gemeinsamen Zugangscode möglich. Die optionale Codepflicht kann später wieder aktiviert werden:

```sql
update dungeon_private.app_config set registration_code_required=true where singleton;
```

Zum Deaktivieren `false` verwenden. Der konfigurierte Code bleibt erhalten.
