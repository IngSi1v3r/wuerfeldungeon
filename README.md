# Würfeldungeon 1.1.0

Multiplayer-Würfelspiel mit gemeinsamer Kartenwerkstatt, individuellen Spielbrettern, gespeicherten Partien und Druckexport..

Installation und Update: [SETUP.md](SETUP.md). Ein bestehendes Projekt mit Version 1.0.2 benötigt nur das Upgrade `supabase/migrations/032_solo_ai_highscores.sql` und die neuen Webdateien. Das erhält alle Daten. Die separate Datei `supabase/RESET_ALL_DATA.sql` ist ausdrücklich destruktiv und ausschließlich für den vollständigen Neustart gedacht.

## Funktionen

- Einzelspiele ohne öffentliche Lobby, konfigurierbarer Rotwürfel-Takt und einfache KI-Gegner (experimentell).
- Automatische KI-Testreihen (experimentell) mit separater Auswertung und Replays.
- Abenteuerwertung und Kartenbestenlisten für menschliche Einzel- und Mehrspielerpartien; Filter nach Gegnerzahl und Rotwürfel-Takt.

- Spielername/Passwort, dauerhafte Sitzungen, Profilbilder, Statistik und Einstellungen. Registrierung zunächst ohne Zugangscode; die Codepflicht bleibt optional verfügbar.
- Kartenbibliothek, Bearbeitungssperre, Autospeicherung, Bilder, portable JSON-Dateien, unveränderbare Veröffentlichungen, Testmodus sowie PNG/PDF-Drucklayout.
- Warteräume, Spielpasswörter, getrennte Spielhilfen, offene/verdeckte Gegnerkarten, Fog of War und Powerups je Partie.
- Servergeprüfte Züge, gemeinsame Erstbelohnungen innerhalb einer Runde, Lebensanzeige, Spezialaufgaben, Pausen und Wiederaufnahme. Warteoptionen öffnen sich nach einer Minute über die Sanduhr am betroffenen Spieler.
- Endwertung mit mehreren Siegern bei Gleichstand, Chronik, Wiederholung und Kosmetikshop. Drei Markierungen und zwei Lagerhintergründe sind sofort kostenlos verfügbar.
- Runen schalten Bosszahlen frei oder verursachen eine einstellbare Anzahl Bosstreffer beim Erreichen. Im Nebel werden Portalpartner erst beim Betreten des Portals enthüllt.
- Anpassbare Animationen sowie getrennte Schalter für Effekte und Hintergrundklang. Spielen funktioniert mobil; Karten bearbeiten ist für den PC ausgelegt.

## Entwickeln und prüfen

Node.js 24 oder neuer:

```sh
npm ci
npm run check
npm test
npx playwright install chromium
npm run test:solo-ai-browser
npx playwright install chromium
npm run test:release-browser
npm run test:release-game-browser
npm run test:rune-hits-browser
npm run test:playtest-browser
npm start
```

Danach `http://localhost:5173` öffnen. SQL- und Browserprüfungen arbeiten mit isolierten Testdatenbanken und verändern keine Live-Daten.

| Pfad | Inhalt |
| --- | --- |
| `web/` | Vollständige statische Webapp; dieser Ordner wird gehostet |
| `web/editor/` | SVG-Karteneditor und Druckdarstellung |
| `web/js/maps/` | Kartenformat, Bilder, Regeln, Vorschauen und Sicherung |
| `web/js/games/` | Spielansicht, Verbindung, Testmodus und Wiederholung |
| `supabase/migrations/` | Migrationsgeschichte und aktuelles Upgrade |
| `supabase/install.sql` | Einrichtung eines leeren Projekts |
| `supabase/functions/` | Serverfunktionen für Profil- und Kartenbilder |
| `tests/` | Regel-, Datenbank-, Upload- und Browserprüfungen |
| `.github/workflows/deploy.yml` | Prüfung und Veröffentlichung von `web/` |

Weitere Referenzen: [ARCHITECTURE.md](ARCHITECTURE.md), [MAP_FORMAT.md](MAP_FORMAT.md), [EDITOR_FORMAT.md](EDITOR_FORMAT.md), [GAME_SPEC.md](GAME_SPEC.md).
