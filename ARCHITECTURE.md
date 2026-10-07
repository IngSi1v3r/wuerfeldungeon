# Architektur · Würfeldungeon 1.1.0

## Webapp

Native JavaScript-Module, HTML, CSS und SVG bilden eine statische Webapp ohne Framework-Laufzeit. Hash-Routen funktionieren auch unter dem Unterpfad eines GitHub-Pages-Repositories. `app.js` verwaltet Sitzung, Navigation und Einstellungen. Ansichten räumen Verbindungen, Timer und Dialoge beim Verlassen auf.

Der Editor läuft in einem gleichoriginären iframe. Die Spielansicht, Vorschauen und Druckexporte verwenden dieselbe Feld-/Bilddarstellung. Nur `web/` wird öffentlich gehostet.

## Anmeldung

`dungeon_players` enthält Profilinformationen. Passwort-Hashes, Sitzungshashes und Anmeldebegrenzung liegen im privaten Schema. Passwörter werden serverseitig mit bcrypt gehasht. Im Browser liegt der Sitzungsschlüssel, serverseitig ausschließlich sein SHA-256-Hash. Sitzungen laufen spätestens nach 180 Tagen ab und können widerrufen werden.

Spieler-RPCs prüfen diesen Schlüssel. Supabase Auth wird für Spieler nicht benötigt. Registrierung und optionaler Zugangscode sind serverseitige Konfiguration; `app_status()` liefert die Formularoptionen.

## Karten und Bilder

Entwürfe liegen in `dungeon_maps`. Befristete, sitzungs-/tabbezogene Sperren verhindern gemeinsames Überschreiben. Revisionen erkennen konkurrierende Änderungen. Autospeicherung und kartenspezifische lokale Wiederherstellung ergänzen die Serverkopie.

Der Bucket `map-assets` enthält Kartenbilder, `avatars` enthält Profilbilder. Die Edge Functions prüfen Sitzung, Dateiformat und Größe, bevor sie mit serverseitigen Projektwerten schreiben. Browsercode enthält keine geheimen Schlüssel.

Der Editor löst Bildreferenzen zu eingebetteten Bildern auf. Portable Exporte funktionieren unabhängig von Storage-URLs. Beim Veröffentlichen prüft der Server Geometrie, offene Verbindungen, Portale, Anforderungen, Freischaltungen und Aufgaben. `dungeon_map_versions`, `dungeon_map_cells` und `dungeon_map_connections` frieren die Definition ein. Alte Veröffentlichungen/Partien bleiben lesbar; ausschließlich bearbeitete Entwürfe werden aktualisiert.

## Partien

`dungeon_games` speichert Warteraum, Einstellungen, Würfel, Runde und Spielphase. Teilnehmer und persönlicher Fortschritt liegen in `dungeon_game_players` und `dungeon_game_player_states`. Spielerbefehle werden serverseitig validiert und mit Anfrage-UUID gespeichert. Wiederholte Übertragung verursacht keine doppelten Züge oder Belohnungen.

Transaktionen regeln Rundenschluss, gemeinsame Erstbelohnungen, Fallen, Powerups und Endwertung. Ereignisse, Ergebnisse und Wiederholungsbilder werden separat gespeichert. Realtime-Broadcasts lösen das Laden des aktuellen RPC-Zustands aus; Polling übernimmt bei fehlendem Realtime. Ein dezenter Punkt zeigt den Verbindungsstatus.

Fog-Sicht folgt dem Graphen und stoppt bei unbesiegten Monstern/Bossen. Die Hintergrundfreigabe verrät keine verdeckten Räume. Der lokale Testmodus besitzt eine eigene Browser-Spielinstanz und speichert keine Partien, Punkte oder Statistiken.

## Shop und Betrieb

Private Kataloge, Guthaben, Käufe und Anfrage-IDs bilden den Shop. Katalogeinträge mit Preis 0 sind sofort verfügbar, ohne Kaufdatensatz. Neue Preise verändern keine historischen Käufe. Shopguthaben und Spielpunkte sind getrennt.

Release 1.1.0 verwendet Migrationsstand 16. `032_solo_ai_highscores.sql` ist das Upgrade, `install.sql` die Einrichtung eines leeren Projekts. Der separate Reset bewahrt Schema, Kataloge und Konfiguration. Storage-Dateien werden über die Storage-Oberfläche entfernt.


## Einzelspiele und KI

`dungeon_games.mode` unterscheidet `multiplayer`, `solo` und `ai_test`. `create_solo_game` erzeugt die komplette Partie atomar und startet sie sofort. KI-Plätze sind Profile ohne Zugangsdaten (`is_bot`), mit persönlichen Zuständen und normalen Spielereignissen. In KI-only-Partien ist der Host Zuschauer ohne eigenen Spielersitz. Diese Partien sind ausschließlich für den Host zugänglich und werden nicht öffentlich gelistet.

`get_ai_context` liefert dem Host legale Aktionen und die für den jeweiligen KI-Spieler sichtbaren Räume. Bilder werden für die Entscheidungsberechnung weggelassen. `ai.js` bewertet diese Aktionen anhand aktueller Treffer, Belohnungen, Aufgaben, Ressourcen, erreichbarer Wege und lokaler Würfelwahrscheinlichkeiten. Es simuliert keine zukünftigen Züge. `ai-controller.js` führt die Vorschläge nacheinander aus; Pausen und veraltete Revisionen werden beachtet. Ohne geöffneten Hostbrowser läuft die KI nicht weiter.

`perform_ai_action` prüft Host und Spielmodus sowie den betroffenen KI-Sitz. Eine ausschließlich interne, innerhalb derselben Transaktion wieder gelöschte Sitzung ruft die bestehenden Würfel-/Zug-/Powerup-RPCs auf. Keine Bot-Sitzung wird an den Browser ausgegeben. Die vollständige Regelprüfung, Anfrage-Idempotenz, Rundenabschlüsse und Replays bleiben damit dieselben. Konkurrierende Hosttabs können wegen Zustandsrevisionen und Rundenprüfung keinen doppelten Zug verbuchen.

Das KI-Labor führt begrenzte Testreihen aus. Fortsetzungs-IDs liegen als Komfort-Cache lokal; jede Folgerunde erhält eine aus Ursprungsspiel und Durchlaufnummer deterministisch abgeleitete Anfrage-UUID. Auch nach verloren gegangener Antwort wird dieselbe Testpartie wiedergefunden. Tests speichern Ergebnisse/Replays zum Vergleichen, aber keine menschlichen Statistiken oder Shopgutschriften.

## Abenteuerwertung

`dungeon_private.adventure_scores` speichert kompakte, unveränderliche Ergebnissnapshots inklusive Formelversion, Nettopunkten, Runden, Kartenaufwand, Teilnehmerzahl, Rotwürfel-Takt, Erwartungswert und ungerundeter Wertung. Der Abschluss-Trigger befüllt diese Tabelle; die Migration ergänzt ältere abgeschlossene Spiele, soweit die Grunddaten vorhanden sind. Die Rangfolge verwendet PostgreSQL `numeric` und `rank()`.

`list_highscores` und `list_highscore_maps` sind sitzungsgeprüfte RPCs. Menschliche Bestenlisten schließen KI-only-Partien und Bot-Ergebnisse aus. Das KI-Labor verwendet dieselbe Formel in seiner separaten Auswertung. Ergebnisdetails nennen KI-Gegner ausdrücklich als experimentell. `get_game_result` und `get_game_replay` schützen private KI-Testdaten vor anderen Spielern. Der Standard-Reset erfasst die neuen Tabellen über Fremdschlüssel ebenfalls.
