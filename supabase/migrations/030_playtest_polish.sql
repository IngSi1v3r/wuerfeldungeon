-- Würfeldungeon 1.0.2 · auf Version 1.0.1 aufbauen.
-- Erhält Spieler, Karten, Partien, Guthaben, Gratis-Auswahl und bestehende Käufe.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte das eingerichtete Würfeldungeon-Projekt öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=14) then
  raise exception 'Bitte zuerst Version 1.0.1 (028_free_starters_and_rune_hits.sql) installieren.';
 end if;
end$$;
lock table dungeon_private.schema_migrations in exclusive mode;

-- Preisänderung nur einmal anwenden; frühere Käufe behalten ihren Preis.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=15) then
  update dungeon_private.marking_catalog set price=round(price*1.5)::integer where price>0;
  update dungeon_private.cosmetic_catalog set price=round(price*1.5)::integer where price>0;
 end if;
end$$;

create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive unopened_portals(cell_a,cell_b) as (
  select least(pair->>0,pair->>1),greatest(pair->>0,pair->>1)
  from public.dungeon_map_versions version
   cross join lateral jsonb_array_elements(coalesce(version.rules->'portalPairs','[]')) pair
  where version.id=g.map_version_id
   and not dungeon_private.has_reached(s,pair->>0) and not dungeon_private.has_reached(s,pair->>1)
   -- Auch zwei Portale können einen normalen, offenen Wanddurchgang teilen.
   and not exists(
    select 1 from public.dungeon_map_cells a join public.dungeon_map_cells b on b.version_id=a.version_id
    where a.version_id=g.map_version_id and a.cell_id=pair->>0 and b.cell_id=pair->>1
     and (
      (((a.definition->>'x')::int+(a.definition->>'w')::int=(b.definition->>'x')::int
         or (b.definition->>'x')::int+(b.definition->>'w')::int=(a.definition->>'x')::int)
       and least((a.definition->>'y')::int+(a.definition->>'h')::int,(b.definition->>'y')::int+(b.definition->>'h')::int)-greatest((a.definition->>'y')::int,(b.definition->>'y')::int)>=1)
      or
      (((a.definition->>'y')::int+(a.definition->>'h')::int=(b.definition->>'y')::int
         or (b.definition->>'y')::int+(b.definition->>'h')::int=(a.definition->>'y')::int)
       and least((a.definition->>'x')::int+(a.definition->>'w')::int,(b.definition->>'x')::int+(b.definition->>'w')::int)-greatest((a.definition->>'x')::int,(b.definition->>'x')::int)>=1)
     )
     and coalesce(version.document->'closedDoors'->(case when a.cell_id::bigint<b.cell_id::bigint then a.cell_id||':'||b.cell_id else b.cell_id||':'||a.cell_id end),'false'::jsonb)<>'true'::jsonb
   )
 ), visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind not in ('monster','boss','miniboss') and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where not exists(select 1 from unopened_portals p where p.cell_a=e.cell_a and p.cell_b=e.cell_b)
   and (dungeon_private.has_reached(s,v.cell_id) or not exists(select 1 from public.dungeon_map_cells blocker where blocker.version_id=g.map_version_id and blocker.cell_id=v.cell_id and blocker.kind in ('monster','boss','miniboss')))
   and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'releaseVersion','1.0.2','runeHitsVersion',1,'starterCosmeticsVersion',1,'portalFogVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;

revoke all on function dungeon_private.game_visible_cells(public.dungeon_games,jsonb) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(15) on conflict do nothing;
commit;

