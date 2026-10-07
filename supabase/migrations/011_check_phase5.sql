-- Nur prüfen, verändert nichts. Ergebnis 1: alle Versionen bis einschließlich 5.
select version,installed_at from dungeon_private.schema_migrations order by version;
select public.app_status();
select
 to_regprocedure('public.play_game_action(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean)') is not null as complete_rules_available,
 to_regprocedure('public.choose_game_powerup(text,uuid,text,bigint,text,uuid)') is not null as powerups_available,
 to_regprocedure('public.get_torch_options(text,uuid,integer,bigint)') is not null as torch_available,
 has_table_privilege('anon','public.dungeon_game_task_claims','insert') as direct_task_write_allowed,
 has_function_privilege('anon','dungeon_private.finalize_game(uuid)','execute') as direct_finish_allowed;
-- Erste drei Werte true, letzte zwei false.
