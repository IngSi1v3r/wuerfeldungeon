-- Rein lesende Kontrolle nach dem Update 1.0.2.
select 'Version 1.0.2' as pruefung,case when public.app_status()->>'releaseVersion'='1.0.2'
 and exists(select 1 from dungeon_private.schema_migrations where version=15) then 'OK' else 'FEHLT' end as ergebnis
union all select 'Portalsicht im Nebel',case when public.app_status()->>'portalFogVersion'='1'
 and pg_get_functiondef('dungeon_private.game_visible_cells(public.dungeon_games,jsonb)'::regprocedure) like '%unopened_portals%' then 'OK' else 'FEHLT' end
union all select 'Gratis-Auswahl erhalten',case when
 (select count(*) from dungeon_private.marking_catalog where price=0)=3
 and (select count(*) from dungeon_private.cosmetic_catalog where category='campStyle' and price=0)=2 then 'OK' else 'FEHLT' end
union all select 'Neue Markierungspreise',case when
 (select count(*) from dungeon_private.marking_catalog where
 (style,price) in (('cross',0),('pencil',0),('weave',0),('waves',15),('spiral',15),('solid',23),('seal',27),('stars',30),('runes',38),('claws',45)))=10 then 'OK' else 'FEHLT' end
union all select 'Neue Kosmetikpreise',case when
 (select count(*) from dungeon_private.cosmetic_catalog where
 (category,value,price) in (('diceStyle','ivory',0),('diceStyle','forest',23),('diceStyle','midnight',30),('diceStyle','amber',38),
 ('cupStyle','leather',0),('cupStyle','wood',30),('cupStyle','runic',45),('campStyle','forest',0),('campStyle','dawn',0),('campStyle','moon',45),('campStyle','autumn',38)))=11 then 'OK' else 'FEHLT' end;

