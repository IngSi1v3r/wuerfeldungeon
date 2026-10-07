-- Würfeldungeon 0.5: vollständiger Prototyp, nach 008_phase4.sql ausführen.
-- Additives Update; keine Spieler, Karten oder laufenden Partien werden gelöscht.
begin;
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=4) then
  raise exception 'Bitte zuerst 008_phase4.sql installieren.';
 end if;
end$$;
alter table public.dungeon_games add column if not exists rules_version integer not null default 4;
alter table public.dungeon_games alter column rules_version set default 5;
alter table public.dungeon_game_results add column if not exists breakdown jsonb not null default '{}';
create table if not exists public.dungeon_game_task_claims (
 game_id uuid not null references public.dungeon_games(id) on delete cascade,
 task_key text not null check(task_key in ('special','custom')),
 first_player_id uuid not null,
 completed_in_round integer not null,
 primary key(game_id,task_key),
 foreign key(game_id,first_player_id) references public.dungeon_game_players(game_id,player_id)
);
alter table public.dungeon_game_task_claims enable row level security;
revoke all on public.dungeon_game_task_claims from anon,authenticated;

create or replace function dungeon_private.available_powerups(p_version uuid,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(v),'[]') from public.dungeon_map_versions m,
 jsonb_array_elements(m.allowed_powerups) v where m.id=p_version
 and not coalesce(s->'powerups','[]') @> jsonb_build_array(v);
$$;
create or replace function dungeon_private.task_progress(g public.dungeon_games,s jsonb,p_key text)
returns jsonb language plpgsql stable set search_path='' as $$
declare rules jsonb;goal jsonb;ids jsonb;total integer;done integer;
begin
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 if p_key='special' then ids:=coalesce(rules->'specialCellIds','[]');
 else
  goal:=rules->'customGoal';
  if goal->>'type'='none' then return jsonb_build_object('enabled',false,'completed',false,'progress',0,'total',0); end if;
  if goal->>'type'='collectDiamonds' then
   total:=(goal->>'diamonds')::int;done:=coalesce((s->>'diamonds')::int,0);
   return jsonb_build_object('enabled',true,'completed',done>=total,'progress',least(done,total),'total',total);
  end if;
  ids:=coalesce(goal->'cellIds','[]');
 end if;
 total:=jsonb_array_length(ids);
 select count(*)::int into done from jsonb_array_elements_text(ids) id where dungeon_private.has_reached(s,id);
 return jsonb_build_object('enabled',total>0,'completed',total>0 and done=total,'progress',done,'total',total);
end;
$$;
create or replace function dungeon_private.award_game_tasks(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare key text;first_id uuid;reward integer;
begin
 -- Reihenfolge ist fest: X-Aufgabe, dann individuelle Aufgabe. Gruppenboni
 -- des Bosses kommen erst am Ende und zählen nicht zum Sammelziel während des Spiels.
 foreach key in array array['special','custom'] loop
  if coalesce(s->'taskRewards','{}') ? key then continue; end if;
  if dungeon_private.task_progress(g,s,key)->'completed' <> 'true'::jsonb then continue; end if;
  insert into public.dungeon_game_task_claims(game_id,task_key,first_player_id,completed_in_round)
   values(g.id,key,p_player,g.round_index) on conflict do nothing;
  select first_player_id into first_id from public.dungeon_game_task_claims where game_id=g.id and task_key=key;
  reward:=case when first_id=p_player then 3 else 1 end;
  s:=s||jsonb_build_object('taskRewards',coalesce(s->'taskRewards','{}')||jsonb_build_object(key,reward),
   'diamonds',coalesce((s->>'diamonds')::int,0)+reward);
 end loop;
 return s;
end;
$$;
create or replace function dungeon_private.task_view(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb:='{}';key text;progress jsonb;claim uuid;
begin
 foreach key in array array['special','custom'] loop
  progress:=dungeon_private.task_progress(g,s,key);
  select first_player_id into claim from public.dungeon_game_task_claims where game_id=g.id and task_key=key;
  result:=result||jsonb_build_object(key,progress||jsonb_build_object(
   'completed',coalesce(s->'taskRewards','{}') ? key,'reward',s->'taskRewards'->key,'firstAvailable',claim is null)
   ||case when claim is not null and (g.settings->>'cards'='open' or coalesce(s->'taskRewards','{}') ? key)
    then jsonb_build_object('firstPlayerId',claim) else '{}'::jsonb end);
 end loop;
 return result;
end;
$$;

create or replace function dungeon_private.game_torch_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare middle public.dungeon_map_cells%rowtype;c public.dungeon_map_cells%rowtype;temporary jsonb;result jsonb:='[]';
 rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];
begin
 if coalesce((s->>'torchUses')::int,0)<1 or g.dice is null then return result; end if;
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 normal:=dungeon_private.dice_options(g.dice,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
 for middle in select * from public.dungeon_map_cells where version_id=g.map_version_id and kind not in ('monster','miniboss','boss') order by cell_id loop
  if not dungeon_private.cell_reachable(g.map_version_id,middle.cell_id,s) then continue; end if;
  temporary:=s||jsonb_build_object('reached',coalesce(s->'reached','[]')||jsonb_build_array(middle.cell_id));
  for c in select t.* from public.dungeon_map_cells t where t.version_id=g.map_version_id and not dungeon_private.has_reached(temporary,t.cell_id)
   and exists(select 1 from public.dungeon_map_connections e where e.version_id=g.map_version_id and
    ((e.cell_a=middle.cell_id and e.cell_b=t.cell_id) or (e.cell_b=middle.cell_id and e.cell_a=t.cell_id))) order by t.cell_id loop
   requirements:=dungeon_private.cell_requirements(c,rules,temporary);
   matches:=array(select n from unnest(requirements) n where n=any(normal));
   red_matches:=array(select n from unnest(requirements) n where n=any(red));
   if cardinality(matches)>0 or cardinality(red_matches)>0 then
    result:=result||jsonb_build_array(jsonb_build_object('cellId',c.cell_id,'middleCellId',middle.cell_id,
     'redOnly',cardinality(matches)=0,'attack',c.kind in ('monster','miniboss','boss'),
     'numbers',to_jsonb(case when cardinality(matches)>0 then matches else red_matches end)));
   end if;
  end loop;
 end loop;
 return result;
end;
$$;

-- Phase-4-Partien nachrüsten. Die historischen Zugereignisse bestimmen die
-- Reihenfolge der Erstbelohnungen; ein späteres Öffnen des Spielraums bevorzugt niemanden.
create or replace function dungeon_private.prepare_game_rules(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;simulations jsonb:='{}';e record;ps record;c public.dungeon_map_cells%rowtype;
 player uuid;s jsonb;added integer;hits integer;key text;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.rules_version>=5 or g.status not in ('playing','paused') then return; end if;
 for e in select payload from public.dungeon_game_events where game_id=g.id and kind='turn_played' order by id loop
  player:=(e.payload->>'playerId')::uuid;
  s:=coalesce(simulations->player::text,'{"reached":[],"monsterHits":{},"diamonds":0}'::jsonb);
  select * into c from public.dungeon_map_cells where version_id=g.map_version_id and cell_id=e.payload->>'cellId';
  if not found then continue; end if;
  if c.kind in ('monster','miniboss','boss') then
   hits:=least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0)+1);
   s:=s||jsonb_build_object('monsterHits',coalesce(s->'monsterHits','{}')||jsonb_build_object(c.cell_id,hits));
   if hits=(c.definition->>'hits')::int then s:=s||jsonb_build_object('reached',(s->'reached')||jsonb_build_array(c.cell_id)); end if;
  else s:=s||jsonb_build_object('reached',(s->'reached')||jsonb_build_array(c.cell_id)); end if;
  s:=s||jsonb_build_object('diamonds',(s->>'diamonds')::int+coalesce((e.payload->>'reward')::int,0));
  s:=dungeon_private.award_game_tasks(g,player,s);
  simulations:=simulations||jsonb_build_object(player::text,s);
 end loop;
 for ps in select * from public.dungeon_game_player_states where game_id=g.id order by player_id loop
  s:=ps.state;added:=0;
  foreach key in array array['special','custom'] loop
   if not coalesce(s->'taskRewards','{}') ? key and coalesce(simulations->ps.player_id::text->'taskRewards','{}') ? key then
    added:=added+(simulations->ps.player_id::text->'taskRewards'->>key)::int;
    s:=s||jsonb_build_object('taskRewards',coalesce(s->'taskRewards','{}')||jsonb_build_object(key,simulations->ps.player_id::text->'taskRewards'->key));
   end if;
  end loop;
  s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+added);
  s:=dungeon_private.award_game_tasks(g,ps.player_id,s);
  if jsonb_array_length(dungeon_private.available_powerups(g.map_version_id,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  if s is distinct from ps.state then update public.dungeon_game_player_states set state=s,revision=revision+1,updated_at=now() where game_id=g.id and player_id=ps.player_id; end if;
 end loop;
 update public.dungeon_games set rules_version=5,revision=revision+1,
  choice_started_at=case when choice_started_at is null and exists(select 1 from public.dungeon_game_player_states where game_id=g.id and jsonb_array_length(coalesce(state->'pendingChests','[]'))>0) then now() else choice_started_at end where id=g.id;
end;
$$;

create or replace function dungeon_private.finalize_game(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;ps record;s jsonb;bonus integer;defeated integer;top_points integer;details jsonb;tasks integer;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.status<>'playing' or exists(select 1 from public.dungeon_game_results where game_id=g.id) then return; end if;
 for ps in select st.*,gp.active,gp.eliminated from public.dungeon_game_player_states st join public.dungeon_game_players gp
  on gp.game_id=st.game_id and gp.player_id=st.player_id where st.game_id=g.id order by gp.seat loop
  s:=dungeon_private.award_game_tasks(g,ps.player_id,ps.state);
  select coalesce(sum(least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0))/3),0)::int into bonus
   from public.dungeon_map_cells c left join public.dungeon_game_monster_claims cl on cl.game_id=g.id and cl.monster_cell_id=c.cell_id
   where c.version_id=g.map_version_id and c.kind in ('boss','miniboss') and cl.first_player_id is distinct from ps.player_id;
  select count(*)::int into defeated from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and c.kind in ('monster','boss','miniboss') and dungeon_private.has_reached(s,c.cell_id);
  tasks:=coalesce((s->'taskRewards'->>'special')::int,0)+coalesce((s->'taskRewards'->>'custom')::int,0);
  details:=jsonb_build_object('earnedDiamonds',coalesce((s->>'diamonds')::int,0),'bossBonusDiamonds',bonus,
   'specialTaskDiamonds',coalesce((s->'taskRewards'->>'special')::int,0),'customTaskDiamonds',coalesce((s->'taskRewards'->>'custom')::int,0),
   'otherDiamonds',coalesce((s->>'diamonds')::int,0)-tasks,'lostLives',coalesce((s->>'lostLives')::int,0),'extraLives',coalesce((s->>'extraLives')::int,0));
  s:=s||jsonb_build_object('bossBonusDiamonds',bonus,'diamonds',coalesce((s->>'diamonds')::int,0)+bonus,'finalBreakdown',details);
  update public.dungeon_game_player_states set state=s,revision=revision+1,updated_at=now() where game_id=g.id and player_id=ps.player_id;
  insert into public.dungeon_game_results(game_id,player_id,total_points,diamonds,life_penalty,monsters_defeated,won,breakdown)
   values(g.id,ps.player_id,(s->>'diamonds')::int*3+dungeon_private.life_penalty(s),(s->>'diamonds')::int,dungeon_private.life_penalty(s),defeated,false,details);
 end loop;
 select max(r.total_points) into top_points from public.dungeon_game_results r join public.dungeon_game_players gp
  on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id and gp.active;
 update public.dungeon_game_results r set won=r.total_points=top_points where r.game_id=g.id
  and exists(select 1 from public.dungeon_game_players gp where gp.game_id=r.game_id and gp.player_id=r.player_id and gp.active);
 update public.dungeon_games set status='finished',phase='finished',finished_at=now(),revision=revision+1,final_round=coalesce(final_round,round_index) where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'finished',jsonb_build_object('round',g.round_index));
end;
$$;
create or replace function dungeon_private.settle_game_round(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;next_roller uuid;current_seat integer;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.status<>'playing' or g.phase not in ('choosing','round_complete','waiting_roll') then return; end if;
 if exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
  where gp.game_id=g.id and gp.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0) then return; end if;
 if g.phase='waiting_roll' then return; end if;
 if exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
  where gp.game_id=g.id and gp.active and not gp.eliminated and s.last_completed_round<g.round_index) then return; end if;
 if g.final_round is not null or not exists(select 1 from public.dungeon_game_players where game_id=g.id and active and not eliminated) then
  perform dungeon_private.finalize_game(g.id);
 else
  select seat into current_seat from public.dungeon_game_players where game_id=g.id and player_id=g.roller_id;
  select player_id into next_roller from public.dungeon_game_players where game_id=g.id and active and not eliminated order by (seat>current_seat) desc,seat limit 1;
  update public.dungeon_games set round_index=round_index+1,roller_id=next_roller,phase='waiting_roll',dice=null,choice_started_at=null where id=g.id;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'next_round',jsonb_build_object('round',g.round_index+1,'rollerId',next_roller));
 end if;
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
 standard_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='false'::jsonb);
 red_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='true'::jsonb);
 return jsonb_build_object('canRoll',coalesce(g.status='playing' and g.phase='waiting_roll' and g.roller_id=p_player and gp.active and not gp.eliminated,false)
   and not exists(select 1 from public.dungeon_game_players gp2 join public.dungeon_game_player_states s on s.game_id=gp2.game_id and s.player_id=gp2.player_id where gp2.game_id=g.id and gp2.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0),
  'canAct',ready,'done',coalesce(ps.last_completed_round>=g.round_index,false) and not pending,'standardPossible',standard_possible,'redPossible',red_possible,
  'torchPossible',jsonb_array_length(torch)>0,'canLoseLife',ready and not standard_possible,'ownRevision',ps.revision,'lastCompletedRound',ps.last_completed_round,
  'pendingPowerup',pending,'availablePowerups',dungeon_private.available_powerups(g.map_version_id,ps.state))
  ||case when g.settings->'hints'='true'::jsonb then jsonb_build_object('actions',actions,
   'options',to_jsonb(dungeon_private.dice_options(g.dice,g.roller_id=p_player)),
   'redOptions',to_jsonb(case when g.roller_id<>p_player and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.dice_options(g.dice,true)) n where not n=any(dungeon_private.dice_options(g.dice,false))) else '{}'::text[] end))
   else '{}'::jsonb end;
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
  if jsonb_array_length(dungeon_private.game_actions(g,ps.player_id,ps.state))=0 and jsonb_array_length(dungeon_private.game_torch_actions(g,ps.player_id,ps.state))=0 then
   perform dungeon_private.apply_life_loss(g.id,ps.player_id,g.round_index,g.revision,true);
  end if;
 end loop;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'roll',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function public.play_game_action(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid,p_middle_cell_id text default null,p_use_axe boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;c public.dungeon_map_cells%rowtype;middle public.dungeon_map_cells%rowtype;
 replay jsonb;payload jsonb:=jsonb_build_object('round',p_round,'stateRevision',p_state_revision,'action',p_action,'cellId',p_cell_id,'useRed',p_use_red);
 actions jsonb;chosen jsonb;s jsonb;hits integer;first_id uuid;reward integer:=0;defeated boolean:=false;intermediate_reward integer:=0;
begin
 if p_middle_cell_id is not null or p_use_axe then payload:=payload||jsonb_build_object('middleCellId',p_middle_cell_id,'useAxe',p_use_axe); end if;
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
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
   if not found or middle.kind in ('monster','miniboss','boss') or middle.cell_id=c.cell_id or not dungeon_private.cell_reachable(g.map_version_id,middle.cell_id,s) then return jsonb_build_object('ok',false,'error','GAME_TORCH_PATH'); end if;
   if not exists(select 1 from public.dungeon_map_connections e where e.version_id=g.map_version_id and ((e.cell_a=middle.cell_id and e.cell_b=c.cell_id) or (e.cell_b=middle.cell_id and e.cell_a=c.cell_id))) then return jsonb_build_object('ok',false,'error','GAME_TORCH_PATH'); end if;
   s:=s||jsonb_build_object('reached',coalesce(s->'reached','[]')||jsonb_build_array(middle.cell_id));
   actions:=dungeon_private.game_actions(g,player,s);
  elsif not dungeon_private.cell_reachable(g.map_version_id,c.cell_id,s) then return jsonb_build_object('ok',false,'error','GAME_CELL_UNREACHABLE'); end if;
  select a into chosen from jsonb_array_elements(actions) a where a->>'cellId'=c.cell_id;
  if chosen is null then return jsonb_build_object('ok',false,'error','GAME_NUMBER_MISMATCH'); end if;
  if chosen->'redOnly'='true'::jsonb and not p_use_red then return jsonb_build_object('ok',false,'error','GAME_RED_CONFIRMATION'); end if;
  if p_use_axe and (c.kind not in ('monster','miniboss','boss') or coalesce((s->>'axeUses')::int,0)<1) then return jsonb_build_object('ok',false,'error','GAME_AXE_UNAVAILABLE'); end if;
  -- Erst nach vollständiger Prüfung Kosten und Belohnungen anwenden.
  if p_middle_cell_id is not null then
   s:=s||jsonb_build_object('torchUses',(s->>'torchUses')::int-1);
   if middle.kind='diamond' then intermediate_reward:=1;
   elsif middle.kind='chest' then s:=s||jsonb_build_object('pendingChests',coalesce(s->'pendingChests','[]')||jsonb_build_array(middle.cell_id)); end if;
  end if;
  if chosen->'redOnly'='true'::jsonb then s:=s||jsonb_build_object('redUses',(s->>'redUses')::int-1); end if;
  if p_use_axe then s:=s||jsonb_build_object('axeUses',(s->>'axeUses')::int-1); end if;
  if c.kind in ('monster','miniboss','boss') then
   hits:=least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0)+case when p_use_axe then 2 else 1 end);
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
  s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+reward+intermediate_reward);
  s:=dungeon_private.award_game_tasks(g,player,s);
  if jsonb_array_length(dungeon_private.available_powerups(g.map_version_id,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when defeated and not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'middleCellId',p_middle_cell_id,'axeUsed',p_use_axe,'round',g.round_index,'redUsed',chosen->'redOnly','reward',reward+intermediate_reward));
  if defeated then insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'enemy_defeated',jsonb_build_object('playerId',player,'cellId',c.cell_id,'round',g.round_index,'name',coalesce(nullif(c.definition->>'name',''),'Gegner #'||c.cell_id))); end if;
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;
-- Alte Clients und bereits gesendete Befehle behalten ihre Signatur und Request-Hashes.
create or replace function public.play_game_turn(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid)
returns jsonb language sql security definer set search_path='' as $$
 select public.play_game_action(p_session_token,p_game_id,p_round,p_state_revision,p_action,p_cell_id,p_use_red,p_request_id,null,false);
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
 if p_powerup is null or not dungeon_private.available_powerups(g.map_version_id,s) @> jsonb_build_array(p_powerup) then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE'); end if;
 s:=s||jsonb_build_object('pendingChests',(select coalesce(jsonb_agg(id),'[]') from jsonb_array_elements_text(s->'pendingChests') id where id<>p_chest_cell_id),
  'powerups',coalesce(s->'powerups','[]')||jsonb_build_array(p_powerup));
 if p_powerup='extraLife' then s:=s||jsonb_build_object('extraLives',coalesce((s->>'extraLives')::int,0)+3,'diamonds',coalesce((s->>'diamonds')::int,0)+1);
 elsif p_powerup='redDice' then s:=s||jsonb_build_object('redUses',coalesce((s->>'redUses')::int,0)+3);
 elsif p_powerup='torch' then s:=s||jsonb_build_object('torchUses',2);
 elsif p_powerup='axe' then s:=s||jsonb_build_object('axeUses',2); end if;
 s:=dungeon_private.award_game_tasks(g,player,s);
 if jsonb_array_length(dungeon_private.available_powerups(g.map_version_id,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
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
create or replace function public.get_torch_options(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;
begin
 select * into g from public.dungeon_games where id=p_game_id for share;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if g.status<>'playing' or g.phase<>'choosing' or ps.last_completed_round>=g.round_index then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED'); end if;
 if jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0 then return jsonb_build_object('ok',false,'error','GAME_POWERUP_PENDING'); end if;
 return jsonb_build_object('ok',true,'actions',case when g.settings->'hints'='true'::jsonb then dungeon_private.game_torch_actions(g,player,ps.state) else '[]'::jsonb end);
end;
$$;

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'dice',g.dice,'choiceStartedAt',g.choice_started_at,'finalRound',g.final_round,'serverNow',now(),'rulesVersion',g.rules_version,
  'tasks',dungeon_private.task_view(g,p_viewer,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'results',case when g.status='finished' then dungeon_private.game_result_json(g,p_viewer)->'results' else '[]'::jsonb end,
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'seat',gp.seat,
   'active',gp.active,'eliminated',gp.eliminated,'online',gp.last_seen_at>now()-interval '45 seconds',
   'turnDone',coalesce(s.last_completed_round>=g.round_index,false) and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))=0,
   'hasPendingPowerup',jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0,'points',coalesce((s.state->>'diamonds')::int,0)*3+coalesce(dungeon_private.life_penalty(s.state),0)) order by gp.seat),'[]')
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
    or (kind in ('life_lost','powerup_chosen') and payload->>'playerId'=p_viewer::text)) order by id desc limit 50) e))
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

create or replace function dungeon_private.game_result_json(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object('results',(select coalesce(jsonb_agg(jsonb_build_object(
  'playerId',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'points',r.total_points,'diamonds',r.diamonds,
  'lifePenalty',r.life_penalty,'monstersDefeated',r.monsters_defeated,'won',r.won,'breakdown',r.breakdown,'eliminated',gp.eliminated,'removed',not gp.active) order by r.total_points desc,gp.seat),'[]')
  from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id join public.dungeon_game_players gp on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id));
$$;

create or replace function public.get_game(p_session_token text,p_game_id uuid,p_include_definition boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;membership public.dungeon_game_players%rowtype;
begin
 -- FOR UPDATE synchronisiert auch einmalige Nachrüstung und Schlusswertung.
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 select * into membership from public.dungeon_game_players where game_id=g.id and player_id=player;
 if membership.player_id is not null and not membership.active and membership.departure_reason='removed' and g.status not in ('finished','cancelled') then return jsonb_build_object('ok',false,'error','GAME_REMOVED'); end if;
 if membership.player_id is null or (not membership.active and g.status not in ('finished','cancelled')) then
  if g.status='lobby' then return jsonb_build_object('ok',false,'error','GAME_JOIN_REQUIRED','lobby',dungeon_private.game_summary(g,player)); end if;
  return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');
 end if;
 perform dungeon_private.prepare_game_rules(g.id);
 perform dungeon_private.settle_game_round(g.id);
 select * into g from public.dungeon_games where id=g.id;
 if membership.active and g.status in ('lobby','playing','paused') then update public.dungeon_game_players set last_seen_at=clock_timestamp() where game_id=g.id and player_id=player; end if;
 return jsonb_build_object('ok',true,'game',dungeon_private.game_detail(g,player,p_include_definition));
end;
$$;

create or replace function public.resolve_game_wait(p_session_token text,p_game_id uuid,p_round integer,p_target_player_id uuid,p_action text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;gp public.dungeon_game_players%rowtype;replay jsonb;
 payload jsonb:=jsonb_build_object('round',p_round,'target',p_target_player_id,'action',p_action);current_seat integer;next_roller uuid;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'wait',payload);if replay is not null then return replay; end if;
 if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY'); end if;
 if g.status<>'playing' or g.phase not in ('choosing','round_complete','waiting_roll') then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if g.choice_started_at is null or now()<g.choice_started_at+interval '60 seconds' then return jsonb_build_object('ok',false,'error','GAME_WAIT_TOO_SHORT'); end if;
 select * into gp from public.dungeon_game_players where game_id=g.id and player_id=p_target_player_id;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=p_target_player_id;
 if not coalesce(gp.active,false) or not ((not gp.eliminated and g.phase='choosing' and ps.last_completed_round<g.round_index) or jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0) then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if p_action is null or p_action not in ('skip','remove') or (p_action='remove' and p_target_player_id=player) then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 update public.dungeon_game_player_states set state=state||jsonb_build_object('pendingChests','[]'::jsonb),
  last_completed_round=case when g.phase='choosing' then g.round_index else last_completed_round end,revision=revision+1,updated_at=now() where game_id=g.id and player_id=p_target_player_id;
 if p_action='remove' then
  update public.dungeon_game_players set active=false,removed_at=now(),departure_reason='removed' where game_id=g.id and player_id=p_target_player_id;
  if g.phase='waiting_roll' and g.roller_id=p_target_player_id then
   select seat into current_seat from public.dungeon_game_players where game_id=g.id and player_id=p_target_player_id;
   select player_id into next_roller from public.dungeon_game_players where game_id=g.id and active and not eliminated order by (seat>current_seat) desc,seat limit 1;
   update public.dungeon_games set roller_id=next_roller where id=g.id;
  end if;
 end if;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,case when p_action='skip' then 'turn_skipped' else 'removed' end,jsonb_build_object('playerId',p_target_player_id,'round',g.round_index,'pendingChoicesSkipped',jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))));
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'wait',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;
create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
revoke all on all functions in schema dungeon_private from public,anon,authenticated;
revoke all on function public.play_game_action(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean),
 public.choose_game_powerup(text,uuid,text,bigint,text,uuid),public.get_torch_options(text,uuid,integer,bigint) from public;
grant execute on function public.play_game_action(text,uuid,integer,bigint,text,text,boolean,uuid,text,boolean),
 public.choose_game_powerup(text,uuid,text,bigint,text,uuid),public.get_torch_options(text,uuid,integer,bigint) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(5) on conflict do nothing;
notify pgrst,'reload schema';
commit;
