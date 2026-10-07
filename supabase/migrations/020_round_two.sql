-- Würfeldungeon 0.10.0: sauber auf dem beigefügten Stand 0.9.0 aufgebaut.
-- Ein einziges Update; wiederholbar, keine bestehenden Spielstände umschreiben.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Dies ist nicht die eingerichtete Würfeldungeon-Datenbank. Bitte das Projekt mit Version 0.9.0 öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=9) then
  raise exception 'Dieses Update benötigt den funktionierenden Stand 0.9.0 (018_marking_shop.sql).';
 end if;
end$$;
-- Nur beim ersten Einspielen Preise verdoppeln, bestehende Käufe bewahren.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=10) then
  update dungeon_private.marking_catalog set price=price*2;
 end if;
end$$;
insert into dungeon_private.marking_catalog(style,label,price,position) values
 ('spiral','Spirale',70,7),('weave','Schraffur',80,8),('seal','Abenteurersiegel',90,9)
 on conflict(style) do nothing;


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
  if r->>'type' is null or r->>'type' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if r->>'type'<>'normal' and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
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
  r:=r||jsonb_build_object('type',case r->>'type' when 'rune' then 'special' when 'bonus' then 'miniboss' when 'trap' then 'normal' when 'portal' then 'normal' when 'crazy' then 'normal' when 'goldSack' then 'diamond' when 'goldCoin' then 'diamond' else r->>'type' end);
  shadow:=jsonb_set(shadow,'{rooms}',shadow->'rooms'||jsonb_build_array(r));
 end loop;
 if not dungeon_private.map_document_valid_v1(shadow) then return false; end if;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if jsonb_typeof(g) is distinct from 'object' or g->>'type' is null or g->>'type' not in ('none','allType','reachFields','defeatEnemies','firstEnemies','connect','collectDiamonds')
   or jsonb_typeof(g->'cellIds') is distinct from 'array' or jsonb_array_length(g->'cellIds')>3000 or not dungeon_private.json_int(g->'diamonds',1,999)
   or not dungeon_private.json_int(g->'reward'->'first',0,999) or not dungeon_private.json_int(g->'reward'->'later',0,999) then return false; end if;
  if g->>'type'='allType' and (g->>'fieldType' is null or g->>'fieldType' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin')) then return false; end if;
  values_seen:='{}';for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not dungeon_private.json_int(a,1,9007199254740990) or a::text=any(values_seen) then return false; end if;values_seen:=array_append(values_seen,a::text);
  end loop;
 end loop;
 return true;
exception when others then return false;
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
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Wegfeld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->>'type'='normal' and r->'dimmed'='true'::jsonb and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
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

create or replace function dungeon_private.game_available_powerups(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements(dungeon_private.available_powerups(g.map_version_id,s)) value
  where value not in ('"binocular"'::jsonb,'"horn"'::jsonb) or (g.rules_version>=7 and g.settings->'fog'='true'::jsonb);
$$;

create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind='normal' and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where (dungeon_private.has_reached(s,v.cell_id) or not exists(select 1 from public.dungeon_map_cells blocker where blocker.version_id=g.map_version_id and blocker.cell_id=v.cell_id and blocker.kind in ('monster','boss','miniboss')))
  and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;

create or replace function public.choose_game_powerup(p_session_token text,p_game_id uuid,p_chest_cell_id text,p_state_revision bigint,p_powerup text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;s jsonb;replay jsonb;
 payload jsonb:=jsonb_build_object('chest',p_chest_cell_id,'stateRevision',p_state_revision,'powerup',p_powerup);
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'powerup',payload);if replay is not null then return replay; end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 perform dungeon_private.prepare_game_rules(g.id);select * into g from public.dungeon_games where id=g.id;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;s:=ps.state;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED'); end if;
 if not coalesce(s->'pendingChests','[]') @> jsonb_build_array(p_chest_cell_id) then return jsonb_build_object('ok',false,'error','GAME_CHEST_INVALID'); end if;
 if p_powerup is null or not dungeon_private.game_available_powerups(g,s) @> jsonb_build_array(p_powerup) then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE'); end if;
 s:=s||jsonb_build_object('pendingChests',(select coalesce(jsonb_agg(id),'[]') from jsonb_array_elements_text(s->'pendingChests') id where id<>p_chest_cell_id),
  'powerups',coalesce(s->'powerups','[]')||jsonb_build_array(p_powerup));
 if p_powerup='extraLife' then s:=s||jsonb_build_object('extraLives',coalesce((s->>'extraLives')::int,0)+3,'diamonds',coalesce((s->>'diamonds')::int,0)+1);
 elsif p_powerup='redDice' then s:=s||jsonb_build_object('redUses',coalesce((s->>'redUses')::int,0)+3);
 elsif p_powerup='torch' then s:=s||jsonb_build_object('torchUses',2);
 elsif p_powerup='binocular' then s:=s||jsonb_build_object('visionRadius',3);
 elsif p_powerup='horn' then s:=s||jsonb_build_object('hornUses',1);
 elsif p_powerup='axe' then s:=s||jsonb_build_object('axeUses',2); end if;
 s:=dungeon_private.award_game_tasks(g,player,s);
 if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
 update public.dungeon_game_player_states set state=s,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 if coalesce((s->>'lostLives')::int,0)<11+coalesce((s->>'extraLives')::int,0) then update public.dungeon_game_players set eliminated=false where game_id=g.id and player_id=player; end if;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'powerup_chosen',jsonb_build_object('playerId',player,'chest',p_chest_cell_id,'powerup',p_powerup));
 if g.phase='choosing' and ps.last_completed_round<g.round_index and jsonb_array_length(s->'pendingChests')=0
  and jsonb_array_length(dungeon_private.game_actions(g,player,s))=0 and jsonb_array_length(dungeon_private.game_torch_actions(g,player,s))=0 then
  perform dungeon_private.apply_life_loss(g.id,player,g.round_index,g.revision,true);
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'powerup',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function public.update_player_preferences(p_session_token text,p_preferences jsonb,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;prefs jsonb;current_revision bigint;
begin
 player:=dungeon_private.require_player(p_session_token);
 if p_preferences is null or jsonb_typeof(p_preferences)<>'object'
  or not exists(select 1 from dungeon_private.marking_catalog where style=p_preferences->>'markStyle')
  or jsonb_typeof(p_preferences->'sound') is distinct from 'boolean'
  or jsonb_typeof(p_preferences->'music') is distinct from 'boolean'
  or jsonb_typeof(p_preferences->'reduceMotion') is distinct from 'boolean' then
  return jsonb_build_object('ok',false,'error','PREFERENCES_INVALID');
 end if;
 if (p_preferences ? 'diceStyle' and coalesce(p_preferences->>'diceStyle','') not in ('ivory','forest','midnight','amber'))
  or (p_preferences ? 'cupStyle' and coalesce(p_preferences->>'cupStyle','') not in ('leather','wood','runic'))
  or (p_preferences ? 'campStyle' and coalesce(p_preferences->>'campStyle','') not in ('forest','dawn','moon','autumn'))
  or (p_preferences ? 'diceAnimation' and coalesce(p_preferences->>'diceAnimation','') not in ('none','short','normal','long')) then
  return jsonb_build_object('ok',false,'error','PREFERENCES_INVALID');
 end if;
 select revision into current_revision from public.dungeon_players where id=player for update;
 if current_revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED');end if;
 if p_preferences->>'markStyle'<>'cross' and not exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_preferences->>'markStyle') then
  return jsonb_build_object('ok',false,'error','SHOP_STYLE_LOCKED');
 end if;
 prefs:=jsonb_build_object('markStyle',p_preferences->'markStyle','sound',p_preferences->'sound','music',p_preferences->'music','reduceMotion',p_preferences->'reduceMotion');
 -- Optional keys keep old clients and their four-key preferences compatible.
 if p_preferences ? 'diceStyle' then prefs:=prefs||jsonb_build_object('diceStyle',p_preferences->'diceStyle');end if;
 if p_preferences ? 'cupStyle' then prefs:=prefs||jsonb_build_object('cupStyle',p_preferences->'cupStyle');end if;
 if p_preferences ? 'campStyle' then prefs:=prefs||jsonb_build_object('campStyle',p_preferences->'campStyle');end if;
 if p_preferences ? 'diceAnimation' then prefs:=prefs||jsonb_build_object('diceAnimation',p_preferences->'diceAnimation');end if;
 update public.dungeon_players set preferences=prefs,revision=revision+1,updated_at=now() where id=player;
 return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player));
end;
$$;


-- Artefakt ist eine bestätigte, einmalige Ressourcenaktion, kein regulärer Zug.
create or replace function public.use_game_horn(p_session_token text,p_game_id uuid,p_state_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;replay jsonb;payload jsonb:=jsonb_build_object('stateRevision',p_state_revision);
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'horn',payload);if replay is not null then return replay;end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED');end if;
 if g.status<>'playing' then return jsonb_build_object('ok',false,'error','GAME_CLOSED');end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED');end if;
 if g.settings->'fog' is distinct from 'true'::jsonb or coalesce((ps.state->>'hornUses')::int,0)<1 or not coalesce(ps.state->'powerups','[]') ? 'horn' then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE');end if;
 update public.dungeon_game_player_states set state=state||jsonb_build_object('hornUses',0,'hornUntil',now()+interval '10 seconds'),revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'horn',payload,g.revision);
end;
$$;

-- Die alten Ereignisse enthalten nicht jeden Zwischenraum / Treffer. Deshalb
-- ab diesem Update ausschließlich bestätigte Zustände als Replay festhalten.
create table if not exists dungeon_private.replay_frames(
 id bigint generated always as identity primary key,
 game_id uuid not null references public.dungeon_games(id) on delete cascade,
 player_id uuid not null references public.dungeon_players(id),
 state_revision bigint not null,
 round_index integer not null,
 state jsonb not null,
 dice jsonb,
 round_requirements jsonb not null default '{}',
 initial_frame boolean not null default false,
 recorded_at timestamptz not null default now(),
 unique(game_id,player_id,state_revision)
);
create index if not exists dungeon_replay_game_player on dungeon_private.replay_frames(game_id,player_id,id);
revoke all on dungeon_private.replay_frames from public,anon,authenticated;
create or replace function dungeon_private.capture_replay_frame()
returns trigger language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;
begin
 if tg_op='UPDATE' then
  if new.state is not distinct from old.state and new.last_completed_round is not distinct from old.last_completed_round then return new;end if;
 end if;
 select * into g from public.dungeon_games where id=new.game_id;
 if g.status in ('playing','paused') then
  insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
  values(new.game_id,new.player_id,new.revision,greatest(1,g.round_index),new.state,g.dice,coalesce(g.round_requirements,'{}'),tg_op='INSERT') on conflict do nothing;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_capture_replay on public.dungeon_game_player_states;
create trigger dungeon_capture_replay after insert or update on public.dungeon_game_player_states for each row execute function dungeon_private.capture_replay_frame();
-- Startet nach der Runden-Vorbereitung, damit auch die ersten Zufallszahlen
-- exakt den gestarteten Zustand wiedergeben.
create or replace function dungeon_private.capture_replay_start()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='lobby' and new.status='playing' then
  insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
   select s.game_id,s.player_id,s.revision,new.round_index,s.state,new.dice,coalesce(new.round_requirements,'{}'),true from public.dungeon_game_player_states s where s.game_id=new.id on conflict do nothing;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_capture_replay_start on public.dungeon_games;
create trigger dungeon_capture_replay_start after update of status on public.dungeon_games for each row execute function dungeon_private.capture_replay_start();
-- Schon laufende Spiele erhalten einen ehrlichen Einstiegspunkt, keine
-- erfundene Vorgeschichte. Wiederholtes SQL ergänzt keine Duplikate.
insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
 select s.game_id,s.player_id,s.revision,g.round_index,s.state,g.dice,coalesce(g.round_requirements,'{}'),false
 from public.dungeon_game_player_states s join public.dungeon_games g on g.id=s.game_id where g.status in ('playing','paused') on conflict do nothing;

create or replace function public.get_game_replay(p_session_token text,p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare viewer uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;players jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.status<>'finished' then return jsonb_build_object('ok',false,'error','GAME_CLOSED');end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,
  'complete',exists(select 1 from dungeon_private.replay_frames f where f.game_id=g.id and f.player_id=p.id and f.initial_frame),
  'frames',(select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'round',f.round_index,'state',f.state,'dice',f.dice,'roundRequirements',f.round_requirements,'recordedAt',f.recorded_at) order by f.id),'[]') from dungeon_private.replay_frames f where f.game_id=g.id and f.player_id=p.id)) order by gp.seat),'[]') into players
 from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id;
 return jsonb_build_object('ok',true,'available',exists(select 1 from dungeon_private.replay_frames where game_id=g.id),
  'game',dungeon_private.game_result_json(g,viewer)||jsonb_build_object('round',g.round_index,'startedAt',g.started_at),
  'definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,'graph',v.compiled_graph) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'players',players);
end;
$$;
revoke all on function public.use_game_horn(text,uuid,bigint,uuid),public.get_game_replay(text,uuid) from public;
grant execute on function public.use_game_horn(text,uuid,bigint,uuid),public.get_game_replay(text,uuid) to anon,authenticated,service_role;


create or replace function dungeon_private.game_result_json(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object('round',g.round_index,'startedAt',g.started_at,'results',(select coalesce(jsonb_agg(jsonb_build_object(
  'playerId',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'points',r.total_points,'diamonds',r.diamonds,
  'lifePenalty',r.life_penalty,'monstersDefeated',r.monsters_defeated,'won',r.won,'breakdown',r.breakdown,'eliminated',gp.eliminated,'removed',not gp.active) order by r.total_points desc,gp.seat),'[]')
  from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id join public.dungeon_game_players gp on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id));
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'roundTwoVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;

revoke all on all functions in schema dungeon_private from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(10) on conflict do nothing;
notify pgrst,'reload schema';
commit;
