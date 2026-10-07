-- Würfeldungeon 1.1.0 · Einzelspiele, experimentelle KI, Abenteuerwertung.
-- Auf 1.0.2 aufbauen. Bestehende Spieler, Karten und Partien bleiben erhalten.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null or
    not exists(select 1 from dungeon_private.schema_migrations where version=15) then
  raise exception 'Bitte zuerst Würfeldungeon 1.0.2 installieren.';
 end if;
end$$;
lock table dungeon_private.schema_migrations in exclusive mode;
alter table public.dungeon_players add column if not exists is_bot boolean not null default false;
alter table public.dungeon_games add column if not exists mode text not null default 'multiplayer' check(mode in ('multiplayer','solo','ai_test'));

create table if not exists dungeon_private.solo_create_requests(
 player_id uuid not null references public.dungeon_players(id),request_id uuid not null,
 payload_hash text not null,game_id uuid not null references public.dungeon_games(id) on delete cascade,
 primary key(player_id,request_id)
);
create table if not exists dungeon_private.adventure_scores(
 game_id uuid not null references public.dungeon_games(id) on delete cascade,
 player_id uuid not null references public.dungeon_players(id),
 map_version_id uuid not null references public.dungeon_map_versions(id),
 display_name text not null,points integer not null,rounds integer not null,
 participants integer not null,red_every integer not null,effort integer not null,
 expected_points numeric not null,red_factor numeric not null,rating numeric,
 formula_version integer not null default 1,is_bot boolean not null,mode text not null,
 completed_at timestamptz not null,primary key(game_id,player_id)
);
create index if not exists dungeon_adventure_rank_idx on dungeon_private.adventure_scores(map_version_id,rating desc,completed_at);
alter table dungeon_private.solo_create_requests enable row level security;
alter table dungeon_private.adventure_scores enable row level security;
revoke all on dungeon_private.solo_create_requests,dungeon_private.adventure_scores from public,anon,authenticated;

create or replace function dungeon_private.game_red_free(g public.dungeon_games,p_player uuid)
returns boolean language sql stable set search_path='' as $$
 select case when g.mode in ('solo','ai_test') then
  coalesce((g.round_index-1)%greatest(1,(g.settings->>'redEvery')::int)=
   (select seat%greatest(1,(g.settings->>'redEvery')::int) from public.dungeon_game_players where game_id=g.id and player_id=p_player),false)
 else g.roller_id=p_player end;
$$;

create or replace function public.create_solo_game(p_session_token text,p_map_version_id uuid,p_name text,p_settings jsonb,p_bot_count integer,p_red_every integer,p_ai_only boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);previous dungeon_private.solo_create_requests%rowtype;
 hash text;answer jsonb;g public.dungeon_games%rowtype;bot uuid;count_players integer;q integer;i integer;settings jsonb;
 names text[]:=array['Kupferklinge','Nebelpfote','Runenwacht','Glutfeder','Silberzahn','Moosschatten','Frostfunke','Steinherz'];
begin
 if p_request_id is null or p_ai_only is null or p_bot_count is null or p_bot_count not between 0 and 8
  or (p_ai_only and p_bot_count<1) or (not p_ai_only and p_bot_count>7)
  or p_red_every is null or p_red_every not between 0 and 16 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 count_players:=p_bot_count+case when p_ai_only then 0 else 1 end;
 q:=case when p_red_every=0 then count_players else p_red_every end;
 hash:=dungeon_private.token_hash(jsonb_build_object('map',p_map_version_id,'name',p_name,'settings',p_settings,'bots',p_bot_count,'q',q,'test',p_ai_only)::text);
 perform 1 from public.dungeon_players where id=player for no key update;
 select * into previous from dungeon_private.solo_create_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.payload_hash<>hash then return jsonb_build_object('ok',false,'error','GAME_REQUEST_INVALID');end if;
  return jsonb_build_object('ok',true,'gameId',previous.game_id);
 end if;
 settings:=p_settings||jsonb_build_object('maxPlayers',greatest(2,count_players));
 answer:=public.create_game(p_session_token,p_map_version_id,p_name,settings,'',p_request_id);
 if answer->'ok'<>'true'::jsonb then return answer;end if;
 select * into g from public.dungeon_games where id=(answer->>'gameId')::uuid for update;
 update public.dungeon_games game set mode=case when p_ai_only then 'ai_test' else 'solo' end,
  settings=game.settings||jsonb_build_object('redEvery',q,'aiVersion',1) where id=g.id;
 if p_ai_only then delete from public.dungeon_game_players where game_id=g.id and player_id=player;end if;
 for i in 1..p_bot_count loop
  bot:=gen_random_uuid();
  insert into public.dungeon_players(id,username,display_name,is_bot,preferences)
   values(bot,'ki_'||substr(replace(bot::text,'-',''),1,28),names[i]||' · KI',true,jsonb_build_object('markStyle',case when i%3=0 then 'weave' when i%3=1 then 'cross' else 'pencil' end));
  insert into public.dungeon_game_players(game_id,player_id,seat,last_seen_at)
   values(g.id,bot,case when p_ai_only then i-1 else i end,now());
 end loop;
 answer:=public.start_game(p_session_token,g.id,g.revision,gen_random_uuid());
 if answer->'ok'<>'true'::jsonb then raise exception 'SOLO_START_FAILED';end if;
 insert into dungeon_private.solo_create_requests values(player,p_request_id,hash,g.id);
 return jsonb_build_object('ok',true,'gameId',g.id);
end;
$$;

create or replace function dungeon_private.map_rating_benchmarks(g public.dungeon_games)
returns jsonb language plpgsql stable set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;v public.dungeon_map_versions%rowtype;goal jsonb;
 effort integer:=0;base numeric:=0;premium numeric:=0;later numeric;n integer;
begin
 select * into v from public.dungeon_map_versions where id=g.map_version_id;
 select greatest(1,count(*))::int into n from public.dungeon_game_players where game_id=g.id;
 for c in select * from public.dungeon_map_cells where version_id=g.map_version_id loop
  if c.kind in ('monster','boss','miniboss','bonus') then
   effort:=effort+greatest(1,(c.definition->>'hits')::int);
   later:=coalesce((c.definition->>'rewardLater')::int,0)+case when c.kind in ('boss','miniboss') then (c.definition->>'hits')::int/3 else 0 end;
   base:=base+3*later;premium:=premium+3*(coalesce((c.definition->>'rewardFirst')::int,0)-later);
  else effort:=effort+1;base:=base+case c.kind when 'diamond' then 3 when 'goldSack' then 2 when 'goldCoin' then 1 else 0 end;end if;
 end loop;
 if dungeon_private.game_powerup_pool(g) ? 'extraLife' and exists(select 1 from public.dungeon_map_cells where version_id=g.map_version_id and kind='chest') then base:=base+3;end if;
 for goal in select value from jsonb_array_elements(coalesce(v.rules->'goals',jsonb_build_array(jsonb_build_object('type','allType','fieldType','special','reward',jsonb_build_object('first',3,'later',1)),coalesce(v.rules->'customGoal','{}')||jsonb_build_object('reward',jsonb_build_object('first',3,'later',1))))) loop
  if goal->>'type' is null or goal->>'type'='none' then continue;end if;
  if goal->>'type'<>'collectDiamonds' and ((goal->>'type'='allType' and not exists(select 1 from public.dungeon_map_cells where version_id=g.map_version_id and kind=goal->>'fieldType'))
   or (goal->>'type'<>'allType' and jsonb_array_length(coalesce(goal->'cellIds','[]'))=0)) then continue;end if;
  base:=base+3*coalesce((goal->'reward'->>'later')::int,0);
  premium:=premium+3*(coalesce((goal->'reward'->>'first')::int,0)-coalesce((goal->'reward'->>'later')::int,0));
 end loop;
 return jsonb_build_object('effort',effort,'participants',n,'expectedPoints',base+premium/n,'basePoints',base,'firstBonusPoints',premium);
end;
$$;
create or replace function dungeon_private.store_adventure_scores(p_game uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;b jsonb;q integer;m numeric;f integer;n integer;d numeric;
begin
 select * into g from public.dungeon_games where id=p_game;
 if g.status<>'finished' or g.round_index<1 then return;end if;
 b:=dungeon_private.map_rating_benchmarks(g);n:=(b->>'participants')::int;m:=(b->>'expectedPoints')::numeric;f:=(b->>'effort')::int;
 q:=case when g.mode='multiplayer' then n else greatest(1,(g.settings->>'redEvery')::int) end;
 d:=(521.0/108)/(107.0/36+((521.0/108)-(107.0/36))/q);
 insert into dungeon_private.adventure_scores(game_id,player_id,map_version_id,display_name,points,rounds,participants,red_every,effort,expected_points,red_factor,rating,is_bot,mode,completed_at)
 select g.id,r.player_id,g.map_version_id,p.display_name,r.total_points,g.round_index,n,q,f,m,d,
  case when m>0 and f>0 then 100*(2*r.total_points/m+d*f/g.round_index)/3 else null end,p.is_bot,g.mode,g.finished_at
 from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id where r.game_id=g.id and exists(select 1 from public.dungeon_game_players gp where gp.game_id=r.game_id and gp.player_id=r.player_id and gp.active) on conflict do nothing;
end;
$$;
create or replace function dungeon_private.capture_adventure_scores()
returns trigger language plpgsql security definer set search_path='' as $$
begin if new.status='finished' and old.status is distinct from new.status then perform dungeon_private.store_adventure_scores(new.id);end if;return new;end;
$$;
drop trigger if exists dungeon_capture_adventure_scores on public.dungeon_games;
create trigger dungeon_capture_adventure_scores after update of status on public.dungeon_games for each row execute function dungeon_private.capture_adventure_scores();

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
 for ps in select s.*,gp.seat,gp.eliminated from public.dungeon_game_player_states s join public.dungeon_game_players gp on gp.game_id=s.game_id and gp.player_id=s.player_id
  join public.dungeon_players p on p.id=s.player_id where s.game_id=g.id and gp.active and not gp.eliminated and p.is_bot order by gp.seat loop
  t:=dungeon_private.game_turn_view(g,ps.player_id);
  if not (t->'canAct'='true'::jsonb or t->'pendingPowerup'='true'::jsonb or t->'canRoll'='true'::jsonb) then continue;end if;
  seen:=dungeon_private.game_visible_cells(g,ps.state);
  if coalesce((ps.state->>'hornUntil')::timestamptz,'epoch')>now() then
   seen:=seen||(select coalesce(jsonb_agg(cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id and kind in ('monster','boss','miniboss'));
  end if;
  select jsonb_build_object('rooms',coalesce(jsonb_agg(c.definition-'image'-'defeatedImage'-'imageLayout'),'[]')) into doc from public.dungeon_map_cells c where c.version_id=g.map_version_id and seen ? c.cell_id;
  select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into edges from public.dungeon_map_connections where version_id=g.map_version_id and seen ? cell_a and seen ? cell_b;
  ctx:=jsonb_build_object('playerId',ps.player_id,'round',g.round_index,'revision',ps.revision,'state',ps.state,'fog',g.settings->'fog','freeRed',dungeon_private.game_red_free(g,ps.player_id),
   'canRoll',t->'canRoll','canAct',t->'canAct','canLoseLife',t->'canLoseLife','pendingChest',ps.state->'pendingChests'->0,'availablePowerups',t->'availablePowerups',
   'roundRequirements',g.round_requirements,'tasks',dungeon_private.task_view(g,ps.player_id,ps.state),'definition',jsonb_build_object('document',doc,'rules',v.rules,'graph',edges),
   'actions',case when t->'canAct'='true'::jsonb then dungeon_private.game_actions(g,ps.player_id,ps.state) else '[]'::jsonb end,
   'torchActions',case when t->'canAct'='true'::jsonb then dungeon_private.game_torch_actions(g,ps.player_id,ps.state) else '[]'::jsonb end,
   'traps',(select coalesce(jsonb_agg(jsonb_build_object('cellId',cell_id,'armed',activated_in_round<g.round_index)),'[]') from public.dungeon_game_trap_claims where game_id=g.id),
   'claims',(select coalesce(jsonb_agg(jsonb_build_object('cellId',monster_cell_id,'claimedInRound',claimed_in_round)),'[]') from public.dungeon_game_monster_claims where game_id=g.id));
  contexts:=contexts||jsonb_build_array(ctx);
 end loop;end if;
 return jsonb_build_object('ok',true,'status',g.status,'round',g.round_index,'phase',g.phase,'bots',contexts);
end;
$$;

-- Der Host darf nur KI-Plätze dieses privaten Spiels steuern. Die kurzlebige
-- interne Sitzung wird nie ausgegeben und noch in derselben Transaktion gelöscht.
-- Dadurch laufen Würfe, Züge und Powerups durch die vorhandenen Regel-RPCs.
create or replace function public.perform_ai_action(p_session_token text,p_game_id uuid,p_bot_id uuid,p_round integer,p_state_revision bigint,p_kind text,p_cell_id text,p_middle_cell_id text,p_use_red boolean,p_use_axe boolean,p_powerup text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;token text;session_id uuid;answer jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.host_id<>player or g.mode='multiplayer' or not exists(select 1 from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id and p.id=p_bot_id and p.is_bot and gp.active) then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY');end if;
 if p_request_id is null or p_kind is null or p_kind not in ('roll','cell','lose_life','powerup','horn') then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 token:=dungeon_private.new_token();
 insert into dungeon_private.player_sessions(player_id,token_hash,device_label,expires_at) values(p_bot_id,dungeon_private.token_hash(token),'Interner KI-Zug',now()+interval '1 minute') returning id into session_id;
 if p_kind='roll' then answer:=public.roll_game_dice(token,g.id,p_round,p_request_id);
 elsif p_kind='powerup' then answer:=public.choose_game_powerup(token,g.id,p_cell_id,p_state_revision,p_powerup,p_request_id);
 elsif p_kind='horn' then answer:=public.use_game_horn(token,g.id,p_state_revision,p_request_id);
 else answer:=public.play_game_action(token,g.id,p_round,p_state_revision,p_kind,p_cell_id,p_use_red,p_request_id,p_middle_cell_id,p_use_axe);end if;
 delete from dungeon_private.player_sessions where id=session_id;
 return answer;
end;
$$;

create or replace function public.list_highscores(p_session_token text,p_map_version_id uuid,p_opponents integer default null,p_red_every integer default null,p_game_id uuid default null,p_offset integer default 0,p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);rows jsonb;own jsonb;total integer;
begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or (p_opponents is not null and p_opponents not between 0 and 15) or (p_red_every is not null and p_red_every not between 1 and 16) then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 with ranked as(select s.*,rank() over(order by rating desc) place from dungeon_private.adventure_scores s
  where map_version_id=p_map_version_id and rating is not null and not is_bot and mode<>'ai_test'
   and (p_opponents is null or participants=p_opponents+1) and (p_red_every is null or red_every=p_red_every)),
 selected as(select * from ranked order by place,completed_at,game_id,player_id offset p_offset limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('rank',place,'gameId',game_id,'playerId',player_id,'displayName',display_name,'rating',rating,'points',points,'rounds',rounds,'opponents',participants-1,'aiOpponents',(select count(*) from public.dungeon_game_players gp join public.dungeon_players bp on bp.id=gp.player_id where gp.game_id=selected.game_id and bp.is_bot),'redEvery',red_every,'completedAt',completed_at,'mine',player_id=player,'current',game_id=p_game_id) order by place,completed_at,game_id,player_id),'[]') into rows from selected;
 with ranked as(select s.*,rank() over(order by rating desc) place from dungeon_private.adventure_scores s
  where map_version_id=p_map_version_id and rating is not null and not is_bot and mode<>'ai_test'
   and (p_opponents is null or participants=p_opponents+1) and (p_red_every is null or red_every=p_red_every))
 select jsonb_build_object('rank',place,'rating',rating,'points',points,'rounds',rounds,'gameId',game_id) into own from ranked where player_id=player and (p_game_id is null or game_id=p_game_id) order by rating desc,completed_at limit 1;
 select count(*)::int into total from dungeon_private.adventure_scores where map_version_id=p_map_version_id and rating is not null and not is_bot and mode<>'ai_test'
  and (p_opponents is null or participants=p_opponents+1) and (p_red_every is null or red_every=p_red_every);
 return jsonb_build_object('ok',true,'entries',rows,'personal',own,'total',total,'formulaVersion',1);
end;
$$;
create or replace function public.list_highscore_maps(p_session_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 return jsonb_build_object('ok',true,'maps',(select coalesce(jsonb_agg(jsonb_build_object('versionId',v.id,'name',v.name,'entries',(select count(*) from dungeon_private.adventure_scores s where s.map_version_id=v.id and not s.is_bot and s.mode<>'ai_test' and s.rating is not null)) order by v.name,v.id),'[]') from public.dungeon_map_versions v));
end;
$$;
create or replace function public.list_ai_experiments(p_session_token text,p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);
begin
 if p_limit is null or p_limit not between 1 and 100 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 return jsonb_build_object('ok',true,'games',(select coalesce(jsonb_agg(dungeon_private.game_result_json(g,player) order by g.created_at desc),'[]') from
  (select * from public.dungeon_games where host_id=player and mode='ai_test' order by created_at desc limit p_limit) g));
end;
$$;


create or replace function dungeon_private.game_actions_v5(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.dice is null then return result; end if;
 normal:=dungeon_private.dice_options(g.dice,dungeon_private.game_red_free(g,p_player));
 red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
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
 normal:=dungeon_private.dice_options(g.dice,dungeon_private.game_red_free(g,p_player));
 red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.dice_options(g.dice,true) else '{}'::text[] end;
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

create or replace function dungeon_private.game_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.rules_version<7 then return dungeon_private.game_actions_v5(g,p_player,s); end if;
 if g.dice is null then return result; end if;
 normal:=dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player));
 red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
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
 normal:=dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player));
 red:=case when not dungeon_private.game_red_free(g,p_player) and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
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
 standard_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='false'::jsonb);
 red_possible:=exists(select 1 from jsonb_array_elements(actions) a where a->'redOnly'='true'::jsonb);
 return jsonb_build_object('canRoll',coalesce(g.status='playing' and g.phase='waiting_roll' and g.roller_id=p_player and gp.active and not gp.eliminated,false)
   and not exists(select 1 from public.dungeon_game_players gp2 join public.dungeon_game_player_states s on s.game_id=gp2.game_id and s.player_id=gp2.player_id where gp2.game_id=g.id and gp2.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0),
  'freeRed',dungeon_private.game_red_free(g,p_player),'canAct',ready,'done',coalesce(ps.last_completed_round>=g.round_index,false) and not pending,'standardPossible',standard_possible,'redPossible',red_possible,
  'torchPossible',jsonb_array_length(torch)>0,'canLoseLife',ready and not standard_possible,'ownRevision',ps.revision,'lastCompletedRound',ps.last_completed_round,
  'pendingPowerup',pending,'availablePowerups',dungeon_private.game_available_powerups(g,ps.state))
  ||case when coalesce(g.settings->'fieldHints',g.settings->'hints')='true'::jsonb then jsonb_build_object('actions',actions) else '{}'::jsonb end
  ||case when coalesce(g.settings->'diceHints',g.settings->'hints')='true'::jsonb then jsonb_build_object(
   'options',to_jsonb(dungeon_private.game_dice_options(g,dungeon_private.game_red_free(g,p_player))),
   'redOptions',to_jsonb(case when not dungeon_private.game_red_free(g,p_player) and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.game_dice_options(g,true)) n where not n=any(dungeon_private.game_dice_options(g,false))) else '{}'::text[] end)) else '{}'::jsonb end;
end;
$$;

create or replace function dungeon_private.game_summary(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',g.id,'name',g.name,'status',g.status,'revision',g.revision,
  'mode',g.mode,'experimentalAI',g.mode='ai_test' or exists(select 1 from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id and p.is_bot),'settings',g.settings,'createdAt',g.created_at,'startedAt',g.started_at,'finishedAt',g.finished_at,
  'round',g.round_index,'phase',g.phase,'rollerId',g.roller_id,'pausedAt',g.paused_at,'rollWaitStartedAt',g.roll_wait_started_at,
  'host',(select jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path) from public.dungeon_players p where p.id=g.host_id),
  'map',(select dungeon_private.game_map_json(v) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'playerCount',(select count(*) from public.dungeon_game_players p where p.game_id=g.id and p.active),
  'passwordRequired',exists(select 1 from dungeon_private.game_passwords where game_id=g.id),
  'mine',exists(select 1 from public.dungeon_game_players p where p.game_id=g.id and p.player_id=p_viewer and p.active),
  'participated',exists(select 1 from public.dungeon_game_players p where p.game_id=g.id and p.player_id=p_viewer));
$$;

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'powerupPool',dungeon_private.game_powerup_pool(g),'roundRequirements',g.round_requirements,'visibleCells',dungeon_private.game_visible_cells(g,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'traps',(select coalesce(jsonb_agg(jsonb_build_object('cellId',cell_id,'activatedInRound',activated_in_round,'armed',activated_in_round<g.round_index)),'[]') from public.dungeon_game_trap_claims where game_id=g.id),
  'dice',g.dice,'choiceStartedAt',g.choice_started_at,'finalRound',g.final_round,'serverNow',now(),'rulesVersion',g.rules_version,
  'tasks',dungeon_private.task_view(g,p_viewer,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'results',case when g.status='finished' then dungeon_private.game_result_json(g,p_viewer)->'results' else '[]'::jsonb end,
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'isBot',p.is_bot,'markStyle',coalesce(p.preferences->>'markStyle','pencil'),'seat',gp.seat,
   'active',gp.active,'eliminated',gp.eliminated,'online',gp.last_seen_at>now()-interval '45 seconds',
   'turnDone',coalesce(s.last_completed_round>=g.round_index,false) and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))=0,
   'hasPendingPowerup',jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0,'points',coalesce((s.state->>'diamonds')::int,0)*3+coalesce((s.state->>'goldPoints')::int,0)+coalesce(dungeon_private.life_penalty(s.state),0)) order by gp.seat),'[]')
   from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id left join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id where gp.game_id=g.id and (gp.active or g.status in ('finished','cancelled'))),
  'ownPlayerId',p_viewer,'ownState',(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),
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
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',dungeon_private.game_powerup_pool(g),'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

create or replace function dungeon_private.game_result_json(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object('round',g.round_index,'startedAt',g.started_at,'results',(select coalesce(jsonb_agg(jsonb_build_object(
  'isBot',p.is_bot,'markStyle',coalesce(p.preferences->>'markStyle','pencil'),'adventureRating',(select rating from dungeon_private.adventure_scores where game_id=g.id and player_id=p.id),'ratingDetails',(select jsonb_build_object('effort',effort,'expectedPoints',expected_points,'redEvery',red_every,'redFactor',red_factor,'participants',participants,'formulaVersion',formula_version) from dungeon_private.adventure_scores where game_id=g.id and player_id=p.id),'playerId',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'points',r.total_points,'diamonds',r.diamonds,
  'lifePenalty',r.life_penalty,'monstersDefeated',r.monsters_defeated,'won',r.won,'breakdown',r.breakdown,'eliminated',gp.eliminated,'removed',not gp.active) order by r.total_points desc,gp.seat),'[]')
  from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id join public.dungeon_game_players gp on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id));
$$;

create or replace function public.get_game(p_session_token text,p_game_id uuid,p_include_definition boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;membership public.dungeon_game_players%rowtype;observed uuid;detail jsonb;
begin
 -- FOR UPDATE synchronisiert auch einmalige Nachrüstung und Schlusswertung.
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 if g.mode='ai_test' then
  if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
  select player_id into observed from public.dungeon_game_players where game_id=g.id order by seat limit 1;
  detail:=dungeon_private.game_detail(g,observed,p_include_definition)||jsonb_build_object('spectator',true,'turn',jsonb_build_object('canRoll',false,'canAct',false,'done',true));
  return jsonb_build_object('ok',true,'game',detail);
 end if;
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

create or replace function public.get_game_result(p_session_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype;
begin
 select * into g from public.dungeon_games where id=p_game_id and status in ('finished','cancelled');
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 return jsonb_build_object('ok',true,'game',dungeon_private.game_result_json(g,player));
end;
$$;

create or replace function public.get_game_replay(p_session_token text,p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare viewer uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;players jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.mode='ai_test' and g.host_id<>viewer then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 if g.status<>'finished' then return jsonb_build_object('ok',false,'error','GAME_CLOSED');end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'markStyle',coalesce(p.preferences->>'markStyle','pencil'),'isBot',p.is_bot,
  'complete',exists(select 1 from dungeon_private.replay_frames f where f.game_id=g.id and f.player_id=p.id and f.initial_frame),
  'frames',(select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'round',f.round_index,'state',f.state,'dice',f.dice,'roundRequirements',f.round_requirements,'recordedAt',f.recorded_at) order by f.id),'[]') from dungeon_private.replay_frames f where f.game_id=g.id and f.player_id=p.id)) order by gp.seat),'[]') into players
 from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id;
 return jsonb_build_object('ok',true,'available',exists(select 1 from dungeon_private.replay_frames where game_id=g.id),
  'game',dungeon_private.game_result_json(g,viewer)||jsonb_build_object('round',g.round_index,'startedAt',g.started_at),
  'definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',dungeon_private.game_powerup_pool(g),'graph',v.compiled_graph) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'players',players);
end;
$$;

create or replace function public.list_game_history(p_session_token text,p_scope text default 'all',p_query text default '',p_status text default 'finished',p_since timestamptz default null,p_until timestamptz default null,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); entries jsonb; total int;
begin
 if p_scope not in ('all','mine','won') or p_status not in ('all','finished','cancelled') or p_limit is null or p_limit not between 1 and 100 or char_length(coalesce(p_query,''))>100
  or ((p_before is null)<>(p_before_id is null)) then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID'); end if;
 select coalesce(jsonb_agg(dungeon_private.game_result_json(e,player) order by e.finished_at desc,e.id desc),'[]') into entries from (
  select g.* from public.dungeon_games g join public.dungeon_map_versions v on v.id=g.map_version_id join public.dungeon_players host on host.id=g.host_id
   where g.mode<>'ai_test' and g.status in ('finished','cancelled') and (p_status='all' or g.status=p_status)
    and (p_scope='all' or (p_scope='mine' and exists(select 1 from public.dungeon_game_players p where p.game_id=g.id and p.player_id=player))
      or (p_scope='won' and exists(select 1 from public.dungeon_game_results r where r.game_id=g.id and r.player_id=player and r.won)))
    and (p_since is null or g.finished_at>=p_since) and (p_until is null or g.finished_at<p_until)
    and (p_before is null or (g.finished_at,g.id)<(p_before,p_before_id))
    and strpos(lower(g.name||' '||v.name||' '||host.display_name),lower(btrim(coalesce(p_query,''))))>0
   order by g.finished_at desc,g.id desc limit p_limit+1) e;
 total:=jsonb_array_length(entries);
 return jsonb_build_object('ok',true,'games',(select coalesce(jsonb_agg(value order by ord),'[]') from jsonb_array_elements(entries) with ordinality as a(value,ord) where ord<=p_limit),'hasMore',total>p_limit);
end;
$$;

create or replace function public.list_games(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);
begin
 return jsonb_build_object('ok',true,
  'lobbies',(select coalesce(jsonb_agg(dungeon_private.game_summary(g,player) order by g.created_at desc,g.id),'[]') from public.dungeon_games g where g.status='lobby' and g.mode='multiplayer'),
  'ongoing',(select coalesce(jsonb_agg(dungeon_private.game_summary(g,player) order by g.created_at desc,g.id),'[]')
   from public.dungeon_games g join public.dungeon_game_players p on p.game_id=g.id where g.mode<>'ai_test' and p.player_id=player and p.active and g.status in ('playing','paused')));
end;
$$;

create or replace function public.join_game(p_session_token text,p_game_id uuid,p_password text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; gp public.dungeon_game_players%rowtype; hash text; replay jsonb; payload jsonb:=jsonb_build_object('passwordHash',dungeon_private.token_hash(coalesce(p_password,''))); seat_no int;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'join',payload);if replay is not null then return replay; end if;
 if g.status in ('finished','cancelled') then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 select * into gp from public.dungeon_game_players where game_id=g.id and player_id=player;
 if gp.active then return dungeon_private.record_game_command(g.id,player,p_request_id,'join',payload,g.revision); end if;
 if g.mode<>'multiplayer' then return jsonb_build_object('ok',false,'error','GAME_CLOSED');end if;
 if g.status<>'lobby' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_STARTED'); end if;
 if gp.departure_reason='removed' then return jsonb_build_object('ok',false,'error','GAME_REMOVED'); end if;
 if (select count(*) from public.dungeon_game_players where game_id=g.id and active)>=(g.settings->>'maxPlayers')::int then return jsonb_build_object('ok',false,'error','GAME_FULL'); end if;
 select password_hash into hash from dungeon_private.game_passwords where game_id=g.id;
 if hash is not null and (p_password is null or octet_length(p_password)>72 or not dungeon_private.password_matches(p_password,hash)) then return jsonb_build_object('ok',false,'error','GAME_PASSWORD_WRONG'); end if;
 select coalesce(max(seat),-1)+1 into seat_no from public.dungeon_game_players where game_id=g.id;
 insert into public.dungeon_game_players(game_id,player_id,seat,last_seen_at) values(g.id,player,seat_no,clock_timestamp())
  on conflict(game_id,player_id) do update set seat=excluded.seat,active=true,eliminated=false,joined_at=now(),last_seen_at=excluded.last_seen_at,removed_at=null,departure_reason=null;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'joined',jsonb_build_object('playerId',player));
 return dungeon_private.record_game_command(g.id,player,p_request_id,'join',payload,g.revision);
end;
$$;

create or replace function public.manage_game(p_session_token text,p_game_id uuid,p_action text,p_expected_revision bigint,p_request_id uuid,p_target_player_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; replay jsonb; payload jsonb:=jsonb_build_object('action',p_action,'revision',p_expected_revision,'target',p_target_player_id); event_kind text;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'manage',payload);if replay is not null then return replay; end if;
 if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY'); end if;
 if g.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','GAME_CHANGED'); end if;
 if g.status not in ('lobby','playing','paused') then return jsonb_build_object('ok',false,'error','GAME_CLOSED'); end if;
 if p_action='host' and g.mode<>'multiplayer' then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID');end if;
 if p_action='host' and exists(select 1 from public.dungeon_players where id=p_target_player_id and is_bot) then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID');end if;
 if p_action='pause' and g.status='playing' then
  update public.dungeon_games set status='paused',paused_at=now(),revision=revision+1 where id=g.id returning * into g; event_kind:='paused';
 elsif p_action='resume' and g.status='paused' then
  update public.dungeon_games set status='playing',paused_at=null,revision=revision+1 where id=g.id returning * into g; event_kind:='resumed';
 elsif p_action='cancel' then
  update public.dungeon_games set status='cancelled',phase='finished',finished_at=now(),paused_at=null,revision=revision+1 where id=g.id returning * into g; event_kind:='cancelled';
 elsif p_action in ('host','remove') and p_target_player_id is not null and p_target_player_id<>player
  and exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=p_target_player_id and active and not eliminated) then
  if p_action='remove' then
   if g.status<>'lobby' then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
   update public.dungeon_game_players set active=false,removed_at=now(),departure_reason='removed' where game_id=g.id and player_id=p_target_player_id; event_kind:='removed';
   update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
  else
   update public.dungeon_games set host_id=p_target_player_id,revision=revision+1 where id=g.id returning * into g; event_kind:='host_changed';
  end if;
 else return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,event_kind,jsonb_build_object('playerId',coalesce(p_target_player_id,player)));
 return dungeon_private.record_game_command(g.id,player,p_request_id,'manage',payload,g.revision);
end;
$$;

create or replace function dungeon_private.credit_game_diamonds(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare result record;
begin
 if not exists(select 1 from public.dungeon_games where id=p_game_id and status='finished' and mode<>'ai_test') then return;end if;
 -- Eindeutige Spiel-/Spieler-Schlüssel verhindern doppelte Gutschriften.
 -- Dieselbe Lock-Reihenfolge vermeidet Konflikte beim Abschluss mehrerer Spiele.
 for result in select player_id,greatest(0,diamonds) amount from public.dungeon_game_results where game_id=p_game_id and not exists(select 1 from public.dungeon_players p where p.id=player_id and p.is_bot) order by player_id loop
  perform 1 from public.dungeon_players where id=result.player_id for update;
  insert into dungeon_private.marking_credits(player_id,game_id,amount) values(result.player_id,p_game_id,result.amount) on conflict do nothing;
 end loop;
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'soloAIVersion',1,'highscoreVersion',1,'releaseVersion','1.1.0','runeHitsVersion',1,'starterCosmeticsVersion',1,'portalFogVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;

do $$declare g record;begin
 for g in select id from public.dungeon_games where status='finished' loop perform dungeon_private.store_adventure_scores(g.id);end loop;
end$$;

do $$declare f record;begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='dungeon_private' loop
  execute 'revoke all on function '||f.signature||' from public,anon,authenticated';
 end loop;
end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='create_solo_game';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='get_ai_context';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='perform_ai_action';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_highscores';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_highscore_maps';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

do $$declare sig regprocedure;begin select p.oid::regprocedure into sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_ai_experiments';execute 'revoke all on function '||sig||' from public';execute 'grant execute on function '||sig||' to anon,authenticated';end$$;

insert into dungeon_private.schema_migrations(version) values(16) on conflict do nothing;
commit;
