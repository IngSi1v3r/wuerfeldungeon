# Prüfbericht – Würfeldungeon 1.3.0

Ausgangspunkt: das funktionierende Archiv 1.2.0. Die bestehende Datenbank wird mit Migration 036 aktualisiert; Karten, Spieler und Partien werden nicht zurückgesetzt.

| Prüfung | Ergebnis |
| --- | --- |
| Syntax und TypeScript (`npm run check`) | 117 JavaScript-Dateien geprüft; erfolgreich |
| Gesamte Regel-, Datenbank- und Uploadsuite (`npm test`) | 279 bestanden, 0 fehlgeschlagen |
| Neue Artefakt- und Nebelregeln (`tests/artifacts.test.mjs`) | Bestanden, einschließlich zweier magischer Änderungen im selben Zug |
| Kombinierte Upgrade-SQL und Prüfabfrage | 5 × OK in isolierter PostgreSQL-Testdatenbank |
| Browserprüfung (`tests/artifacts-browser.test.mjs`) | In dieser Umgebung nicht ausgeführt: Playwright-Chromium ist hier nicht installiert |

Die Browserprüfung ist als ausführbares Skript enthalten. Nach `npx playwright install chromium` lässt sie sich mit `npm run test:artifacts-browser` auf einem Entwicklungsrechner starten. Sie prüft Handy-Hochformat, Querformat, Powerup-Knöpfe und den verschwindenden Monsterrahmen.

Das produktive Supabase-Projekt und die GitHub-Website wurden nicht verändert. Installationsschritte stehen in SETUP.md.

## GitHub Actions Korrektur

Der erste Workflow mit `ubuntu-latest` landete auf Ubuntu 26.04. Playwright 1.56.1 brach dort bei `npx playwright install --with-deps chromium` ab; die vorherigen Schritte `npm ci`, `npm run check` und `npm test` waren erfolgreich. Der Build-Runner ist daher ausdrücklich auf `ubuntu-24.04` gesetzt. An der Webapp und an der Datenbank wurde für diese Korrektur nichts geändert.
