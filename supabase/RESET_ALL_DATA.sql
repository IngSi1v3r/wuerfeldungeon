-- WÜRFELDUNGEON: ALLE SPIELDATEN LÖSCHEN.
-- Löscht sämtliche Spieler einschließlich Passwörtern/Sitzungen, Karten,
-- Partien, Ergebnisse, Replays, Shopguthaben, Käufe und Bildreferenzen.
-- Schema, Funktionen, Migrationen, Shopkatalog, Konfiguration und der
-- gespeicherte Registrierungscode bleiben erhalten.
-- Nur für den ausdrücklich gewünschten vollständigen Neustart ausführen.
-- Vorher die Buckets "avatars" und "map-assets" in Supabase Storage leeren,
-- wenn auch die Bilddateien entfernt werden sollen. SQL löscht keine Dateien.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Dies ist keine eingerichtete Würfeldungeon-Datenbank.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=13) then
  raise exception 'Bitte zuerst das Datenbank-Update auf 1.0.0 installieren.';
 end if;
end$$;

-- Alle Spieldatentabellen hängen direkt oder indirekt von Spielern ab.
-- TRUNCATE entfernt auch veröffentlichte Karten und setzt Ereignis-IDs zurück.
truncate table public.dungeon_players, dungeon_private.auth_attempts
 restart identity cascade;
commit;

select 'Spieler' as bereich,count(*) as verbleibend from public.dungeon_players
union all select 'Karten',count(*) from public.dungeon_maps
union all select 'Kartenveröffentlichungen',count(*) from public.dungeon_map_versions
union all select 'Partien',count(*) from public.dungeon_games
union all select 'Ergebnisse',count(*) from public.dungeon_game_results
union all select 'Replays',count(*) from dungeon_private.replay_frames
union all select 'Bildreferenzen',count(*) from dungeon_private.assets
union all select 'Sitzungen',count(*) from dungeon_private.player_sessions;
