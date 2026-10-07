-- Nach 018_marking_shop.sql: alle Zeilen sollen OK zeigen.
select 'Markierungs-Shop' pruefung,case when public.app_status()->>'shopSchemaVersion'='1' then 'OK' else 'FEHLT' end ergebnis
union all select 'Sieben Markierungen',case when (select count(*) from dungeon_private.marking_catalog)=7 then 'OK' else 'FEHLT' end
union all select 'Automatische Gutschrift',case when exists(select 1 from pg_trigger where tgname='dungeon_marking_game_credit' and not tgisinternal) then 'OK' else 'FEHLT' end
union all select 'Vergangene Partien berücksichtigt',case when not exists(select 1 from public.dungeon_game_results r join public.dungeon_games g on g.id=r.game_id where g.status='finished' and not exists(select 1 from dungeon_private.marking_credits c where c.player_id=r.player_id and c.game_id=r.game_id)) then 'OK' else 'FEHLT' end
union all select 'Guthaben nicht negativ',case when not exists(select 1 from public.dungeon_players p where (dungeon_private.cosmetics_json(p.id)->>'balance')::bigint<0) then 'OK' else 'FEHLT' end
union all select 'Private Shopdaten',case when not has_table_privilege('anon','dungeon_private.marking_credits','select') and not has_table_privilege('anon','dungeon_private.marking_purchases','insert') then 'OK' else 'FEHLT' end
union all select 'Migration registriert',case when exists(select 1 from dungeon_private.schema_migrations where version=9) then 'OK' else 'FEHLT' end;
