-- Nur lesen; keine Testspieler oder Testzüge erzeugen.
select public.app_status() as installation;
select version from dungeon_private.schema_migrations order by version;
select has_function_privilege('anon','public.roll_game_dice(text,uuid,integer,uuid)','execute') as roll_rpc_allowed,
 has_function_privilege('anon','public.play_game_turn(text,uuid,integer,bigint,text,text,boolean,uuid)','execute') as turn_rpc_allowed,
 has_table_privilege('anon','public.dungeon_game_player_states','update') as direct_state_write_allowed,
 has_function_privilege('anon','dungeon_private.roll_die()','execute') as direct_die_access_allowed;
select exists(select 1 from pg_trigger where tgname='dungeon_game_signal' and not tgisinternal) as broadcast_trigger_installed,
 exists(select 1 from pg_trigger where tgname='dungeon_choice_clock' and not tgisinternal) as pause_clock_installed;
