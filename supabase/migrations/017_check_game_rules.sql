-- Nach 016_game_rules.sql ausführen. Alle Zeilen sollen OK zeigen.
select 'Neue Online-Regeln' as pruefung,case when public.app_status()->>'gameFeaturesVersion'='1' then 'OK' else 'FEHLT' end as ergebnis
union all select 'Kartenversion 7 spielbar',case when pg_get_functiondef('public.list_game_maps(text)'::regprocedure) not like '%v.definition_version=1%' then 'OK' else 'FEHLT' end
union all select 'Zufallszahlen und Nebel',case when to_regprocedure('dungeon_private.game_visible_cells(public.dungeon_games,jsonb)') is not null and exists(select 1 from pg_trigger where tgname='dungeon_game_round_cells' and not tgisinternal) then 'OK' else 'FEHLT' end
union all select 'Fallen gespeichert',case when to_regclass('public.dungeon_game_trap_claims') is not null and not has_table_privilege('anon','public.dungeon_game_trap_claims','select') then 'OK' else 'FEHLT' end
union all select 'Bestehende Partien erhalten',case when to_regprocedure('dungeon_private.play_game_action_v5(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean)') is not null then 'OK' else 'FEHLT' end
union all select 'Migration registriert',case when exists(select 1 from dungeon_private.schema_migrations where version=8) then 'OK' else 'FEHLT' end;
