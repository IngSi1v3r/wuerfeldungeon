-- Würfeldungeon 1.3.0: Würfelmagie, Zahlenbüchse und variable Nebelsicht.
-- Nach 034 installieren. Wiederholbar; Spielstände und Karten bleiben erhalten.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then raise exception 'Bitte zuerst Version 1.2.0 installieren.';end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=17) then raise exception 'Bitte zuerst Version 1.2.0 (034) installieren.';end if;
end$$;
lock table dungeon_private.schema_migrations in exclusive mode;


create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>8 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn','magicDie','numberFlask') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','doubleSum','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if jsonb_typeof(r->'start') is distinct from 'boolean' or jsonb_typeof(r->'dimmed') is distinct from 'boolean' then return false; end if;
  if r->>'type' in ('monster','boss') and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
  if r->>'type'='doubleSum' and r->'number' is not null and r->'number'<>'null'::jsonb and (not dungeon_private.json_int(r->'number',2,12) or (r->>'number')::int%2<>0) then return false; end if;
  if r->>'type'='rune' and ((r ? 'runeEffect' and (jsonb_typeof(r->'runeEffect') is distinct from 'string' or r->>'runeEffect' not in ('unlock','hits'))) or (r ? 'runeHits' and not dungeon_private.json_int(r->'runeHits',1,100))) then return false; end if;
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

create or replace function dungeon_private.powerup_selection_valid(powers jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare value jsonb;seen text[]:='{}';
begin
 if jsonb_typeof(powers) is distinct from 'array' then return false;end if;
 if jsonb_array_length(powers)>8 then return false;end if;
 for value in select v from jsonb_array_elements(powers) v loop
  if jsonb_typeof(value)<>'string' or value#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn','magicDie','numberFlask') or (value#>>'{}')=any(seen) then return false;end if;
  seen:=array_append(seen,value#>>'{}');
 end loop;
 return true;
end;
$$;

create or replace function dungeon_private.game_settings_valid(s jsonb)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(jsonb_typeof(s)='object' and dungeon_private.json_int(s->'maxPlayers',2,16)
  and s->>'cards' in ('open','hidden') and jsonb_typeof(s->'hints')='boolean'
  and (not s ? 'diceHints' or jsonb_typeof(s->'diceHints')='boolean')
  and (not s ? 'fieldHints' or jsonb_typeof(s->'fieldHints')='boolean')
  and (not s ? 'fog' or jsonb_typeof(s->'fog')='boolean')
  and (not s ? 'fogRange' or dungeon_private.json_int(s->'fogRange',1,3))
  and (not s ? 'allowedPowerups' or dungeon_private.powerup_selection_valid(s->'allowedPowerups')),false);
$$;

create or replace function public.create_game(p_session_token text,p_map_version_id uuid,p_name text,p_settings jsonb,p_password text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; previous dungeon_private.game_create_requests%rowtype; hash text; v public.dungeon_map_versions%rowtype; settings jsonb;
begin
 if p_request_id is null or p_name is null or char_length(btrim(p_name)) not between 1 and 80 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID'); end if;
 if not dungeon_private.game_settings_valid(p_settings) then return jsonb_build_object('ok',false,'error','GAME_SETTINGS_INVALID'); end if;
 if p_password is not null and octet_length(p_password)>72 then return jsonb_build_object('ok',false,'error','GAME_PASSWORD_INVALID'); end if;
 settings:=jsonb_build_object('maxPlayers',p_settings->'maxPlayers','cards',p_settings->'cards','hints',p_settings->'hints');
 -- Optional keys are preserved only when supplied, so old request hashes still replay.
 if p_settings ? 'allowedPowerups' then settings:=settings||jsonb_build_object('allowedPowerups',p_settings->'allowedPowerups');end if;
 if p_settings ? 'fog' then settings:=settings||jsonb_build_object('fog',p_settings->'fog');end if;
 if p_settings ? 'fogRange' then settings:=settings||jsonb_build_object('fogRange',p_settings->'fogRange');end if;
 if p_settings ? 'diceHints' then settings:=settings||jsonb_build_object('diceHints',p_settings->'diceHints');end if;
 if p_settings ? 'fieldHints' then settings:=settings||jsonb_build_object('fieldHints',p_settings->'fieldHints');end if;
 hash:=dungeon_private.token_hash(jsonb_build_object('map',p_map_version_id,'name',btrim(p_name),'settings',settings,'password',coalesce(p_password,''))::text);
 -- Erstellung je Spieler serialisieren, ohne FK-Prüfungen beim gleichzeitigen
 -- Archivieren einer Karte zu blockieren (deren updated_by verweist hierher).
 perform 1 from public.dungeon_players where id=player for no key update;
 select * into previous from dungeon_private.game_create_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.payload_hash<>hash then return jsonb_build_object('ok',false,'error','GAME_REQUEST_INVALID'); end if;
  return jsonb_build_object('ok',true,'gameId',previous.game_id);
 end if;
 select v0.* into v from public.dungeon_map_versions v0 join public.dungeon_maps m on m.id=v0.map_id where v0.id=p_map_version_id and m.status='published' for share of m;
 if not found then return jsonb_build_object('ok',false,'error','GAME_MAP_UNAVAILABLE'); end if;
 insert into public.dungeon_games(name,host_id,map_version_id,settings) values(btrim(p_name),player,v.id,settings) returning * into g;
 insert into public.dungeon_game_players(game_id,player_id,seat,last_seen_at) values(g.id,player,0,clock_timestamp());
 if coalesce(p_password,'')<>'' then insert into dungeon_private.game_passwords(game_id,password_hash) values(g.id,dungeon_private.hash_password(p_password)); end if;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'created',jsonb_build_object('playerId',player));
 insert into dungeon_private.game_create_requests(player_id,request_id,payload_hash,game_id) values(player,p_request_id,hash,g.id);
 return jsonb_build_object('ok',true,'gameId',g.id);
end;
$$;

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
   and v.depth<coalesce((g.settings->>'fogRange')::int,2)+case when coalesce(s->'powerups','[]') ? 'binocular' then 1 else 0 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;

create or replace function public.roll_game_dice(p_session_token text,p_game_id uuid,p_round integer,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;replay jsonb;payload jsonb:=jsonb_build_object('round',p_round);d jsonb;ps record;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'roll',payload);if replay is not null then return replay; end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 perform dungeon_private.prepare_game_rules(g.id);select * into g from public.dungeon_games where id=g.id;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' or g.phase='round_complete' then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 if g.roller_id<>player then return jsonb_build_object('ok',false,'error','GAME_ROLLER_ONLY'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.phase<>'waiting_roll' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_ROLLED'); end if;
 if exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
  where gp.game_id=g.id and gp.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0) then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING'); end if;
 d:=jsonb_build_array(dungeon_private.roll_die(),dungeon_private.roll_die(),dungeon_private.roll_die(),dungeon_private.roll_die());
 update public.dungeon_games set dice=d,phase='choosing',choice_started_at=now(),revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'rolled',jsonb_build_object('round',g.round_index,'dice',d,'rollerId',player));
 for ps in select s.* from public.dungeon_game_player_states s join public.dungeon_game_players gp on gp.game_id=s.game_id and gp.player_id=s.player_id where s.game_id=g.id and gp.active and not gp.eliminated loop
  if jsonb_array_length(dungeon_private.game_actions(g,ps.player_id,ps.state))=0 and jsonb_array_length(dungeon_private.game_torch_actions(g,ps.player_id,ps.state))=0
   and coalesce((ps.state->>'magicUses')::int,0)=0
   and coalesce((ps.state->>'flaskUses')::int,0)=0 then
   perform dungeon_private.apply_life_loss(g.id,ps.player_id,g.round_index,g.revision,true);
  end if;
 end loop;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'roll',payload,(select revision from public.dungeon_games where id=g.id));
end;
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
 elsif p_powerup='axe' then s:=s||jsonb_build_object('axeUses',2);
 elsif p_powerup='magicDie' then s:=s||jsonb_build_object('magicUses',2);
 elsif p_powerup='numberFlask' then s:=s||jsonb_build_object('flaskUses',1); end if;
 s:=dungeon_private.award_game_tasks(g,player,s);
 if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
 update public.dungeon_game_player_states set state=s,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 if coalesce((s->>'lostLives')::int,0)<11+coalesce((s->>'extraLives')::int,0) then update public.dungeon_game_players set eliminated=false where game_id=g.id and player_id=player; end if;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'powerup_chosen',jsonb_build_object('playerId',player,'chest',p_chest_cell_id,'powerup',p_powerup));
 if g.phase='choosing' and ps.last_completed_round<g.round_index and jsonb_array_length(s->'pendingChests')=0
  and jsonb_array_length(dungeon_private.game_actions(g,player,s))=0 and jsonb_array_length(dungeon_private.game_torch_actions(g,player,s))=0
  and coalesce((s->>'magicUses')::int,0)=0
  and coalesce((s->>'flaskUses')::int,0)=0 then
  perform dungeon_private.apply_life_loss(g.id,player,g.round_index,g.revision,true);
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'powerup',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function dungeon_private.game_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.rules_version<7 then return dungeon_private.game_actions_v5(g,p_player,s); end if;
 if g.dice is null then return result; end if;
 if coalesce((s->>'storedActiveRound')::int,0)=g.round_index and s->>'storedNumber' is not null then
  normal:=array[s->>'storedNumber'];red:='{}'::text[];
 else
  if coalesce((s->>'magicRound')::int,0)=g.round_index and jsonb_typeof(s->'magicDice')='array' then g.dice:=s->'magicDice';end if;
  normal:=dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player));
  red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
 end if;
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 for c in select * from public.dungeon_map_cells where version_id=g.map_version_id order by cell_id loop
  if not dungeon_private.cell_reachable(g.map_version_id,c.cell_id,s) then continue; end if;
  requirements:=dungeon_private.game_cell_requirements(g,c,rules,s);
  matches:=array(select n from unnest(requirements) n where n=any(normal));
  red_matches:=array(select n from unnest(requirements) n where n=any(red));
  if cardinality(matches)>0 or cardinality(red_matches)>0 then
   result:=result||jsonb_build_array(jsonb_build_object('cellId',c.cell_id,'redOnly',cardinality(matches)=0,
    'attack',dungeon_private.game_enemy(c),'numbers',to_jsonb(case when cardinality(matches)>0 then matches else red_matches end)));
  end if;
 end loop;
 return result;
end;
$$;

create or replace function dungeon_private.game_torch_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare middle public.dungeon_map_cells%rowtype;c public.dungeon_map_cells%rowtype;temporary jsonb;result jsonb:='[]';
 rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];
begin
 if g.rules_version<7 then return dungeon_private.game_torch_actions_v5(g,p_player,s); end if;
 if coalesce((s->>'torchUses')::int,0)<1 or g.dice is null then return result; end if;
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 if coalesce((s->>'storedActiveRound')::int,0)=g.round_index and s->>'storedNumber' is not null then
  normal:=array[s->>'storedNumber'];red:='{}'::text[];
 else
  if coalesce((s->>'magicRound')::int,0)=g.round_index and jsonb_typeof(s->'magicDice')='array' then g.dice:=s->'magicDice';end if;
  normal:=dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player));
  red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
 end if;
 for middle in select * from public.dungeon_map_cells where version_id=g.map_version_id and kind not in ('monster','miniboss','boss','bonus') order by cell_id loop
  if not dungeon_private.cell_reachable(g.map_version_id,middle.cell_id,s) then continue; end if;
  temporary:=dungeon_private.preview_reach(g,s,middle.cell_id);
  for c in select t.* from public.dungeon_map_cells t where t.version_id=g.map_version_id and not dungeon_private.has_reached(temporary,t.cell_id)
   and dungeon_private.torch_target_linked(g,s,middle.cell_id,t.cell_id) order by t.cell_id loop
   requirements:=dungeon_private.game_cell_requirements(g,c,rules,temporary);
   matches:=array(select n from unnest(requirements) n where n=any(normal));
   red_matches:=array(select n from unnest(requirements) n where n=any(red));
   if cardinality(matches)>0 or cardinality(red_matches)>0 then
    result:=result||jsonb_build_array(jsonb_build_object('cellId',c.cell_id,'middleCellId',middle.cell_id,
     'redOnly',cardinality(matches)=0,'attack',dungeon_private.game_enemy(c),
     'numbers',to_jsonb(case when cardinality(matches)>0 then matches else red_matches end)));
   end if;
  end loop;
 end loop;
 return result;
end;
$$;

create or replace function dungeon_private.game_turn_view(g public.dungeon_games,p_player uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ps public.dungeon_game_player_states%rowtype;gp public.dungeon_game_players%rowtype;actions jsonb;torch jsonb;standard_possible boolean;red_possible boolean;ready boolean;pending boolean;
begin
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=p_player;
 select * into gp from public.dungeon_game_players where game_id=g.id and player_id=p_player;
 pending:=jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0;
 ready:=coalesce(gp.active and not gp.eliminated and g.status='playing' and g.phase='choosing' and ps.last_completed_round<g.round_index and not pending,false);
 actions:=case when g.phase='choosing' and ps.last_completed_round<g.round_index and not gp.eliminated and not pending then dungeon_private.game_actions(g,p_player,ps.state) else '[]'::jsonb end;
 torch:=case when g.phase='choosing' and ps.last_completed_round<g.round_index and not gp.eliminated and not pending then dungeon_private.game_torch_actions(g,p_player,ps.state) else '[]'::jsonb end;
 standard_possible:=exists(select 1 from jsonb_array_elements(case when coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index then dungeon_private.game_actions(g,p_player,ps.state||jsonb_build_object('storedActiveRound',null)) else actions end) a where a->'redOnly'='false'::jsonb);
 red_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='true'::jsonb);
 if coalesce((ps.state->>'magicRound')::int,0)=g.round_index and jsonb_typeof(ps.state->'magicDice')='array' then g.dice:=ps.state->'magicDice';end if;
 return jsonb_build_object('canRoll',coalesce(g.status='playing' and g.phase='waiting_roll' and g.roller_id=p_player and gp.active and not gp.eliminated,false)
   and not exists(select 1 from public.dungeon_game_players gp2 join public.dungeon_game_player_states s on s.game_id=gp2.game_id and s.player_id=gp2.player_id where gp2.game_id=g.id and gp2.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0),
  'freeRed',dungeon_private.game_red_free(g,p_player),'canAct',ready,'done',coalesce(ps.last_completed_round>=g.round_index,false) and not pending,'standardPossible',standard_possible,'redPossible',red_possible,
  'torchPossible',jsonb_array_length(torch)>0,'canLoseLife',ready and not standard_possible,'ownRevision',ps.revision,'lastCompletedRound',ps.last_completed_round,
  'pendingPowerup',pending,'availablePowerups',dungeon_private.game_available_powerups(g,ps.state))
  ||case when coalesce(g.settings->'fieldHints',g.settings->'hints')='true'::jsonb then jsonb_build_object('actions',actions) else '{}'::jsonb end
  ||case when coalesce(g.settings->'diceHints',g.settings->'hints')='true'::jsonb then jsonb_build_object(
   'options',to_jsonb(case when coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index and ps.state->>'storedNumber' is not null then array[ps.state->>'storedNumber'] else dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player)) end),
   'redOptions',to_jsonb(case when coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index then '{}'::text[] when not dungeon_private.game_red_free(g,p_player) and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.game_dice_options(g,true)) n where not n=any(dungeon_private.game_dice_options(g,false))) else '{}'::text[] end)) else '{}'::jsonb end;
end;
$$;

create or replace function public.get_ai_context(p_session_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;v public.dungeon_map_versions%rowtype;
 ps record;ctx jsonb;contexts jsonb:='[]';seen jsonb;doc jsonb;rules jsonb;edges jsonb;t jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.host_id<>player or g.mode='multiplayer' then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY');end if;
 select * into v from public.dungeon_map_versions where id=g.map_version_id;
 if g.status='playing' then
 for ps in select s.*,gp.seat,gp.eliminated,p.preferences from public.dungeon_game_player_states s join public.dungeon_game_players gp on gp.game_id=s.game_id and gp.player_id=s.player_id
  join public.dungeon_players p on p.id=s.player_id where s.game_id=g.id and gp.active and not gp.eliminated and p.is_bot order by gp.seat loop
  t:=dungeon_private.game_turn_view(g,ps.player_id);
  if not (t->'canAct'='true'::jsonb or t->'pendingPowerup'='true'::jsonb or t->'canRoll'='true'::jsonb) then continue;end if;
  seen:=dungeon_private.game_visible_cells(g,ps.state);
  if coalesce((ps.state->>'hornUntil')::timestamptz,'epoch')>now() then
   seen:=seen||(select coalesce(jsonb_agg(cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id and kind in ('monster','boss','miniboss'));
  end if;
  select jsonb_build_object('rooms',coalesce(jsonb_agg(c.definition-'image'-'defeatedImage'-'imageLayout'),'[]')) into doc from public.dungeon_map_cells c where c.version_id=g.map_version_id and seen ? c.cell_id;
  select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into edges from public.dungeon_map_connections where version_id=g.map_version_id and seen ? cell_a and seen ? cell_b;
  ctx:=jsonb_build_object('gameId',g.id,'character',coalesce(ps.preferences->>'adventurerCharacter','warden'),'seat',ps.seat,'redEvery',g.settings->'redEvery','dice',g.dice,'availablePool',dungeon_private.game_powerup_pool(g),'mandatoryCount',(select count(*) from public.dungeon_map_cells where version_id=g.map_version_id and kind in ('monster','boss','miniboss')),'playerId',ps.player_id,'round',g.round_index,'revision',ps.revision,'state',ps.state,'fog',g.settings->'fog','fogRange',coalesce(g.settings->'fogRange','2'::jsonb),'freeRed',dungeon_private.game_red_free(g,ps.player_id),
   'canRoll',t->'canRoll','canAct',t->'canAct','canLoseLife',t->'canLoseLife','pendingChest',ps.state->'pendingChests'->0,'availablePowerups',t->'availablePowerups',
   'roundRequirements',g.round_requirements,'tasks',dungeon_private.task_view(g,ps.player_id,ps.state),'taskClaims',(select coalesce(jsonb_agg(jsonb_build_object('key',task_key,'completedInRound',completed_in_round)),'[]') from public.dungeon_game_task_claims where game_id=g.id),'definition',jsonb_build_object('document',doc,'rules',v.rules,'graph',edges,'fogRange',coalesce(g.settings->'fogRange','2'::jsonb)),
   'actions',case when t->'canAct'='true'::jsonb then dungeon_private.game_actions(g,ps.player_id,ps.state) else '[]'::jsonb end,
   'torchActions',case when t->'canAct'='true'::jsonb then dungeon_private.game_torch_actions(g,ps.player_id,ps.state) else '[]'::jsonb end,
   'opponents',case when g.settings->>'cards'='open' then (select coalesce(jsonb_agg(jsonb_build_object('playerId',o.player_id,'state',jsonb_build_object('reached',o.state->'reached','monsterHits',o.state->'monsterHits','firstKills',o.state->'firstKills'))),'[]') from public.dungeon_game_player_states o join public.dungeon_game_players op on op.game_id=o.game_id and op.player_id=o.player_id where o.game_id=g.id and o.player_id<>ps.player_id and op.active and not op.eliminated) else '[]'::jsonb end,
   'traps',(select coalesce(jsonb_agg(jsonb_build_object('cellId',cell_id,'activatedInRound',activated_in_round,'armed',activated_in_round<g.round_index)),'[]') from public.dungeon_game_trap_claims where game_id=g.id),
   'claims',(select coalesce(jsonb_agg(jsonb_build_object('cellId',monster_cell_id,'claimedInRound',claimed_in_round)),'[]') from public.dungeon_game_monster_claims where game_id=g.id));
  contexts:=contexts||jsonb_build_array(ctx);
 end loop;end if;
 return jsonb_build_object('ok',true,'status',g.status,'round',g.round_index,'phase',g.phase,'bots',contexts);
end;
$$;

create or replace function public.play_game_action(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid,p_middle_cell_id text default null,p_use_axe boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;c public.dungeon_map_cells%rowtype;middle public.dungeon_map_cells%rowtype;
 replay jsonb;payload jsonb:=jsonb_build_object('round',p_round,'stateRevision',p_state_revision,'action',p_action,'cellId',p_cell_id,'useRed',p_use_red);
 actions jsonb;chosen jsonb;s jsonb;reward integer:=0;temporary jsonb;
begin
 if p_middle_cell_id is not null or p_use_axe then payload:=payload||jsonb_build_object('middleCellId',p_middle_cell_id,'useAxe',p_use_axe); end if;
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 if g.rules_version<7 then return dungeon_private.play_game_action_v5(p_session_token,p_game_id,p_round,p_state_revision,p_action,p_cell_id,p_use_red,p_request_id,p_middle_cell_id,p_use_axe); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'turn',payload);if replay is not null then return replay; end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 perform dungeon_private.prepare_game_rules(g.id);select * into g from public.dungeon_games where id=g.id;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' or g.phase='round_complete' then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.phase<>'choosing' then return jsonb_build_object('ok',false,'error','GAME_NOT_ROLLED'); end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.last_completed_round>=g.round_index then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED'); end if;
 if jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0 then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING'); end if;
 if p_use_red is null or p_use_axe is null or p_action is null or p_action not in ('cell','lose_life') then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID'); end if;
 actions:=dungeon_private.game_actions(g,player,ps.state);
 if p_action='lose_life' and coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index then
  actions:=dungeon_private.game_actions(g,player,ps.state||jsonb_build_object('storedActiveRound',null));
 end if;
 if p_action='lose_life' then
  if p_cell_id is not null or p_middle_cell_id is not null or p_use_red or p_use_axe or exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='false'::jsonb) then return jsonb_build_object('ok',false,'error','GAME_MOVE_AVAILABLE'); end if;
  update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
  perform dungeon_private.apply_life_loss(g.id,player,g.round_index,g.revision,false);
 else
  select * into c from public.dungeon_map_cells where version_id=g.map_version_id and cell_id=p_cell_id;
  if not found then return jsonb_build_object('ok',false,'error','GAME_CELL_INVALID'); end if;
  if dungeon_private.has_reached(ps.state,c.cell_id) then return jsonb_build_object('ok',false,'error','GAME_CELL_REACHED'); end if;
  s:=ps.state;
  if p_middle_cell_id is not null then
   if p_use_axe then return jsonb_build_object('ok',false,'error','GAME_POWERUP_COMBINATION'); end if;
   if coalesce((s->>'torchUses')::int,0)<1 then return jsonb_build_object('ok',false,'error','GAME_TORCH_EMPTY'); end if;
   select * into middle from public.dungeon_map_cells where version_id=g.map_version_id and cell_id=p_middle_cell_id;
   if not found or dungeon_private.game_enemy(middle) or middle.cell_id=c.cell_id or not dungeon_private.cell_reachable(g.map_version_id,middle.cell_id,s) then return jsonb_build_object('ok',false,'error','GAME_TORCH_PATH'); end if;
   if not dungeon_private.torch_target_linked(g,s,middle.cell_id,c.cell_id) then return jsonb_build_object('ok',false,'error','GAME_TORCH_PATH'); end if;
   temporary:=dungeon_private.preview_reach(g,s,middle.cell_id);
   actions:=dungeon_private.game_actions(g,player,temporary);
  elsif not dungeon_private.cell_reachable(g.map_version_id,c.cell_id,s) then return jsonb_build_object('ok',false,'error','GAME_CELL_UNREACHABLE'); end if;
  select a into chosen from jsonb_array_elements(actions) a where a->>'cellId'=c.cell_id;
  if chosen is null then return jsonb_build_object('ok',false,'error','GAME_NUMBER_MISMATCH'); end if;
  if chosen->'redOnly'='true'::jsonb and not p_use_red then return jsonb_build_object('ok',false,'error','GAME_RED_CONFIRMATION'); end if;
  if p_use_axe and (not dungeon_private.game_enemy(c) or coalesce((s->>'axeUses')::int,0)<1) then return jsonb_build_object('ok',false,'error','GAME_AXE_UNAVAILABLE'); end if;
  -- Erst nach vollständiger Prüfung Kosten und Belohnungen anwenden.
  if p_middle_cell_id is not null then
   s:=s||jsonb_build_object('torchUses',(s->>'torchUses')::int-1);
   s:=dungeon_private.reach_game_cell(g,player,s,middle);
  end if;
  if chosen->'redOnly'='true'::jsonb then s:=s||jsonb_build_object('redUses',(s->>'redUses')::int-1); end if;
  if coalesce((s->>'storedActiveRound')::int,0)=g.round_index then s:=s||jsonb_build_object('storedNumber',null,'storedActiveRound',null,'flaskUses',0); end if;
  if p_use_axe then s:=s||jsonb_build_object('axeUses',(s->>'axeUses')::int-1); end if;
  if dungeon_private.game_enemy(c) then
   s:=dungeon_private.damage_game_enemy(g,player,s,c,case when p_use_axe then 2 else 1 end);
  else s:=dungeon_private.reach_game_cell(g,player,s,c);end if;
  reward:=coalesce((s->>'diamonds')::int,0)-coalesce((ps.state->>'diamonds')::int,0);
  s:=dungeon_private.award_game_tasks(g,player,s);
  if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  update public.dungeon_game_players set eliminated=coalesce((s->>'lostLives')::int,0)>=11+coalesce((s->>'extraLives')::int,0) where game_id=g.id and player_id=player;
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'middleCellId',p_middle_cell_id,'axeUsed',p_use_axe,'round',g.round_index,'redUsed',chosen->'redOnly','storedUsed',coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index,'reward',reward));
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

-- Eine persönliche Änderung des aktuellen Wurfs; die übrigen Spieler behalten
-- das unveränderte gemeinsame Ergebnis. Beide Verwendungen dürfen auch in
-- derselben Runde eingesetzt werden und bauen auf dem eigenen Wurf auf.
create or replace function public.use_game_magic(p_session_token text,p_game_id uuid,p_state_revision bigint,p_die_index integer,p_delta integer,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;
 payload jsonb:=jsonb_build_object('revision',p_state_revision,'index',p_die_index,'delta',p_delta);replay jsonb;die integer;changed jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'magic',payload);if replay is not null then return replay;end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED');end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED');end if;
 if g.status<>'playing' or g.phase<>'choosing' or ps.last_completed_round>=g.round_index or g.dice is null then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE');end if;
 if jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0 then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING');end if;
 if coalesce((ps.state->>'magicUses')::int,0)<1 or coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE');end if;
 if p_die_index is null or p_die_index not between 0 and 3 or p_delta is null or p_delta not in (-1,1) then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 if coalesce((ps.state->>'magicRound')::int,0)=g.round_index and jsonb_typeof(ps.state->'magicDice')='array' then g.dice:=ps.state->'magicDice';end if;
 die:=(g.dice->>p_die_index)::int;
 if die+p_delta not between 1 and 6 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 changed:=jsonb_set(g.dice,array[p_die_index::text],to_jsonb(die+p_delta));
 update public.dungeon_game_player_states set state=state||jsonb_build_object('magicUses',(ps.state->>'magicUses')::int-1,'magicRound',g.round_index,'magicDice',changed),revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'magic_used',jsonb_build_object('playerId',player,'round',g.round_index,'dieIndex',p_die_index,'value',die+p_delta));
 return dungeon_private.record_game_command(g.id,player,p_request_id,'magic',payload,g.revision);
end;
$$;

-- Eine würfelbare Zahl einpacken kostet den aktuellen Zug. Rot kostet eine
-- Verwendung, wenn die Zahl nur mit dem roten Würfel erreichbar ist.
create or replace function public.store_game_number(p_session_token text,p_game_id uuid,p_state_revision bigint,p_number text,p_use_red boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;
 payload jsonb:=jsonb_build_object('revision',p_state_revision,'number',p_number,'red',p_use_red);replay jsonb;s jsonb;normal text[];all_dice text[];free boolean;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'store_number',payload);if replay is not null then return replay;end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED');end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED');end if;
 if g.status<>'playing' or g.phase<>'choosing' or ps.last_completed_round>=g.round_index or g.dice is null then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE');end if;
 if jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0 then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING');end if;
 if coalesce((ps.state->>'flaskUses')::int,0)<1 or ps.state->>'storedNumber' is not null then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE');end if;
 if p_number is null or p_number not in ('2','3','4','5','6','7','8','9','10','11','12') or p_use_red is null then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 if coalesce((ps.state->>'magicRound')::int,0)=g.round_index then g.dice:=ps.state->'magicDice';end if;
 free:=dungeon_private.game_red_free(g,player);normal:=dungeon_private.game_dice_options(g,free);
 all_dice:=dungeon_private.game_dice_options(g,true);
 if p_number=any(normal) then
  if p_use_red then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 elsif p_number=any(all_dice) and not free and coalesce((ps.state->>'redUses')::int,0)>0 then
  if not p_use_red then return jsonb_build_object('ok',false,'error','GAME_RED_CONFIRMATION');end if;
 else return jsonb_build_object('ok',false,'error','GAME_NUMBER_MISMATCH');end if;
 s:=ps.state||jsonb_build_object('storedNumber',p_number,'storedActiveRound',null);
 if p_use_red then s:=s||jsonb_build_object('redUses',(s->>'redUses')::int-1);end if;
 update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'number_stored',jsonb_build_object('playerId',player,'round',g.round_index,'number',p_number,'redUsed',p_use_red));
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'store_number',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

-- Bis zum bestätigten Feldzug kann die Zahl wieder eingepackt werden.
create or replace function public.toggle_stored_number(p_session_token text,p_game_id uuid,p_state_revision bigint,p_active boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;
 payload jsonb:=jsonb_build_object('revision',p_state_revision,'active',p_active);replay jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'toggle_number',payload);if replay is not null then return replay;end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED');end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED');end if;
 if g.status<>'playing' or g.phase<>'choosing' or ps.last_completed_round>=g.round_index then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE');end if;
 if jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0 then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING');end if;
 if p_active is null or coalesce((ps.state->>'flaskUses')::int,0)<1 or ps.state->>'storedNumber' is null then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE');end if;
 if (coalesce((ps.state->>'storedActiveRound')::int,0)=g.round_index)=p_active then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 update public.dungeon_game_player_states set state=state||jsonb_build_object('storedActiveRound',case when p_active then to_jsonb(g.round_index) else 'null'::jsonb end),revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'toggle_number',payload,g.revision);
end;
$$;


create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'soloAIVersion',1,'highscoreVersion',1,'adventurerVersion',2,'releaseVersion','1.3.0','artifactVersion',1,'runeHitsVersion',1,'starterCosmeticsVersion',1,'portalFogVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;


revoke all on function public.use_game_magic(text,uuid,bigint,integer,integer,uuid),public.store_game_number(text,uuid,bigint,text,boolean,uuid),public.toggle_stored_number(text,uuid,bigint,boolean,uuid) from public;
grant execute on function public.use_game_magic(text,uuid,bigint,integer,integer,uuid),public.store_game_number(text,uuid,bigint,text,boolean,uuid),public.toggle_stored_number(text,uuid,bigint,boolean,uuid) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(18) on conflict do nothing;
commit;
notify pgrst,'reload schema';
