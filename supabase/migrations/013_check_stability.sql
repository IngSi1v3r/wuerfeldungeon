-- Nur prüfen; verändert keine Daten.
select public.app_status();
select
 exists(select 1 from dungeon_private.schema_migrations where version=6) as stability_update_installed,
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='dungeon_games' and column_name='roll_wait_started_at') as roll_wait_clock_available,
 exists(select 1 from pg_trigger where tgname='dungeon_roll_wait_clock' and tgrelid='public.dungeon_games'::regclass and not tgisinternal) as roll_wait_clock_active,
 has_function_privilege('anon','public.resolve_game_wait(text,uuid,integer,uuid,text,uuid)','execute') as wait_rpc_available,
 has_function_privilege('anon','dungeon_private.preserve_roll_wait_clock()','execute') as direct_clock_access_allowed;
-- Erste vier Werte true, letzter Wert false. stabilitySchemaVersion: 1.
