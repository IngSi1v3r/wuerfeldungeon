-- Rein lesende Kontrolle für Würfeldungeon 1.0.0.
select 'Version 1.0.0' as pruefung,
 case when public.app_status()->>'releaseVersion'='1.0.0'
  and exists(select 1 from dungeon_private.schema_migrations where version=13) then 'OK' else 'FEHLT' end as ergebnis
union all
select 'Registrierungsoption vorhanden',case when public.app_status() ? 'registrationCodeRequired' then 'OK' else 'FEHLT' end
union all
select 'Shoppreise',case when
 (select price from dungeon_private.marking_catalog where style='stars')=20 and
 (select price from dungeon_private.marking_catalog where style='weave')=8 and
 (select price from dungeon_private.cosmetic_catalog where category='cupStyle' and value='runic')=30 then 'OK' else 'ABWEICHEND' end
union all
select 'Sonderfeld als Startfeld',case when pg_get_functiondef('dungeon_private.cell_reachable(uuid,text,jsonb)'::regprocedure) like '%kind not in%' then 'OK' else 'FEHLT' end
union all
select 'Nebel ab Sonder-Startfeldern',case when pg_get_functiondef('dungeon_private.game_visible_cells(public.dungeon_games,jsonb)'::regprocedure) like '%kind not in%' then 'OK' else 'FEHLT' end;
