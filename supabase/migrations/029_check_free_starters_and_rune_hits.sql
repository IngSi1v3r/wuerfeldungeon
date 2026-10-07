-- Rein lesende Kontrolle nach dem Update 1.0.1.
select 'Version 1.0.1' as pruefung,case when public.app_status()->>'releaseVersion'='1.0.1'
 and exists(select 1 from dungeon_private.schema_migrations where version=14) then 'OK' else 'FEHLT' end as ergebnis
union all select 'Drei kostenlose Markierungen',case when
 (select count(*) from dungeon_private.marking_catalog where price=0)=3 and
 (select count(*) from dungeon_private.marking_catalog where style in ('cross','pencil','weave') and price=0)=3 then 'OK' else 'FEHLT' end
union all select 'Zwei kostenlose Hintergründe',case when
 (select count(*) from dungeon_private.cosmetic_catalog where category='campStyle' and price=0)=2 and
 (select count(*) from dungeon_private.cosmetic_catalog where category='campStyle' and value in ('forest','dawn') and price=0)=2 then 'OK' else 'FEHLT' end
union all select 'Runentreffer verfügbar',case when public.app_status()->>'runeHitsVersion'='1'
 and to_regprocedure('dungeon_private.damage_game_enemy(public.dungeon_games,uuid,jsonb,public.dungeon_map_cells,integer,text)') is not null then 'OK' else 'FEHLT' end
union all select 'Gemeinsame Trefferlogik eingebunden',case when
 pg_get_functiondef('public.play_game_action(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean)'::regprocedure) like '%damage_game_enemy%'
 and pg_get_functiondef('dungeon_private.reach_game_cell(public.dungeon_games,uuid,jsonb,public.dungeon_map_cells)'::regprocedure) like '%bossHits%' then 'OK' else 'FEHLT' end;
