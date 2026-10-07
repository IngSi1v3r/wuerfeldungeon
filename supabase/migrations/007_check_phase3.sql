-- Rein lesender Installationscheck. Keine Spieler, Karten oder Spiele ändern.
select public.app_status() as installation;
select version from dungeon_private.schema_migrations order by version;
select
 has_function_privilege('anon','public.create_game(text,uuid,text,jsonb,text,uuid)','execute') as game_rpc_allowed,
 has_table_privilege('anon','public.dungeon_games','select') as direct_game_read_allowed,
 has_table_privilege('anon','dungeon_private.game_passwords','select') as password_read_allowed;
select exists(select 1 from pg_trigger where tgname='dungeon_game_signal' and not tgisinternal) as broadcast_trigger_installed;
select to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null as database_broadcast_available;
