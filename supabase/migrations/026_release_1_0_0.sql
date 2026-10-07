-- Würfeldungeon 1.0.0: Upgrade der eingerichteten Version 0.10.2.
-- Erhält alle Spieler, Karten, Spiele, Guthaben und bisherigen Käufe.
-- Wiederholbar. Die separate Reset-Datei ist NICHT Bestandteil dieses Updates.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte die eingerichtete Würfeldungeon-Datenbank öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=12) then
  raise exception 'Dieses Upgrade benötigt die vollständig installierte Version 0.10.2.';
 end if;
end$$;
alter table dungeon_private.app_config add column if not exists registration_code_required boolean not null default false;
-- Nur die erstmalige Installation schaltet die Codepflicht ab. Ein später
-- bewusst reaktivierter Code wird bei erneutem Ausführen nicht ausgeschaltet.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=13) then
  update dungeon_private.app_config set registration_code_required=false,updated_at=now() where singleton;
  update dungeon_private.marking_catalog set position=position+100;
  update dungeon_private.marking_catalog set
   price=case style when 'cross' then 0 when 'pencil' then 5 when 'weave' then 8 when 'waves' then 10 when 'spiral' then 10 when 'solid' then 15 when 'seal' then 18 when 'stars' then 20 when 'runes' then 25 when 'claws' then 30 else price end,
   position=case style when 'cross' then 0 when 'pencil' then 1 when 'weave' then 2 when 'waves' then 3 when 'spiral' then 4 when 'solid' then 5 when 'seal' then 6 when 'stars' then 7 when 'runes' then 8 when 'claws' then 9 else position end;
  update dungeon_private.cosmetic_catalog set price=price/2;
 end if;
end$$;
create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>6 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','doubleSum','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if jsonb_typeof(r->'start') is distinct from 'boolean' or jsonb_typeof(r->'dimmed') is distinct from 'boolean' then return false; end if;
  if r->>'type' in ('monster','boss') and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
  if r->>'type'='doubleSum' and r->'number' is not null and r->'number'<>'null'::jsonb and (not dungeon_private.json_int(r->'number',2,12) or (r->>'number')::int%2<>0) then return false; end if;
  if r->>'type'='trap' and (r->>'trapKind' is null or r->>'trapKind' not in ('diamonds','life') or not dungeon_private.json_int(r->'trapCost',1,99)) then return false; end if;
  if r->>'type'='crazy' then
   if jsonb_typeof(r->'requirements') is distinct from 'array' or jsonb_array_length(r->'requirements')>12 then return false; end if;
   values_seen:='{}';
   for a in select value from jsonb_array_elements(r->'requirements') loop
    if not dungeon_private.dice_number(a) or a::text=any(values_seen) then return false; end if; values_seen:=array_append(values_seen,a::text);
   end loop;
  end if;
  if r->>'type' in ('monster','boss','bonus') then
   if not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
   if r->'defeatedImageLayout' is not null and r->'defeatedImageLayout'<>'null'::jsonb then
    enemy:=r||jsonb_build_object('image',r->'defeatedImage','imageLayout',r->'defeatedImageLayout','type','miniboss');
    if not dungeon_private.map_document_valid_v1(shadow||jsonb_build_object('rooms',jsonb_build_array(enemy))) then return false; end if;
   end if;
  end if;
  -- Geometry/image compatibility is checked separately from the independent field flags.
  r:=r||jsonb_build_object('start',false,'dimmed',false,'type',case r->>'type' when 'doubleSum' then 'normal' when 'rune' then 'special' when 'bonus' then 'miniboss' when 'trap' then 'normal' when 'portal' then 'normal' when 'crazy' then 'normal' when 'goldSack' then 'diamond' when 'goldCoin' then 'diamond' else r->>'type' end);
  shadow:=jsonb_set(shadow,'{rooms}',shadow->'rooms'||jsonb_build_array(r));
 end loop;
 if not dungeon_private.map_document_valid_v1(shadow) then return false; end if;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if jsonb_typeof(g) is distinct from 'object' or g->>'type' is null or g->>'type' not in ('none','allType','reachFields','defeatEnemies','firstEnemies','connect','collectDiamonds')
   or jsonb_typeof(g->'cellIds') is distinct from 'array' or jsonb_array_length(g->'cellIds')>3000 or not dungeon_private.json_int(g->'diamonds',1,999)
   or not dungeon_private.json_int(g->'reward'->'first',0,999) or not dungeon_private.json_int(g->'reward'->'later',0,999) then return false; end if;
  if g->>'type'='allType' and (g->>'fieldType' is null or g->>'fieldType' not in ('normal','doubleSum','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin')) then return false; end if;
  if g->'requiredCount' is not null and g->'requiredCount'<>'null'::jsonb then
   if g->>'type' not in ('allType','reachFields','defeatEnemies','firstEnemies') or not dungeon_private.json_int(g->'requiredCount',1,3000) then return false; end if;
  end if;
  values_seen:='{}';for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not dungeon_private.json_int(a,1,9007199254740990) or a::text=any(values_seen) then return false; end if;values_seen:=array_append(values_seen,a::text);
  end loop;
 end loop;
 return true;
exception when others then return false;
end;
$$;

create or replace function dungeon_private.map_compile_v2(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare target jsonb; source jsonb; number_value jsonb; list jsonb; cells jsonb:='[]'; links jsonb:='[]'; goals jsonb:='[]'; g jsonb; pairs jsonb;
begin
 if d->>'format'<>'dungeon-layout-v7' then return d; end if;
 for target in select value from jsonb_array_elements(d->'rooms') loop
  if target->>'type' in ('monster','boss') then
   list:=target->'attacks';
   for source in select value from jsonb_array_elements(d->'rooms') s where s->>'type' not in ('monster','boss') and
    ((s->>'type'='rune' and target->>'type'='boss') or (s->'dimmed'='true'::jsonb and exists
     (select 1 from dungeon_private.map_edges(d) e where (e.cell_a=s->>'id' and e.cell_b=target->>'id') or (e.cell_b=s->>'id' and e.cell_a=target->>'id')))) loop
    for number_value in select distinct value from jsonb_array_elements(case source->>'type'
     when 'crazy' then coalesce(source->'requirements','[]')
     when 'bonus' then (select coalesce(jsonb_agg(a->'number'),'[]') from jsonb_array_elements(source->'attacks') a)
     else jsonb_build_array(source->'number') end) n where value is not null and value<>'null'::jsonb loop
     select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a where a->'number'<>number_value;
     list:=list||jsonb_build_array(jsonb_build_object('number',number_value,'state','locked'));
     links:=links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','number',number_value));
    end loop;
   end loop;
   select coalesce(jsonb_agg(a order by case when a->>'number'='doubles' then 13 else (a->>'number')::int end),'[]') into list from jsonb_array_elements(list) a;
   target:=jsonb_set(target,'{attacks}',list);
  end if;
  cells:=cells||jsonb_build_array(target);
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='allType' then g:=jsonb_set(g,'{cellIds}',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(cells) r where r->>'type'=g->>'fieldType')); end if;
  goals:=goals||jsonb_build_array(g);
 end loop;
 select coalesce(jsonb_agg(jsonb_build_array(a->'id',b->'id') order by (a->>'id')::bigint,(b->>'id')::bigint),'[]') into pairs
  from jsonb_array_elements(cells) a,jsonb_array_elements(cells) b where a->>'type'='portal' and b->>'type'='portal' and a->'number'=b->'number' and a->'number'<>'null'::jsonb and (a->>'id')::bigint<(b->>'id')::bigint;
 return d||jsonb_build_object('rooms',cells,'rules',d->'rules'||jsonb_build_object('unlocks',links,'goals',goals,'portalPairs',pairs));
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Feld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->'dimmed'='true'::jsonb and (not exists(select 1 from dungeon_private.map_edges(d) e join jsonb_array_elements(d->'rooms') target on target->>'id'=case when e.cell_a=r->>'id' then e.cell_b else e.cell_a end where r->>'id' in (e.cell_a,e.cell_b) and target->>'type' in ('monster','boss')) or not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id')) then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster oder einen Boss angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  if g->'requiredCount' is not null and g->'requiredCount'<>'null'::jsonb and (g->>'requiredCount')::int>jsonb_array_length(g->'cellIds') then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: %s benötigte Felder, aber nur %s Zielfelder vorhanden.',g->>'requiredCount',jsonb_array_length(g->'cellIds')))); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is not null and bg<>'null'::jsonb and exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

create or replace function dungeon_private.cell_reachable(p_version uuid,p_cell text,s jsonb)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.dungeon_map_cells c where c.version_id=p_version and c.cell_id=p_cell
  and not dungeon_private.has_reached(s,p_cell) and (
   (c.kind not in ('monster','boss','miniboss') and c.definition->'start'='true'::jsonb)
   or exists(select 1 from public.dungeon_map_connections e where e.version_id=p_version and
    ((e.cell_a=p_cell and dungeon_private.has_reached(s,e.cell_b)) or (e.cell_b=p_cell and dungeon_private.has_reached(s,e.cell_a))))));
$$;

create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind not in ('monster','boss','miniboss') and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where (dungeon_private.has_reached(s,v.cell_id) or not exists(select 1 from public.dungeon_map_cells blocker where blocker.version_id=g.map_version_id and blocker.cell_id=v.cell_id and blocker.kind in ('monster','boss','miniboss')))
  and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;

create or replace function public.register_player(
  p_username text, p_display_name text, p_password text, p_access_code text,
  p_device_label text default 'Browser'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare user_name text := lower(btrim(p_username)); display text := btrim(p_display_name);
  config dungeon_private.app_config%rowtype; player_id uuid; session_data jsonb;
begin
  if not dungeon_private.allow_auth_attempt('register','') then
    return jsonb_build_object('ok',false,'error','RATE_LIMIT');
  end if;
  select * into config from dungeon_private.app_config where singleton;
  if not config.registration_enabled or (config.registration_code_required and config.registration_code_hash is null) then
    return jsonb_build_object('ok',false,'error','REGISTRATION_CLOSED');
  end if;
  if config.registration_code_required and (p_access_code is null or octet_length(p_access_code) > 72
    or not dungeon_private.password_matches(p_access_code, config.registration_code_hash)) then
    return jsonb_build_object('ok',false,'error','ACCESS_CODE_INVALID');
  end if;
  if user_name is null or user_name !~ '^[a-z0-9._-]{3,32}$' then
    return jsonb_build_object('ok',false,'error','USERNAME_INVALID');
  end if;
  if display is null or char_length(display) not between 1 and 40 then
    return jsonb_build_object('ok',false,'error','DISPLAY_NAME_INVALID');
  end if;
  if p_password is null or char_length(p_password) < 6 or octet_length(p_password) > 72 then
    return jsonb_build_object('ok',false,'error','PASSWORD_INVALID');
  end if;
  begin
    insert into public.dungeon_players (username, display_name) values (user_name, display)
      returning id into player_id;
  exception when unique_violation then
    return jsonb_build_object('ok',false,'error','USERNAME_TAKEN');
  end;
  insert into dungeon_private.player_credentials (player_id, password_hash)
    values (player_id, dungeon_private.hash_password(p_password));
  session_data := dungeon_private.issue_session(player_id, p_device_label);
  return jsonb_build_object('ok',true,'session',session_data,
    'profile',dungeon_private.profile_json(player_id));
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'releaseVersion','1.0.0','releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;
insert into dungeon_private.schema_migrations(version) values(13) on conflict do nothing;
commit;
