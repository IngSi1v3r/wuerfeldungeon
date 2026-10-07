# Prüfbericht – Würfeldungeon 1.1.0

Ausgangspunkt: das vollständige, zuletzt funktionierende Archiv 1.0.2. Keine Dateien aus den abgebrochenen Zwischenständen übernommen. Der Ausgangs-Hash ist in RELEASE_PROVENANCE.json dokumentiert.

| Prüfung | Ergebnis |
| --- | --- |
| JavaScript-Syntax und TypeScript (`npm run check`) | 107 JavaScript-Dateien geprüft; TypeScript erfolgreich |
| Gesamte Regel-, Datenbank-, Upload- und Komponentensuite (`npm test`) | 269 bestanden, 0 fehlgeschlagen, 0 übersprungen |
| Davon neue Einzelspiel-/KI-/Wertungsprüfungen | 10 bestanden |
| Release-Oberfläche (`test:release-browser`) | 24 bestanden |
| Vollständige bestehende Mehrspielerpartie (`test:release-game-browser`) | 49 bestanden |
| Gratis-Auswahl, Runeneditor, Testmodus und Runensieg (`test:rune-hits-browser`) | 26 bestanden |
| Portale, Warteoptionen, Shoppreise und Registrierung (`test:playtest-browser`) | 33 bestanden |
| Neue Einzelspiele, autonome KI-Testreihe, Bestenlisten und Replay (`test:solo-ai-browser`) | 18 bestanden |

150 Browserprüfungen ohne JavaScript-Laufzeitfehler. Desktop- und Handyansichten von Bestenliste und KI-Labor wurden zusätzlich visuell geprüft.

## Neue Abdeckung

- Sofortiger Einzelspielstart ohne öffentliche Lobby; Erstellungsanfragen sind idempotent. Fremde Spieler können dem Solo-/KI-Spiel nicht beitreten.
- Der Rotwürfel-Takt verändert nicht die Zuständigkeit zum Würfeln. Zusätzliche Rotverwendungen werden nur bei tatsächlich nötigen roten Aktionen und auch bei wiederholten Anfragen nur einmal verbraucht.
- KI-only-Partien laufen vollständig mit Würfen, legalen Zügen, Schatzkisten, Fackel/Axt, Monster- und Bossangriffen sowie gemeinsamer Schlussrunde. Eine einzelne KI ist als autonomer Solotest ebenfalls zulässig.
- KI-only-Partien haben keine menschlichen Spielersitze, Shopgutschriften, Chronikeinträge oder menschlichen Bestenlisteneinträge. Ergebnisse und Replays bleiben im privaten KI-Labor verfügbar.
- Nebelkontexte enthalten keine verdeckten Bossräume oder Verbindungen. Unzulässige KI-Züge und fremde Hostbefehle werden serverseitig abgewiesen. Pause hält die KI an. Interne Bot-Sitzungen bleiben nach dem Befehl nicht bestehen.
- Browser lässt drei KI-Partien nacheinander automatisch laufen, ohne manuelle Würfe oder Züge. Ergebnisvergleich und Spielerauswahl funktionieren.
- Würfel-Erwartungswerte werden durch vollständige Enumeration überprüft. JavaScript und SQL berechnen denselben Kartenaufwand, Punkte-Erwartungswert und dieselbe Abenteuerwertung.
- Menschliche Einzel- und Mehrspielerpartien werden gewertet. Gegnerfilter, persönlicher Rang, Detailansicht und geteilte Ränge bei gleichen Werten funktionieren. Rundung beeinflusst die Rangfolge nicht.
- Replay unterstützt Vollbild, Normal/Schnell/Sehr schnell und die individuellen Spielermarkierungen.
- Datenbank-Upgrade ist wiederholbar, erhält Ergebnisse und Wertungssnapshots. Die sieben Installationsprüfungen ergeben OK. Die vollständige Neueinrichtung und der bestehende Reset werden ebenfalls geprüft.

## Grenzen dieses Schritts

Die KI verwendet eine Heuristik für den aktuellen Zustand. Mehrere zukünftige Runden, Schwierigkeiten und Persönlichkeiten sind nicht implementiert. Ihre Berechnung und automatische Verarbeitung benötigen einen geöffneten Hostbrowser; mobile Browser können Hintergrundtabs drosseln. KI-Testreihen sind auf zehn Partien begrenzt. Die gemeinsame Wertung ist ein nachvollziehbarer Näherungswert, keine vollständige mathematische Schwierigkeitsbewertung jeder Karte.

Node.js 24.19.0, Playwright 1.56.1/Chromium 141 und isolierte PostgreSQL-Testdatenbanken mit PGlite. Browseraufrufe an Supabase wurden auf diese Testdatenbanken umgeleitet. Das Live-Projekt wurde nicht verändert. Installation und Veröffentlichung erfolgen nach SETUP.md.
