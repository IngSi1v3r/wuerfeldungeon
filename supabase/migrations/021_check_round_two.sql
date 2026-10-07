-- Nach 020_round_two.sql: jede Zeile soll OK ergeben.
select 'Migration 0.10.0' as pruefung,case when exists(select 1 from dungeon_private.schema_migrations where version=10) then 'OK' else 'FEHLT' end as ergebnis
union all select 'Neue RPCs',case when to_regprocedure('public.use_game_horn(text,uuid,bigint,uuid)') is not null and to_regprocedure('public.get_game_replay(text,uuid)') is not null then 'OK' else 'FEHLT' end
union all select 'Private Replaytabelle',case when to_regclass('dungeon_private.replay_frames') is not null and not has_table_privilege('anon','dungeon_private.replay_frames','select') then 'OK' else 'PRUEFEN' end
union all select 'Replay-Aufzeichnung',case when exists(select 1 from pg_trigger where tgname='dungeon_capture_replay' and not tgisinternal) then 'OK' else 'FEHLT' end
union all select 'Markierungen und Preise',case when (select count(*) from dungeon_private.marking_catalog)=10 and (select price from dungeon_private.marking_catalog where style='pencil')=10 then 'OK' else 'PRUEFEN' end
union all select 'App-Status',case when public.app_status()->'roundTwoVersion'='1'::jsonb then 'OK' else 'FEHLT' end;
