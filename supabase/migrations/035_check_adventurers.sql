-- Lesende Kontrolle nach Update 1.2.0. Alle Ergebnisse sollen OK sein.
select 'Version 1.2.0' as pruefung,case when public.app_status()->>'releaseVersion'='1.2.0'
 and exists(select 1 from dungeon_private.schema_migrations where version=17) then 'OK' else 'FEHLT' end as ergebnis
union all select 'Abenteurer-Kontext',case when public.app_status()->>'adventurerVersion'='2'
 and pg_get_functiondef('public.get_ai_context(text,uuid)'::regprocedure) like '%opponents%'
 and pg_get_functiondef('public.create_solo_game(text,uuid,text,jsonb,integer,integer,boolean,uuid)'::regprocedure) like '%adventurerCharacter%' then 'OK' else 'FEHLT' end
union all select 'Private Entscheidungsprotokolle',case when exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='dungeon_private' and c.relname='adventurer_decisions' and c.relrowsecurity)
 and not has_table_privilege('anon','dungeon_private.adventurer_decisions','SELECT') then 'OK' else 'FEHLT' end
union all select 'Züge über normale Regelprüfung',case when to_regprocedure('public.perform_adventurer_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid,jsonb)') is not null
 and pg_get_functiondef('public.perform_ai_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid)'::regprocedure) like '%public.play_game_action%' then 'OK' else 'FEHLT' end
union all select 'Rundenverlauf',case when to_regprocedure('public.get_adventurer_journal(text,uuid,bigint,bigint,bigint)') is not null
 and exists(select 1 from pg_trigger where tgname='dungeon_capture_replay' and not tgisinternal) then 'OK' else 'FEHLT' end
union all select 'Freiwilliger Lebensverlust',case when pg_get_functiondef('public.play_game_action(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean)'::regprocedure) like '%GAME_MOVE_AVAILABLE%'
 and pg_get_functiondef('dungeon_private.game_turn_view(public.dungeon_games,uuid)'::regprocedure) like '%ready and not standard_possible%' then 'OK' else 'FEHLT' end
union all select 'Bestenlisten und Portalsicht erhalten',case when public.app_status()->>'highscoreVersion'='1' and public.app_status()->>'portalFogVersion'='1'
 and to_regclass('dungeon_private.adventure_scores') is not null then 'OK' else 'FEHLT' end;
