# Würfeldungeon 1.1.0 einspielen

## Bestehende Version 1.0.2 aktualisieren

1. Im Supabase-Projekt `uqbpjsgffxoibvibfvgg` den **SQL Editor** öffnen. Die separat bereitgestellte Datei **Wuerfeldungeon_SQL_1_1_0.sql** einmal vollständig ausführen. Alternativ im Projekt `032_solo_ai_highscores.sql`, danach `033_check_solo_ai_highscores.sql` ausführen. Alle sieben Prüfungen sollen `OK` anzeigen.
2. Das ZIP entpacken und die Dateien aus dem darin enthaltenen Ordner `wuerfeldungeon/` ins bestehende GitHub-Repository übernehmen. Bestehende Dateien überschreiben. Die vollständige Website liegt in `web/`; den aktuellen Workflow `.github/workflows/deploy.yml` ebenfalls übernehmen.
3. Nach dem GitHub-Pages-Deployment die Seite vollständig neu laden. Unten rechts steht **1.1.0**.

Spieler, Karten, Käufe, Guthaben und bisherige Partien bleiben erhalten. Abgeschlossene menschliche Partien werden anhand ihrer gespeicherten Kartenversion und Ergebnisse in die Bestenlisten übernommen. Das SQL ist wiederholbar. Es führt keinen Reset aus.

Falls das Projekt noch auf 1.0.1 steht, zuerst `030_playtest_polish.sql` installieren. Die Bildfunktionen `avatar-upload` und `map-asset-upload`, Storage-Buckets und Realtime-Einstellungen bleiben unverändert. Keine neuen Schlüssel, Buckets oder Edge Functions nötig.

## Neue Funktionen ausprobieren

- **Spielen → Neues Einzelspiel:** Karte auswählen, Rotwürfel-Takt und optional 0–7 KI-Gegner einstellen. Das Spiel startet unmittelbar; es erscheint kein öffentlicher Warteraum. Die normalen Würfel- und Zugregeln gelten weiterhin.
- Der kostenlose rote Würfel steht jedem Teilnehmer im eingestellten Takt zur Verfügung, zeitlich um seine Sitzposition versetzt. „Teilnehmerzyklus“ entspricht einmal je Teilnehmerzahl. Auch in den anderen Runden wird Rot mitgewürfelt und kann mit einer vorhandenen Sonderwürfel-Verwendung eingesetzt werden.
- **Nur KI spielt → Testreihe:** Ein oder mehrere KI-Spieler, 1/3/5/10 automatische Partien. Standardmäßig spielen zwei KIs gegeneinander; eine einzelne KI erlaubt den Vergleich mit einem reinen Solospiel. Das KI-Labor würfelt, zieht und wählt Powerups selbst. Es zeigt pro Partie Ergebnisse und Replay. Über den Spielerwähler können die einzelnen Bretter beobachtet werden. „Pausieren“ hält die laufende Partie an.
- Reine KI-Testpartien haben eine eigene Auswertung im Labor. Sie zählen nicht für menschliche Bestenlisten, Chronik, Profilstatistik oder Shopguthaben. Ein echtes Einzelspiel mit menschlichem Teilnehmer zählt regulär, einschließlich eventueller KI-Gegner.
- **Lager → Bestenlisten:** Karte wählen, nach Gegnerzahl oder Rotwürfel-Takt filtern. Ein Klick auf einen Eintrag zeigt Punkte, Runden und Gegner. Am Partieende erscheint zusätzlich die Kartenbestenliste mit deiner Position.
- Replay bietet Vollbild, die Geschwindigkeiten Normal/Schnell/Sehr schnell und den Markierungsstil des ausgewählten Spielers.

Die KI ist experimentell. Sie bewertet nur die aktuelle Situation, verwendet keine Suche über zukünftige Runden und beachtet den Nebel. Die Berechnung läuft im Hostbrowser; dieser muss die Partie bzw. das KI-Labor geöffnet lassen. Beim Verlassen bleibt der Spielstand gespeichert. Über „Fortsetzen“ bzw. das KI-Labor geht es weiter. KI-Testreihen dürfen wegen der vielen automatischen Züge im Hintergrund vom Browser gedrosselt werden.

## Abenteuerwertung

`W = 100 × (2 × P/M + D × F/R) / 3`

- `P`: tatsächlich erreichte Nettopunkte, inklusive Gold und Lebensabzügen.
- `R`: gemeinsame Rundenzahl der abgeschlossenen Partie.
- `F`: Kartenaufwand; gewöhnliche Felder zählen einmal, Monster/Bosse/Bonusaufgaben je benötigtem Treffer. Grafische Feldgröße und Runen-Abkürzungen verändern diesen Maßstab nicht.
- `M`: erwartete erreichbare Punkte je Spieler. Persönliche Beute zählt vollständig, spätere Belohnungen ebenfalls; die Differenz zur Erstbelohnung wird durch die Teilnehmerzahl geteilt. Boss-Dreiergruppen zählen zur möglichen späteren Bossbelohnung, nicht zusätzlich zur Erstbelohnung. Ein möglicher Extraleben-Diamant wird berücksichtigt.
- `D`: Rotwürfel-Ausgleich ausschließlich für den Geschwindigkeitsteil. Bei freiem Rot jede Runde `1`; bei jeder zweiten Runde ungefähr `1,238`, bei jeder vierten Runde ungefähr `1,404`.

100 ist ein Richtwert, keine Obergrenze. Die Anzeige rundet auf ganze Zahlen; die Rangfolge verwendet den ungerundeten Wert. Gleiche Werte teilen den Rang. Innerhalb derselben Partie folgt die Reihenfolge weiterhin den Nettopunkten. Der Gewinner wird wie bisher anhand der Punkte bestimmt.

Die Wertung ist ein vereinfachter Vergleich, kein exakter Schwierigkeitsmesser: konkrete Würfe, Lebensverluste, Runeffekte, gleiche Erstbelohnungsrunden und verfügbare Powerups beeinflussen Partien. Karten ohne positiven Punkte-Erwartungswert werden ohne Abenteuerwertung beendet. Jede unveränderbare Kartenversion hat eine eigene Bestenliste. Gespeicherte Werte werden bei erneutem SQL-Update nicht neu berechnet.

## Vollständig neues Projekt

Für ein leeres Projekt `supabase/install.sql` ausführen und mit `033_check_solo_ai_highscores.sql` prüfen. Vorhandene Datenbanken immer mit der Migration aktualisieren. Projektwerte in `web/js/config.js` und `supabase/config.toml` anpassen; im Browser ausschließlich den öffentlichen Publishable Key verwenden. Die vorhandenen Bild-Upload-Functions und Buckets nach ihrer bisherigen Anleitung einrichten.

## Optionale Registrierung mit Zugangscode

Die Codepflicht bleibt zunächst deaktiviert. Sie kann in Supabase wieder aktiviert werden:

```sql
update dungeon_private.app_config set registration_code_required=true where singleton;
```

Zum Deaktivieren `false` verwenden. Der bisher konfigurierte Code bleibt erhalten.

## Vollständiger Neustart (nur wenn ausdrücklich gewünscht)

Karten vorher als portable JSON-Dateien sichern. `supabase/RESET_ALL_DATA.sql` löscht Spieler, Karten, Partien, Ergebnisse, KI-Tests, Bestenlisten, Guthaben und Käufe. Schema und Kataloge bleiben erhalten. Bilddateien separat über Supabase Storage entfernen; SQL löscht keine physischen Dateien. Dieses Reset-Skript gehört nicht zum normalen Update.
