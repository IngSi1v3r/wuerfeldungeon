-- Würfeldungeon Phase 4: zusätzlich zu 001, 004 und 006 ausführen.
-- Bestehende Spieler, Kartenversionen und Spielstände bleiben erhalten.
begin;
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=3) then
  raise exception 'Bitte zuerst 006_phase3.sql installieren.';
 end if;
end$$;
alter table public.dungeon_games add column if not exists choice_started_at timestamptz;
alter table public.dungeon_games add column if not exists final_round integer;

-- Rejection Sampling vermeidet die Verzerrung von byte % 6.
create or replace function dungeon_private.roll_die()
returns integer language plpgsql volatile set search_path='' as $$
declare n integer;
begin
 loop
  n:=get_byte(decode(dungeon_private.new_token(),'hex'),0);
  if n<252 then return n%6+1; end if;
 end loop;
end;
$$;
create or replace function dungeon_private.dice_options(d jsonb,p_red boolean)
returns text[] language plpgsql immutable set search_path='' as $$
declare result text[]:='{}';i integer;j integer;a integer;b integer;last_die integer;
begin
 if d is null or jsonb_typeof(d)<>'array' or jsonb_array_length(d)<>4 then return result; end if;
 for i in 0..3 loop if not dungeon_private.json_int(d->i,1,6) then return result; end if; end loop;
 last_die:=case when p_red then 3 else 2 end;
 for i in 0..last_die-1 loop
  for j in i+1..last_die loop
   a:=(d->>i)::int;b:=(d->>j)::int;result:=array_append(result,(a+b)::text);
   if a=b then result:=array_append(result,'doubles'); end if;
  end loop;
 end loop;
 return array(select distinct v from unnest(result) v order by v);
end;
$$;
create or replace function dungeon_private.has_reached(s jsonb,p_cell text)
returns boolean language sql immutable set search_path='' as $$
 select exists(select 1 from jsonb_array_elements_text(coalesce(s->'reached','[]')) v where v=p_cell);
$$;
create or replace function dungeon_private.cell_reachable(p_version uuid,p_cell text,s jsonb)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.dungeon_map_cells c where c.version_id=p_version and c.cell_id=p_cell
  and not dungeon_private.has_reached(s,p_cell) and (
   (c.kind='normal' and c.definition->'start'='true'::jsonb)
   or exists(select 1 from public.dungeon_map_connections e where e.version_id=p_version and
    ((e.cell_a=p_cell and dungeon_private.has_reached(s,e.cell_b)) or (e.cell_b=p_cell and dungeon_private.has_reached(s,e.cell_a))))));
$$;
create or replace function dungeon_private.cell_requirements(c public.dungeon_map_cells,p_rules jsonb,s jsonb)
returns text[] language sql stable set search_path='' as $$
 select case when c.kind in ('monster','miniboss','boss') then
  array(select a->>'number' from jsonb_array_elements(c.definition->'attacks') a where a->>'state'='active'
   or exists(select 1 from jsonb_array_elements(p_rules->'unlocks') u where u->>'targetCellId'=c.cell_id and u->'number'=a->'number'
    and dungeon_private.has_reached(s,u->>'sourceCellId')))
  else case when c.definition->>'number' is not null then array[c.definition->>'number'] else '{}'::text[] end end;
$$;
create or replace function dungeon_private.game_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.dice is null then return result; end if;
 normal:=dungeon_private.dice_options(g.dice,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 for c in select * from public.dungeon_map_cells where version_id=g.map_version_id order by cell_id loop
  if not dungeon_private.cell_reachable(g.map_version_id,c.cell_id,s) then continue; end if;
  requirements:=dungeon_private.cell_requirements(c,rules,s);
  matches:=array(select n from unnest(requirements) n where n=any(normal));
  red_matches:=array(select n from unnest(requirements) n where n=any(red));
  if cardinality(matches)>0 or cardinality(red_matches)>0 then
   result:=result||jsonb_build_array(jsonb_build_object('cellId',c.cell_id,'redOnly',cardinality(matches)=0,
    'attack',c.kind in ('monster','miniboss','boss'),'numbers',to_jsonb(case when cardinality(matches)>0 then matches else red_matches end)));
  end if;
 end loop;
 return result;
end;
$$;
create or replace function dungeon_private.life_penalty(s jsonb)
returns integer language sql immutable set search_path='' as $$
 select (array[0,0,0,-1,-2,-4,-6,-9,-12,-16,-20,-20])[least(11,greatest(0,coalesce((s->>'lostLives')::int,0)-coalesce((s->>'extraLives')::int,0)))+1];
$$;
create or replace function dungeon_private.game_turn_view(g public.dungeon_games,p_player uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ps public.dungeon_game_player_states%rowtype;gp public.dungeon_game_players%rowtype;actions jsonb;standard_possible boolean;red_possible boolean;ready boolean;
begin
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=p_player;
 select * into gp from public.dungeon_game_players where game_id=g.id and player_id=p_player;
 ready:=coalesce(gp.active and not gp.eliminated and g.status='playing' and g.phase='choosing' and ps.last_completed_round<g.round_index,false);
 actions:=case when g.phase='choosing' and ps.last_completed_round<g.round_index and not gp.eliminated then dungeon_private.game_actions(g,p_player,ps.state) else '[]'::jsonb end;
 standard_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='false'::jsonb);
 red_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='true'::jsonb);
 return jsonb_build_object('canRoll',coalesce(g.status='playing' and g.phase='waiting_roll' and g.roller_id=p_player and gp.active and not gp.eliminated,false),
  'canAct',ready,'done',coalesce(ps.last_completed_round>=g.round_index,false),'standardPossible',standard_possible,'redPossible',red_possible,
  'canLoseLife',ready and not standard_possible,'ownRevision',ps.revision,'lastCompletedRound',ps.last_completed_round)
  ||case when g.settings->'hints'='true'::jsonb then jsonb_build_object('actions',actions,
   'options',to_jsonb(dungeon_private.dice_options(g.dice,g.roller_id=p_player)),
   'redOptions',to_jsonb(case when g.roller_id<>p_player and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.dice_options(g.dice,true)) n where not n=any(dungeon_private.dice_options(g.dice,false))) else '{}'::text[] end))
   else '{}'::jsonb end;
end;
$$;

-- Ein vollständiger Rundenstand ist die Transaktionsgrenze. Phase 5 wertet
-- round_complete aus; bis dahin wird nach der Endrunde nicht weitergewürfelt.
create or replace function dungeon_private.settle_game_round(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;next_roller uuid;current_seat integer;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.phase<>'choosing' then return; end if;
 if exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
   where gp.game_id=g.id and gp.active and not gp.eliminated and s.last_completed_round<g.round_index) then return; end if;
 if g.final_round is not null or not exists(select 1 from public.dungeon_game_players where game_id=g.id and active and not eliminated) then
  update public.dungeon_games set phase='round_complete',final_round=coalesce(final_round,round_index) where id=g.id;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'end_round_complete',jsonb_build_object('round',g.round_index));
 else
  select seat into current_seat from public.dungeon_game_players where game_id=g.id and player_id=g.roller_id;
  select player_id into next_roller from public.dungeon_game_players where game_id=g.id and active and not eliminated order by (seat>current_seat) desc,seat limit 1;
  update public.dungeon_games set round_index=round_index+1,roller_id=next_roller,phase='waiting_roll',dice=null,choice_started_at=null where id=g.id;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'next_round',jsonb_build_object('round',g.round_index+1,'rollerId',next_roller));
 end if;
end;
$$;
create or replace function dungeon_private.apply_life_loss(p_game uuid,p_player uuid,p_round integer,p_revision bigint,p_automatic boolean)
returns void language plpgsql security definer set search_path='' as $$
declare s jsonb;losses integer;
begin
 select state into s from public.dungeon_game_player_states where game_id=p_game and player_id=p_player;
 losses:=coalesce((s->>'lostLives')::int,0)+1;s:=s||jsonb_build_object('lostLives',losses);
 update public.dungeon_game_player_states set state=s,last_completed_round=p_round,revision=revision+1,updated_at=now() where game_id=p_game and player_id=p_player;
 if losses>=11+coalesce((s->>'extraLives')::int,0) then update public.dungeon_game_players set eliminated=true where game_id=p_game and player_id=p_player; end if;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(p_game,p_revision,'life_lost',jsonb_build_object('playerId',p_player,'round',p_round,'automatic',p_automatic));
end;
$$;

create or replace function public.roll_game_dice(p_session_token text,p_game_id uuid,p_round integer,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;replay jsonb;payload jsonb:=jsonb_build_object('round',p_round);d jsonb;ps record;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'roll',payload);if replay is not null then return replay; end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' or g.phase='round_complete' then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 if g.roller_id<>player then return jsonb_build_object('ok',false,'error','GAME_ROLLER_ONLY'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.phase<>'waiting_roll' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_ROLLED'); end if;
 d:=jsonb_build_array(dungeon_private.roll_die(),dungeon_private.roll_die(),dungeon_private.roll_die(),dungeon_private.roll_die());
 update public.dungeon_games set dice=d,phase='choosing',choice_started_at=now(),revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'rolled',jsonb_build_object('round',g.round_index,'dice',d,'rollerId',player));
 for ps in select s.* from public.dungeon_game_player_states s join public.dungeon_game_players gp on gp.game_id=s.game_id and gp.player_id=s.player_id where s.game_id=g.id and gp.active and not gp.eliminated loop
  if jsonb_array_length(dungeon_private.game_actions(g,ps.player_id,ps.state))=0 then perform dungeon_private.apply_life_loss(g.id,ps.player_id,g.round_index,g.revision,true); end if;
 end loop;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'roll',payload,g.revision);
end;
$$;

create or replace function public.play_game_turn(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;c public.dungeon_map_cells%rowtype;
 replay jsonb;payload jsonb:=jsonb_build_object('round',p_round,'stateRevision',p_state_revision,'action',p_action,'cellId',p_cell_id,'useRed',p_use_red);
 actions jsonb;chosen jsonb;s jsonb;hits integer;first_id uuid;reward integer:=0;defeated boolean:=false;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'turn',payload);if replay is not null then return replay; end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' or g.phase='round_complete' then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.phase<>'choosing' then return jsonb_build_object('ok',false,'error','GAME_NOT_ROLLED'); end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.last_completed_round>=g.round_index then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED'); end if;
 if p_use_red is null or p_action is null or p_action not in ('cell','lose_life') then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID'); end if;
 actions:=dungeon_private.game_actions(g,player,ps.state);
 if p_action='lose_life' then
  if p_cell_id is not null or p_use_red or exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='false'::jsonb) then return jsonb_build_object('ok',false,'error','GAME_MOVE_AVAILABLE'); end if;
  update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
  perform dungeon_private.apply_life_loss(g.id,player,g.round_index,g.revision,false);
 else
  select * into c from public.dungeon_map_cells where version_id=g.map_version_id and cell_id=p_cell_id;
  if not found then return jsonb_build_object('ok',false,'error','GAME_CELL_INVALID'); end if;
  if dungeon_private.has_reached(ps.state,c.cell_id) then return jsonb_build_object('ok',false,'error','GAME_CELL_REACHED'); end if;
  if not dungeon_private.cell_reachable(g.map_version_id,c.cell_id,ps.state) then return jsonb_build_object('ok',false,'error','GAME_CELL_UNREACHABLE'); end if;
  select a into chosen from jsonb_array_elements(actions) a where a->>'cellId'=c.cell_id;
  if chosen is null then return jsonb_build_object('ok',false,'error','GAME_NUMBER_MISMATCH'); end if;
  if chosen->'redOnly'='true'::jsonb and not p_use_red then return jsonb_build_object('ok',false,'error','GAME_RED_CONFIRMATION'); end if;
  s:=ps.state;
  if chosen->'redOnly'='true'::jsonb then s:=s||jsonb_build_object('redUses',(s->>'redUses')::int-1); end if;
  if c.kind in ('monster','miniboss','boss') then
   hits:=least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0)+1);
   s:=s||jsonb_build_object('monsterHits',coalesce(s->'monsterHits','{}')||jsonb_build_object(c.cell_id,hits));
   defeated:=hits=(c.definition->>'hits')::int;
   if defeated then
    insert into public.dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values(g.id,g.map_version_id,c.cell_id,player,g.round_index) on conflict do nothing;
    select first_player_id into first_id from public.dungeon_game_monster_claims where game_id=g.id and monster_cell_id=c.cell_id;
    reward:=(c.definition->>case when first_id=player then 'rewardFirst' else 'rewardLater' end)::int;
    s:=s||jsonb_build_object('reached',(s->'reached')||jsonb_build_array(c.cell_id));
   end if;
  else
   s:=s||jsonb_build_object('reached',(s->'reached')||jsonb_build_array(c.cell_id));
   if c.kind='diamond' then reward:=1;
   elsif c.kind='chest' then s:=s||jsonb_build_object('pendingChests',coalesce(s->'pendingChests','[]')||jsonb_build_array(c.cell_id)); end if;
  end if;
  s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+reward);
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when defeated and not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'round',g.round_index,'redUsed',chosen->'redOnly','reward',reward));
  if defeated then insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'enemy_defeated',jsonb_build_object('playerId',player,'cellId',c.cell_id,'round',g.round_index,'name',coalesce(nullif(c.definition->>'name',''),'Gegner #'||c.cell_id))); end if;
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,g.revision);
end;
$$;

-- Die Hostentscheidung ist ausdrücklich, ab 60 Sekunden und ohne automatische
-- Entfernung. Überspringen ist eine Verwaltungsaktion ohne Lebensabzug.
create or replace function public.resolve_game_wait(p_session_token text,p_game_id uuid,p_round integer,p_target_player_id uuid,p_action text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;replay jsonb;payload jsonb:=jsonb_build_object('round',p_round,'target',p_target_player_id,'action',p_action);
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'wait',payload);if replay is not null then return replay; end if;
 if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY'); end if;
 if g.status<>'playing' or g.phase<>'choosing' then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.choice_started_at is null or now()<g.choice_started_at+interval '60 seconds' then return jsonb_build_object('ok',false,'error','GAME_WAIT_TOO_SHORT'); end if;
 if not exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
  where gp.game_id=g.id and gp.player_id=p_target_player_id and gp.active and not gp.eliminated and s.last_completed_round<g.round_index) then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if p_action is null or p_action not in ('skip','remove') or (p_action='remove' and p_target_player_id=player) then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 update public.dungeon_game_player_states set last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=p_target_player_id;
 if p_action='remove' then update public.dungeon_game_players set active=false,removed_at=now(),departure_reason='removed' where game_id=g.id and player_id=p_target_player_id; end if;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,case when p_action='skip' then 'turn_skipped' else 'removed' end,jsonb_build_object('playerId',p_target_player_id,'round',g.round_index));
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'wait',payload,g.revision);
end;
$$;

create or replace function dungeon_private.preserve_choice_clock()
returns trigger language plpgsql set search_path='' as $$
begin
 if old.status='paused' and new.status='playing' and old.paused_at is not null and new.choice_started_at is not null then
  new.choice_started_at:=new.choice_started_at+(now()-old.paused_at);
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_choice_clock on public.dungeon_games;
create trigger dungeon_choice_clock before update on public.dungeon_games for each row execute function dungeon_private.preserve_choice_clock();

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'dice',g.dice,'choiceStartedAt',g.choice_started_at,'finalRound',g.final_round,'serverNow',now(),
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'seat',gp.seat,
   'active',gp.active,'eliminated',gp.eliminated,'online',gp.last_seen_at>now()-interval '45 seconds',
   'turnDone',coalesce(s.last_completed_round>=g.round_index,false),'points',coalesce((s.state->>'diamonds')::int,0)*3+coalesce(dungeon_private.life_penalty(s.state),0)) order by gp.seat),'[]')
   from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id left join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id where gp.game_id=g.id and (gp.active or g.status in ('finished','cancelled'))),
  'ownState',(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),
  'turn',dungeon_private.game_turn_view(g,p_viewer),
  'states',(select coalesce(jsonb_agg(jsonb_build_object('playerId',s.player_id,'state',s.state,'revision',s.revision,'lastCompletedRound',s.last_completed_round)),'[]') from public.dungeon_game_player_states s where s.game_id=g.id and (s.player_id=p_viewer or g.settings->>'cards'='open')),
  'claims',(select coalesce(jsonb_agg(jsonb_build_object('cellId',c.monster_cell_id,'ownFirst',c.first_player_id=p_viewer)
   ||case when g.settings->>'cards'='open' or dungeon_private.has_reached((select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),c.monster_cell_id) then jsonb_build_object('playerId',c.first_player_id) else '{}'::jsonb end),'[]') from public.dungeon_game_monster_claims c where c.game_id=g.id),
  'events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.id),'[]') from (
   select id,kind,case when kind='enemy_defeated' and g.settings->>'cards'='hidden'
    and not dungeon_private.has_reached((select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),payload->>'cellId') then payload-'playerId' else payload end as payload,created_at as "createdAt"
   from public.dungeon_game_events where game_id=g.id and (kind in ('created','joined','left','removed','host_changed','started','paused','resumed','cancelled','finished','rolled','next_round','end_round_complete','enemy_defeated','turn_skipped')
    or (kind='life_lost' and payload->>'playerId'=p_viewer::text)) order by id desc limit 50) e))
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

-- Mit dem Spielzeilen-Lock gehört der gesamte gelesene Stand zu derselben
-- Revision: kein alter Wurf zusammen mit gerade neu geschriebenen Treffern.
create or replace function public.get_game(p_session_token text,p_game_id uuid,p_include_definition boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;membership public.dungeon_game_players%rowtype;
begin
 select * into g from public.dungeon_games where id=p_game_id for share;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 select * into membership from public.dungeon_game_players where game_id=g.id and player_id=player;
 if membership.player_id is not null and not membership.active and membership.departure_reason='removed' and g.status not in ('finished','cancelled') then return jsonb_build_object('ok',false,'error','GAME_REMOVED'); end if;
 if membership.player_id is null or (not membership.active and g.status not in ('finished','cancelled')) then
  if g.status='lobby' then return jsonb_build_object('ok',false,'error','GAME_JOIN_REQUIRED','lobby',dungeon_private.game_summary(g,player)); end if;
  return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');
 end if;
 if membership.active and g.status in ('lobby','playing','paused') then update public.dungeon_game_players set last_seen_at=clock_timestamp() where game_id=g.id and player_id=player; end if;
 return jsonb_build_object('ok',true,'game',dungeon_private.game_detail(g,player,p_include_definition));
end;
$$;
create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
revoke all on all functions in schema dungeon_private from public,anon,authenticated;
revoke all on function public.roll_game_dice(text,uuid,integer,uuid),public.play_game_turn(text,uuid,integer,bigint,text,text,boolean,uuid),public.resolve_game_wait(text,uuid,integer,uuid,text,uuid) from public;
grant execute on function public.roll_game_dice(text,uuid,integer,uuid),public.play_game_turn(text,uuid,integer,bigint,text,text,boolean,uuid),public.resolve_game_wait(text,uuid,integer,uuid,text,uuid) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(4) on conflict do nothing;
notify pgrst,'reload schema';
commit;
