-- Lesende Kontrolle nach dem Update von 1.2.0 auf 1.3.0.
select 'Version 1.3.0' as pruefung, case when public.app_status()->>'releaseVersion'='1.3.0' and public.app_status()->>'artifactVersion'='1' then 'OK' else 'FEHLT' end as ergebnis
union all select 'Migration 18',case when exists(select 1 from dungeon_private.schema_migrations where version=18) then 'OK' else 'FEHLT' end
union all select 'Magischer Würfel',case when to_regprocedure('public.use_game_magic(text,uuid,bigint,integer,integer,uuid)') is not null then 'OK' else 'FEHLT' end
union all select 'Zahlenbüchse',case when to_regprocedure('public.store_game_number(text,uuid,bigint,text,boolean,uuid)') is not null and to_regprocedure('public.toggle_stored_number(text,uuid,bigint,boolean,uuid)') is not null then 'OK' else 'FEHLT' end
union all select 'Sichtweite',case when pg_get_functiondef('dungeon_private.game_visible_cells(public.dungeon_games,jsonb)'::regprocedure) like '%fogRange%' then 'OK' else 'FEHLT' end;
