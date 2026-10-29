# Würfeldungeon 1.3.0 einspielen

## Update von der funktionierenden Version 1.2.0

1. In Supabase den **SQL Editor** öffnen und `Wuerfeldungeon_SQL_1_3_0.sql` vollständig ausführen. Die Prüfabfrage am Ende soll ausschließlich **OK** ausgeben. Im Projekt stehen die Teile auch getrennt unter `supabase/migrations/036_artifacts_mobile.sql` und `037_check_artifacts_mobile.sql`.
2. Das ZIP entpacken. Den **Inhalt des Ordners `wuerfeldungeon`** in deinen lokalen Repository-Ordner kopieren und gleichnamige Dateien ersetzen. Die Struktur `web/`, `supabase/`, `tests/`, `scripts/` und `.github/` bleibt erhalten. In GitHub Desktop committen und **Push origin** klicken.
3. Auf den erfolgreichen GitHub-Actions-Lauf warten und die Website mit **Strg+F5** neu laden. Unten soll **1.3.0** stehen.

Falls die SQL bereits fünfmal **OK** gemeldet hat und nur GitHub Actions bei der Chromium-Installation fehlgeschlagen ist, reicht es, die korrigierte `.github/workflows/deploy.yml` zu übernehmen und zu pushen. Die Datenbankmigration nicht noch einmal ausführen.

Spieler, Karten, laufende Partien, Guthaben und Bestenlisten bleiben erhalten. Neue Buckets und Edge Functions sind nicht erforderlich. Das SQL kann erneut ausgeführt werden. `RESET_ALL_DATA.sql` gehört ausdrücklich nicht zu diesem Update.

## Neue Spielregeln

- Beim Spielstart kann die Sichtweite des Nebels auf **1, 2 oder 3 verbundene Felder** eingestellt werden. Bestehende Partien bleiben bei 2. Das Fernglas erhöht die gewählte Reichweite um 1; unbesiegte Monster und Bosse blockieren weiterhin den Blick.
- Karten können **Magischer Würfel** und **Zahlenbüchse** als Powerups anbieten. Der magische Würfel ändert zweimal jeweils einen eigenen Würfel um genau 1 zwischen 1 und 6. Beide Änderungen dürfen in derselben Runde erfolgen; andere Spieler behalten den gemeinsamen Originalwurf.
- Die Zahlenbüchse speichert eine verfügbare Zahl anstelle eines Feldzuges. In einer späteren Runde kannst du die Büchse aktivieren und die Zahl einmal statt deiner aktuellen Würfelkombination verwenden. Das Aktivieren kann bis zum abgeschlossenen Feldzug rückgängig gemacht werden. War zum Einpacken nur der rote Würfel geeignet, kostet das eine rote Verwendung.
- Im lokalen Kartentest stehen Vollbild, Sichtweite und die beiden neuen Powerups zum Ausprobieren bereit. Rechtsklicks bleiben freie Testaktionen, die nicht gespeichert werden.

## Neues Supabase-Projekt

In einer **leeren** Datenbank `supabase/install.sql` ausführen, anschließend `037_check_artifacts_mobile.sql`. Projektwerte in `web/js/config.js` und `supabase/config.toml` kontrollieren. Im Browser nur den öffentlichen Publishable Key verwenden.

## Registrierung

Der gemeinsame Zugangscode ist weiterhin optional deaktiviert. Die Codepflicht kann mit `update dungeon_private.app_config set registration_code_required=true where singleton;` eingeschaltet und mit `false` wieder ausgeschaltet werden.
