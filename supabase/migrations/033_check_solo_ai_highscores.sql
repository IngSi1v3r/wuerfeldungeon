-- Rein lesende Kontrolle nach Update 1.1.0. Alle Ergebnisse sollen OK sein.
select 'Version 1.1.0' as pruefung,case when public.app_status()->>'releaseVersion'='1.1.0'
 and exists(select 1 from dungeon_private.schema_migrations where version=16) then 'OK' else 'FEHLT' end as ergebnis
union all select 'Einzelspiel und KI-RPCs',case when public.app_status()->>'soloAIVersion'='1'
 and to_regprocedure('public.create_solo_game(text,uuid,text,jsonb,integer,integer,boolean,uuid)') is not null
 and to_regprocedure('public.perform_ai_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid)') is not null then 'OK' else 'FEHLT' end
union all select 'Private Abenteuerwertungen',case when public.app_status()->>'highscoreVersion'='1'
 and exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='dungeon_private' and c.relname='adventure_scores' and c.relrowsecurity)
 and not has_table_privilege('anon','dungeon_private.adventure_scores','SELECT') then 'OK' else 'FEHLT' end
union all select 'Automatische Ergebnisaufzeichnung',case when exists(select 1 from pg_trigger where tgname='dungeon_capture_adventure_scores' and not tgisinternal) then 'OK' else 'FEHLT' end
union all select 'KI verwendet normale Regeln',case when pg_get_functiondef('public.perform_ai_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid)'::regprocedure) like '%public.play_game_action%'
 and not has_function_privilege('anon','dungeon_private.game_red_free(public.dungeon_games,uuid)','EXECUTE') then 'OK' else 'FEHLT' end
union all select 'Portalsicht erhalten',case when public.app_status()->>'portalFogVersion'='1'
 and pg_get_functiondef('dungeon_private.game_visible_cells(public.dungeon_games,jsonb)'::regprocedure) like '%unopened_portals%' then 'OK' else 'FEHLT' end
union all select 'Gratis-Auswahl erhalten',case when (select count(*) from dungeon_private.marking_catalog where price=0)=3
 and (select count(*) from dungeon_private.cosmetic_catalog where category='campStyle' and price=0)=2 then 'OK' else 'FEHLT' end;
