-- Würfeldungeon 0.7.0: Online-Regeln für Kartenversion 7.
-- Zusätzlich zu 014_editor_upgrade.sql ausführen. Bestehende Partien bleiben v5.
begin;
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=7) then
  raise exception 'Bitte zuerst 014_editor_upgrade.sql installieren.';
 end if;
end$$;
alter table public.dungeon_games alter column rules_version set default 7;
alter table public.dungeon_games add column if not exists round_requirements jsonb not null default '{}';
-- Fallen dürfen den Diamantensaldo unter null bringen.
alter table public.dungeon_game_results drop constraint if exists dungeon_game_results_diamonds_check;
create table if not exists public.dungeon_game_trap_claims (
 game_id uuid not null,
 map_version_id uuid not null,
 cell_id text not null,
 activated_in_round integer not null check(activated_in_round>0),
 primary key(game_id,cell_id),
 foreign key(game_id,map_version_id) references public.dungeon_games(id,map_version_id) on delete cascade,
 foreign key(map_version_id,cell_id) references public.dungeon_map_cells(version_id,cell_id)
);
alter table public.dungeon_game_trap_claims enable row level security;
revoke all on public.dungeon_game_trap_claims from public,anon,authenticated;


create or replace function dungeon_private.game_actions_v5(g public.dungeon_games,p_player uuid,s jsonb)
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

create or replace function dungeon_private.game_torch_actions_v5(g public.dungeon_games,p_player uuid,s jsonb)
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

create or replace function dungeon_private.task_progress_v5(g public.dungeon_games,s jsonb,p_key text)
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

create or replace function dungeon_private.award_game_tasks_v5(g public.dungeon_games,p_player uuid,s jsonb)
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

create or replace function dungeon_private.task_view_v5(g public.dungeon_games,p_player uuid,s jsonb)
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

create or replace function dungeon_private.finalize_game_v5(p_game uuid)
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

create or replace function dungeon_private.play_game_action_v5(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid,p_middle_cell_id text default null,p_use_axe boolean default false)
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


create or replace function dungeon_private.game_settings_valid(s jsonb)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(jsonb_typeof(s)='object' and dungeon_private.json_int(s->'maxPlayers',2,16)
  and s->>'cards' in ('open','hidden') and jsonb_typeof(s->'hints')='boolean'
  and (not s ? 'diceHints' or jsonb_typeof(s->'diceHints')='boolean')
  and (not s ? 'fieldHints' or jsonb_typeof(s->'fieldHints')='boolean')
  and (not s ? 'fog' or jsonb_typeof(s->'fog')='boolean'),false);
$$;
create or replace function dungeon_private.random_index(n integer)
returns integer language plpgsql volatile set search_path='' as $$
declare b bytea;v bigint;limit_value bigint;
begin
 if n<1 or n>10000 then raise exception 'Invalid random pool'; end if;
 limit_value:=(4294967296::bigint/n)*n;
 loop
  b:=decode(dungeon_private.new_token(),'hex');
  v:=get_byte(b,0)::bigint*16777216+get_byte(b,1)::bigint*65536+get_byte(b,2)::bigint*256+get_byte(b,3);
  if v<limit_value then return (v%n)::integer; end if;
 end loop;
end;
$$;
-- Genau einmal beim Rundenwechsel; Lesen, Wiederverbinden und Würfel-Retries
-- ändern keine Zahl. Alle Spieler verwenden denselben gespeicherten Wert.
create or replace function dungeon_private.prepare_round_cells()
returns trigger language plpgsql security definer set search_path='' as $$
declare c record;values_by_cell jsonb:='{}';
begin
 if new.rules_version<7 or new.round_index<1 then return new; end if;
 if tg_op='UPDATE' then
  if new.round_index=old.round_index and new.rules_version=old.rules_version and new.map_version_id=old.map_version_id then return new; end if;
 end if;
 for c in select cell_id,definition->'requirements' as pool from public.dungeon_map_cells where version_id=new.map_version_id and kind='crazy' order by cell_id loop
  values_by_cell:=values_by_cell||jsonb_build_object(c.cell_id,c.pool->dungeon_private.random_index(jsonb_array_length(c.pool)));
 end loop;
 new.round_requirements:=values_by_cell;return new;
end;
$$;
drop trigger if exists dungeon_game_round_cells on public.dungeon_games;
create trigger dungeon_game_round_cells before insert or update on public.dungeon_games for each row execute function dungeon_private.prepare_round_cells();

create or replace function dungeon_private.game_enemy(c public.dungeon_map_cells)
returns boolean language sql immutable set search_path='' as $$
 select c.kind in ('monster','boss','miniboss','bonus');
$$;
create or replace function dungeon_private.game_available_powerups(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements(dungeon_private.available_powerups(g.map_version_id,s)) value
  where g.rules_version<7 or value<>'"binocular"'::jsonb or g.settings->'fog'='true'::jsonb;
$$;
create or replace function dungeon_private.game_cell_requirements(g public.dungeon_games,c public.dungeon_map_cells,rules jsonb,s jsonb)
returns text[] language sql stable set search_path='' as $$
 select case when c.kind='crazy' then case when g.round_requirements->>c.cell_id is null then '{}'::text[] else array[g.round_requirements->>c.cell_id] end
 when c.kind='bonus' then array(select a->>'number' from jsonb_array_elements(c.definition->'attacks') a where a->>'state'='active'
   or exists(select 1 from jsonb_array_elements(coalesce(rules->'unlocks','[]')) u where u->>'targetCellId'=c.cell_id and u->'number'=a->'number' and dungeon_private.has_reached(s,u->>'sourceCellId')))
 else dungeon_private.cell_requirements(c,rules,s) end;
$$;
-- Reines Vorschau-Erreichen, ohne Fallen, Belohnungen oder andere Schreibvorgänge.
create or replace function dungeon_private.preview_reach(g public.dungeon_games,s jsonb,p_cell text)
returns jsonb language plpgsql stable set search_path='' as $$
declare pair jsonb;other_cell text;rules jsonb;
begin
 if not dungeon_private.has_reached(s,p_cell) then s:=s||jsonb_build_object('reached',coalesce(s->'reached','[]')||jsonb_build_array(p_cell)); end if;
 select v.rules into rules from public.dungeon_map_versions v where v.id=g.map_version_id;
 for pair in select value from jsonb_array_elements(coalesce(rules->'portalPairs','[]')) loop
  if pair->>0=p_cell then other_cell:=pair->>1;elsif pair->>1=p_cell then other_cell:=pair->>0;else continue;end if;
  if not dungeon_private.has_reached(s,other_cell) then s:=s||jsonb_build_object('reached',s->'reached'||jsonb_build_array(other_cell)); end if;
 end loop;
 return s;
end;
$$;
create or replace function dungeon_private.torch_target_linked(g public.dungeon_games,s jsonb,p_middle text,p_target text)
returns boolean language sql stable set search_path='' as $$
 select not dungeon_private.has_reached(dungeon_private.preview_reach(g,s,p_middle),p_target)
  and exists(select 1 from public.dungeon_map_connections e where e.version_id=g.map_version_id and
   ((e.cell_a=p_target and dungeon_private.has_reached(dungeon_private.preview_reach(g,s,p_middle),e.cell_b) and not dungeon_private.has_reached(s,e.cell_b))
    or (e.cell_b=p_target and dungeon_private.has_reached(dungeon_private.preview_reach(g,s,p_middle),e.cell_a) and not dungeon_private.has_reached(s,e.cell_a))));
$$;
create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind='normal' and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;


create or replace function dungeon_private.game_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.rules_version<7 then return dungeon_private.game_actions_v5(g,p_player,s); end if;
 if g.dice is null then return result; end if;
 normal:=dungeon_private.dice_options(g.dice,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
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
 normal:=dungeon_private.dice_options(g.dice,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
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


create or replace function dungeon_private.game_goal(g public.dungeon_games,p_key text)
returns jsonb language sql stable set search_path='' as $$
 select case when v.definition_version=2 then v.rules->'goals'->case when p_key='special' then 0 else 1 end
  when p_key='special' then jsonb_build_object('type','reachFields','cellIds',coalesce(v.rules->'specialCellIds','[]'),'reward',jsonb_build_object('first',3,'later',1))
  else v.rules->'customGoal'||jsonb_build_object('reward',jsonb_build_object('first',3,'later',1)) end
 from public.dungeon_map_versions v where v.id=g.map_version_id;
$$;
create or replace function dungeon_private.task_progress(g public.dungeon_games,s jsonb,p_key text)
returns jsonb language plpgsql stable set search_path='' as $$
declare goal jsonb;ids jsonb;total integer;progress integer;connected boolean:=false;blocked boolean:=false;completed_ids jsonb;
begin
 if g.rules_version<7 then return dungeon_private.task_progress_v5(g,s,p_key); end if;
 goal:=dungeon_private.game_goal(g,p_key);
 if goal is null or goal->>'type'='none' then return jsonb_build_object('enabled',false,'progress',0,'total',0,'completed',false); end if;
 ids:=coalesce(goal->'cellIds','[]');total:=jsonb_array_length(ids);
 select coalesce(jsonb_agg(id order by id),'[]') into completed_ids from jsonb_array_elements_text(ids) id where dungeon_private.has_reached(s,id)
  and (goal->>'type'<>'firstEnemies' or coalesce(s->'firstKills','[]') ? id);
 progress:=jsonb_array_length(completed_ids);
 if goal->>'type'='collectDiamonds' then total:=(goal->>'diamonds')::int;progress:=greatest(0,coalesce((s->>'diamonds')::int,0));
 elsif goal->>'type'='firstEnemies' then
  blocked:=exists(select 1 from jsonb_array_elements_text(ids) id join public.dungeon_game_monster_claims cl on cl.game_id=g.id and cl.monster_cell_id=id
   where cl.claimed_in_round<g.round_index and not coalesce(s->'firstKills','[]') ? id);
 elsif goal->>'type'='connect' and total=2 then
  with recursive path(cell_id) as (
   select ids->>0 where dungeon_private.has_reached(s,ids->>0)
   union
   select case when e.cell_a=p.cell_id then e.cell_b else e.cell_a end from path p join public.dungeon_map_connections e
    on e.version_id=g.map_version_id and (e.cell_a=p.cell_id or e.cell_b=p.cell_id)
    where dungeon_private.has_reached(s,case when e.cell_a=p.cell_id then e.cell_b else e.cell_a end)
  ) select exists(select 1 from path where cell_id=ids->>1) into connected;
 end if;
 return jsonb_build_object('enabled',true,'type',goal->'type','fieldType',goal->'fieldType','cellIds',ids,'completedIds',completed_ids,
  'progress',progress,'total',total,'blocked',blocked,'rewardFirst',goal->'reward'->'first','rewardLater',goal->'reward'->'later',
  'completed',not blocked and total>0 and case when goal->>'type'='connect' then connected else progress>=total end);
end;
$$;
create or replace function dungeon_private.award_game_tasks(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare key text;progress jsonb;claim_round integer;goal jsonb;reward integer;pass integer;
begin
 if g.rules_version<7 then return dungeon_private.award_game_tasks_v5(g,p_player,s); end if;
 -- Zwei Durchgänge decken auch ab, dass Aufgabe 2 das Sammelziel in Aufgabe 1 erfüllt.
 for pass in 1..2 loop
  foreach key in array array['special','custom'] loop
   if coalesce(s->'taskRewards','{}') ? key then continue; end if;
   progress:=dungeon_private.task_progress(g,s,key);if progress->'completed'<>'true'::jsonb then continue; end if;
   insert into public.dungeon_game_task_claims(game_id,task_key,first_player_id,completed_in_round) values(g.id,key,p_player,g.round_index) on conflict do nothing;
   select completed_in_round into claim_round from public.dungeon_game_task_claims where game_id=g.id and task_key=key;
   goal:=dungeon_private.game_goal(g,key);reward:=(goal->'reward'->>case when claim_round=g.round_index then 'first' else 'later' end)::int;
   s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+reward,'taskRewards',coalesce(s->'taskRewards','{}')||jsonb_build_object(key,reward),
    'taskCompletionRounds',coalesce(s->'taskCompletionRounds','{}')||jsonb_build_object(key,g.round_index));
  end loop;
 end loop;
 return s;
end;
$$;
create or replace function dungeon_private.task_view(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb:='{}';key text;progress jsonb;claim public.dungeon_game_task_claims%rowtype;
begin
 if g.rules_version<7 then return dungeon_private.task_view_v5(g,p_player,s); end if;
 foreach key in array array['special','custom'] loop
  progress:=dungeon_private.task_progress(g,s,key);select * into claim from public.dungeon_game_task_claims where game_id=g.id and task_key=key;
  progress:=progress||jsonb_build_object('completed',coalesce(s->'taskRewards','{}') ? key,'firstAvailable',g.status not in ('finished','cancelled') and (claim.game_id is null or claim.completed_in_round=g.round_index),'reward',s->'taskRewards'->key);
  if g.settings->>'cards'='open' or coalesce(s->'taskRewards','{}') ? key then progress:=progress||jsonb_build_object('firstPlayerId',claim.first_player_id); end if;
  result:=result||jsonb_build_object(key,progress);
 end loop;return result;
end;
$$;
-- Wird nur nach vollständiger Prüfung der gesamten Aktion aufgerufen.
create or replace function dungeon_private.reach_game_cell(g public.dungeon_games,p_player uuid,s jsonb,c public.dungeon_map_cells)
returns jsonb language plpgsql security definer set search_path='' as $$
declare arm_round integer;cost integer;
begin
 if dungeon_private.has_reached(s,c.cell_id) then return s; end if;
 s:=dungeon_private.preview_reach(g,s,c.cell_id);
 if c.kind='diamond' then s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+1);
 elsif c.kind in ('goldSack','goldCoin') then s:=s||jsonb_build_object('goldPoints',coalesce((s->>'goldPoints')::int,0)+case when c.kind='goldSack' then 2 else 1 end);
 elsif c.kind='chest' then s:=s||jsonb_build_object('pendingChests',coalesce(s->'pendingChests','[]')||jsonb_build_array(c.cell_id));
 elsif c.kind='trap' then
  insert into public.dungeon_game_trap_claims(game_id,map_version_id,cell_id,activated_in_round) values(g.id,g.map_version_id,c.cell_id,g.round_index) on conflict do nothing;
  select activated_in_round into arm_round from public.dungeon_game_trap_claims where game_id=g.id and cell_id=c.cell_id;
  if arm_round<g.round_index then
   cost:=(c.definition->>'trapCost')::int;
   if c.definition->>'trapKind'='life' then s:=s||jsonb_build_object('lostLives',coalesce((s->>'lostLives')::int,0)+cost);
   else s:=s||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)-cost);end if;
   insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision+1,'trap_triggered',jsonb_build_object('playerId',p_player,'cellId',c.cell_id,'round',g.round_index,'cost',cost,'costKind',c.definition->'trapKind'));
   if c.definition->>'trapKind'='life' then
    insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision+1,'life_lost',jsonb_build_object('playerId',p_player,'round',g.round_index,'automatic',false,'cause','trap','amount',cost));
   end if;
  end if;
 end if;return s;
end;
$$;


create or replace function public.play_game_action(p_session_token text,p_game_id uuid,p_round integer,p_state_revision bigint,p_action text,p_cell_id text,p_use_red boolean,p_request_id uuid,p_middle_cell_id text default null,p_use_axe boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;c public.dungeon_map_cells%rowtype;middle public.dungeon_map_cells%rowtype;
 replay jsonb;payload jsonb:=jsonb_build_object('round',p_round,'stateRevision',p_state_revision,'action',p_action,'cellId',p_cell_id,'useRed',p_use_red);
 actions jsonb;chosen jsonb;s jsonb;hits integer;first_id uuid;reward integer:=0;defeated boolean:=false;intermediate_reward integer:=0;claim_round integer;temporary jsonb;
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
  if p_use_axe then s:=s||jsonb_build_object('axeUses',(s->>'axeUses')::int-1); end if;
  if dungeon_private.game_enemy(c) then
   hits:=least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0)+case when p_use_axe then 2 else 1 end);
   s:=s||jsonb_build_object('monsterHits',coalesce(s->'monsterHits','{}')||jsonb_build_object(c.cell_id,hits));
   defeated:=hits=(c.definition->>'hits')::int;
   if defeated then
    insert into public.dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values(g.id,g.map_version_id,c.cell_id,player,g.round_index) on conflict do nothing;
    select claimed_in_round into claim_round from public.dungeon_game_monster_claims where game_id=g.id and monster_cell_id=c.cell_id;
    reward:=(c.definition->>case when claim_round=g.round_index then 'rewardFirst' else 'rewardLater' end)::int;
    s:=dungeon_private.preview_reach(g,s,c.cell_id)||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+reward,
     'enemyCompletionRounds',coalesce(s->'enemyCompletionRounds','{}')||jsonb_build_object(c.cell_id,g.round_index));
    if claim_round=g.round_index then s:=s||jsonb_build_object('firstKills',coalesce(s->'firstKills','[]')||jsonb_build_array(c.cell_id)); end if;
   end if;
  else s:=dungeon_private.reach_game_cell(g,player,s,c);end if;
  s:=dungeon_private.award_game_tasks(g,player,s);
  if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  update public.dungeon_game_players set eliminated=coalesce((s->>'lostLives')::int,0)>=11+coalesce((s->>'extraLives')::int,0) where game_id=g.id and player_id=player;
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when defeated and not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'middleCellId',p_middle_cell_id,'axeUsed',p_use_axe,'round',g.round_index,'redUsed',chosen->'redOnly','reward',reward+intermediate_reward));
  if defeated then insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,case when c.kind='bonus' then 'bonus_completed' else 'enemy_defeated' end,jsonb_build_object('playerId',player,'cellId',c.cell_id,'round',g.round_index,'name',coalesce(nullif(c.definition->>'name',''),'Gegner #'||c.cell_id))); end if;
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function dungeon_private.finalize_game(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;ps record;s jsonb;bonus integer;defeated integer;top_points integer;details jsonb;tasks integer;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.rules_version<7 then perform dungeon_private.finalize_game_v5(p_game);return;end if;
 if g.status<>'playing' or exists(select 1 from public.dungeon_game_results where game_id=g.id) then return; end if;
 for ps in select st.*,gp.active,gp.eliminated from public.dungeon_game_player_states st join public.dungeon_game_players gp
  on gp.game_id=st.game_id and gp.player_id=st.player_id where st.game_id=g.id order by gp.seat loop
  s:=dungeon_private.award_game_tasks(g,ps.player_id,ps.state);
  select coalesce(sum(least((c.definition->>'hits')::int,coalesce((s->'monsterHits'->>c.cell_id)::int,0))/3),0)::int into bonus
   from public.dungeon_map_cells c left join public.dungeon_game_monster_claims cl on cl.game_id=g.id and cl.monster_cell_id=c.cell_id
   where c.version_id=g.map_version_id and c.kind in ('boss','miniboss') and not coalesce(s->'firstKills','[]') ? c.cell_id;
  select count(*)::int into defeated from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and c.kind in ('monster','boss','miniboss') and dungeon_private.has_reached(s,c.cell_id);
  tasks:=coalesce((s->'taskRewards'->>'special')::int,0)+coalesce((s->'taskRewards'->>'custom')::int,0);
  details:=jsonb_build_object('earnedDiamonds',coalesce((s->>'diamonds')::int,0),'bossBonusDiamonds',bonus,
   'specialTaskDiamonds',coalesce((s->'taskRewards'->>'special')::int,0),'customTaskDiamonds',coalesce((s->'taskRewards'->>'custom')::int,0),
   'goldPoints',coalesce((s->>'goldPoints')::int,0),'bonusTasksCompleted',(select count(*) from public.dungeon_map_cells b where b.version_id=g.map_version_id and b.kind='bonus' and dungeon_private.has_reached(s,b.cell_id)),
   'otherDiamonds',coalesce((s->>'diamonds')::int,0)-tasks,'lostLives',coalesce((s->>'lostLives')::int,0),'extraLives',coalesce((s->>'extraLives')::int,0));
  s:=s||jsonb_build_object('bossBonusDiamonds',bonus,'diamonds',coalesce((s->>'diamonds')::int,0)+bonus,'finalBreakdown',details);
  update public.dungeon_game_player_states set state=s,revision=revision+1,updated_at=now() where game_id=g.id and player_id=ps.player_id;
  insert into public.dungeon_game_results(game_id,player_id,total_points,diamonds,life_penalty,monsters_defeated,won,breakdown)
   values(g.id,ps.player_id,(s->>'diamonds')::int*3+coalesce((s->>'goldPoints')::int,0)+dungeon_private.life_penalty(s),(s->>'diamonds')::int,dungeon_private.life_penalty(s),defeated,false,details);
 end loop;
 select max(r.total_points) into top_points from public.dungeon_game_results r join public.dungeon_game_players gp
  on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id and gp.active;
 update public.dungeon_game_results r set won=r.total_points=top_points where r.game_id=g.id
  and exists(select 1 from public.dungeon_game_players gp where gp.game_id=r.game_id and gp.player_id=r.player_id and gp.active);
 update public.dungeon_games set status='finished',phase='finished',finished_at=now(),revision=revision+1,final_round=coalesce(final_round,round_index) where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'finished',jsonb_build_object('round',g.round_index));
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
  'pendingPowerup',pending,'availablePowerups',dungeon_private.game_available_powerups(g,ps.state))
  ||case when coalesce(g.settings->'fieldHints',g.settings->'hints')='true'::jsonb then jsonb_build_object('actions',actions) else '{}'::jsonb end
  ||case when coalesce(g.settings->'diceHints',g.settings->'hints')='true'::jsonb then jsonb_build_object(
   'options',to_jsonb(dungeon_private.dice_options(g.dice,g.roller_id=p_player)),
   'redOptions',to_jsonb(case when g.roller_id<>p_player and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.dice_options(g.dice,true)) n where not n=any(dungeon_private.dice_options(g.dice,false))) else '{}'::text[] end)) else '{}'::jsonb end;
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
 return jsonb_build_object('ok',true,'actions',case when coalesce(g.settings->'fieldHints',g.settings->'hints')='true'::jsonb then dungeon_private.game_torch_actions(g,player,ps.state) else '[]'::jsonb end);
end;
$$;

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'roundRequirements',g.round_requirements,'visibleCells',dungeon_private.game_visible_cells(g,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'traps',(select coalesce(jsonb_agg(jsonb_build_object('cellId',cell_id,'activatedInRound',activated_in_round,'armed',activated_in_round<g.round_index)),'[]') from public.dungeon_game_trap_claims where game_id=g.id),
  'dice',g.dice,'choiceStartedAt',g.choice_started_at,'finalRound',g.final_round,'serverNow',now(),'rulesVersion',g.rules_version,
  'tasks',dungeon_private.task_view(g,p_viewer,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'results',case when g.status='finished' then dungeon_private.game_result_json(g,p_viewer)->'results' else '[]'::jsonb end,
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'seat',gp.seat,
   'active',gp.active,'eliminated',gp.eliminated,'online',gp.last_seen_at>now()-interval '45 seconds',
   'turnDone',coalesce(s.last_completed_round>=g.round_index,false) and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))=0,
   'hasPendingPowerup',jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0,'points',coalesce((s.state->>'diamonds')::int,0)*3+coalesce((s.state->>'goldPoints')::int,0)+coalesce(dungeon_private.life_penalty(s.state),0)) order by gp.seat),'[]')
   from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id left join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id where gp.game_id=g.id and (gp.active or g.status in ('finished','cancelled'))),
  'ownState',(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),
  'turn',dungeon_private.game_turn_view(g,p_viewer),
  'states',(select coalesce(jsonb_agg(jsonb_build_object('playerId',s.player_id,'state',s.state,'revision',s.revision,'lastCompletedRound',s.last_completed_round,'visibleCells',dungeon_private.game_visible_cells(g,s.state))),'[]') from public.dungeon_game_player_states s where s.game_id=g.id and (s.player_id=p_viewer or g.settings->>'cards'='open')),
  'claims',(select coalesce(jsonb_agg(jsonb_build_object('cellId',c.monster_cell_id,'ownFirst',case when g.rules_version>=7 then coalesce((select state->'firstKills' from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),'[]') ? c.monster_cell_id else c.first_player_id=p_viewer end,
    'firstAvailable',g.rules_version>=7 and g.status not in ('finished','cancelled') and c.claimed_in_round=g.round_index,'claimedInRound',c.claimed_in_round)
   ||case when g.settings->>'cards'='open' or dungeon_private.has_reached((select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),c.monster_cell_id) then jsonb_build_object('playerId',c.first_player_id) else '{}'::jsonb end),'[]') from public.dungeon_game_monster_claims c where c.game_id=g.id),
  'events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.id),'[]') from (
   select id,kind,case when kind in ('enemy_defeated','bonus_completed') and g.settings->>'cards'='hidden'
    and not dungeon_private.has_reached((select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),payload->>'cellId') then payload-'playerId' else payload end as payload,created_at as "createdAt"
   from public.dungeon_game_events where game_id=g.id and (kind in ('created','joined','left','removed','host_changed','started','paused','resumed','cancelled','finished','rolled','next_round','end_round_complete','enemy_defeated','bonus_completed','turn_skipped')
    or (kind in ('life_lost','powerup_chosen','trap_triggered') and payload->>'playerId'=p_viewer::text)) order by id desc limit 50) e))
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

create or replace function public.list_game_maps(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 return jsonb_build_object('ok',true,'maps',(select coalesce(jsonb_agg(dungeon_private.game_map_json(v) order by v.name),'[]')
  from public.dungeon_map_versions v join public.dungeon_maps m on m.id=v.map_id where m.status='published'));
end;
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
 if p_settings ? 'fog' then settings:=settings||jsonb_build_object('fog',p_settings->'fog');end if;
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

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;


-- Keine neuen öffentlichen Datenzugänge: alle Befehle bleiben Sitzungs-RPCs.
revoke all on all functions in schema dungeon_private from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(8) on conflict do nothing;
notify pgrst,'reload schema';
commit;
