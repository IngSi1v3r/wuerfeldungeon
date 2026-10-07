# Spielregeln · Würfeldungeon

Alle besitzen dieselbe Karte und ihren eigenen Fortschritt. Ziel ist, Wege zu erkunden, Schätze zu sammeln und Monster/Bosse zu besiegen. Bonusaufgaben sind optional und lösen kein Spielende aus.

## Runden

Reihum werden drei weiße und ein roter Würfel geworfen. Alle wählen gleichzeitig einen Zug. Anforderungen entstehen aus zwei Würfeln. Der Werfer darf Rot frei kombinieren; andere haben zunächst drei freiwillige rote Verwendungen. Beliebiger Pasch erfüllt `doubles`; bestimmter Pasch benötigt die angegebene Summe.

Ein passendes Startfeld ist jederzeit erreichbar. Andere Räume benötigen einen offenen Durchgang zu einem bereits erreichten Feld. Monster werden mit freigeschalteten Zahlen angegriffen und nach allen Treffern durchquerbar. Graue Nachbarfelder und entfernte Runen schalten Angriffe frei.

Nach allen Zügen einschließlich Truhenauswahl folgt die nächste Runde. Der Host kann pausieren. Nach einer Minute erscheint am ausstehenden Spieler eine kleine Sanduhr; ein Klick öffnet dessen Warteoptionen. „Weiter warten“ schließt diese nur, die Sanduhr bleibt jederzeit erneut anklickbar. Wer keinen normalen Zug hat, kann einen verfügbaren Sonderzug wählen oder ein Leben verlieren; ohne irgendeinen legalen Zug wird ein Leben automatisch abgezogen.

## Sonderfelder

Diamanten zählen drei Punkte, Goldsäcke zwei, Münzen einen. Portale aktivieren beide Partner und verbinden Wege. Verrückte Felder wählen jede Runde gemeinsam aus ihrem Kartenpool.

Fallen sind für alle Spieler der ersten Aktivierungsrunde ungefährlich. Ab der nächsten Runde kosten sie eingestellte Leben oder Diamanten. Diamanten dürfen negativ werden.

## Powerups

Jede Truhe gewährt einen noch nicht gewählten Poweruptyp. Sein Vorrat kann anschließend verbraucht werden. Der Pool ist bei der Partieerstellung und im Warteraum anpassbar.

| Powerup | Wirkung |
| --- | --- |
| Extraleben | Drei zusätzliche Kästchen ohne Abzug und ein Diamant |
| Roter Würfel | Drei zusätzliche rote Verwendungen |
| Fackel | Zweimal Zwischenraum ohne passende Zahl erreichen und danach dessen passendes Nachbarfeld spielen/angreifen; kein Gegner als Zwischenraum |
| Axt des Doppelschlags | Zweimal einen Angriff als zwei Treffer zählen |
| Fernglas | Dauerhaft drei statt zwei Felder Sicht |
| Das Horn des Nebeljägers | Einmal alle Monster/Bosse zehn Sekunden zeigen, ohne Wege aufzudecken |

Rot lässt sich mit Fackel oder Axt kombinieren. Fackel und Axt sind in einem Zug nicht kombinierbar.

## Sicht und Wertung

Fog zeigt Startfelder und zwei Schritte entlang offener Verbindungen. Erreichte Bereiche erweitern die Sicht. Unbesiegte Monster/Bosse stoppen den Blick dahinter, auch mit Fernglas. Bonusaufgaben blockieren Sicht nicht. Hintergrundfreigaben verraten keine verdeckten Räume. Gegnerkarten sowie Würfelsummen und Feldhinweise sind getrennte Optionen.

Alle Abschlüsse in der ersten Abschlussrunde erhalten die Erstbelohnung; danach gilt die zweite. Aufgaben können Teilmengen verlangen. Eine Gegnerkombination hat unabhängig von einzelnen Erstbesiegern einen eigenen Wettlauf.

Eine Trefferrune verursacht einmal beim Erreichen die im Editor festgelegte Anzahl Treffer auf den eigenen Boss. Sie funktioniert auch als Fackel-Zwischenraum. Sie schaltet selbst keine Bosszahl frei. Ein dadurch besiegter Boss wird wie bei einem regulären Angriff belohnt und kann die Endrunde auslösen. Treffer über die Lebensanzahl hinaus werden nicht gezählt.

Bosse gewähren die reguläre Belohnung nur Erstbesiegern. Andere Spieler erhalten am Ende einen Diamanten je vollständiger Dreiergruppe von Treffern. Erstbesieger erhalten diesen Zusatz nicht.

Die Lebensabzüge nach 1–10 Verlusten sind `0, 0, −1, −2, −4, −6, −9, −12, −16, −20`; der elfte bedeutet Ausscheiden. Extraleben fügt drei zusätzliche verlustfreie Kästchen hinzu.

Sobald jemand alle Monster/Bosse besiegt hat, wird die laufende Runde fertig gespielt und danach gewertet. Höchste Gesamtpunkte gewinnen; Gleichstand bedeutet mehrere Sieger. Ergebnisse/Statistiken/Shopguthaben werden serverseitig gespeichert. Testpartien im Editor bleiben vollständig davon getrennt.

Unter Fog of War folgt die Sicht normalen offenen Durchgängen. Ein noch nicht erreichtes Portal erlaubt keinen Blick auf seinen entfernten Partner. Beim Betreten werden beide Portale auf dem eigenen Brett erreicht und der Ausgang sichtbar. Zwei Portalpartner mit einem direkten offenen Wanddurchgang können über diesen schon vorher gesehen werden. Monster- und Bossblockade, Fernglas und temporärer Monsterblick gelten unverändert.


## Einzelspiele und experimentelle KI (1.1.0)

Ein Einzelspiel hat genau einen menschlichen Spieler und optional bis zu sieben KI-Gegner. Kein öffentlicher Warteraum; Würfe sind weiterhin gemeinsam und alle Teilnehmer haben ihren eigenen Spielplan. Der kostenlose Rotwürfel-Takt gilt je Teilnehmer, um dessen Sitzposition versetzt. Verwendungen außerhalb dieses Takts kosten eine normale Sonderwürfel-Ladung. Im Standard-Takt (Teilnehmerzahl) entspricht dies der bisherigen Rotation.

Die KI entscheidet ausschließlich anhand der aktuellen erlaubten Aktionen und ihres sichtbaren Bretts. Normale Züge, Fackel, Axt, Rotwürfel, Lebensverlust und Truhenwahl werden über die unveränderten serverseitigen Regeln kontrolliert. Es gibt zunächst eine Heuristik ohne Schwierigkeiten, Persönlichkeiten oder mehrstufige Vorausplanung.

Reine KI-Testpartien haben nur KI-Sitze. Der Host beobachtet und steuert die automatische Verarbeitung. Solche Tests werden getrennt ausgewertet; sie zählen nicht für menschliche Profile, Shop, Chronik oder Bestenlisten.

Abenteuerwertung: siehe die vollständige Formel und Definition der Benchmarks in SETUP.md. Die Punktwertung entscheidet weiterhin Siege und Gleichstände.
