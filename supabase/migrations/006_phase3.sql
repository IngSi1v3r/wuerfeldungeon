-- Würfeldungeon Phase 3. Zusätzlich zu 001 und 004 ausführen.
-- Eigene Spielersitzungen bleiben erhalten; keine Supabase-Auth-Konten nötig.
begin;

alter table public.dungeon_game_players add column if not exists last_seen_at timestamptz;
alter table public.dungeon_game_players add column if not exists departure_reason text;
alter table dungeon_private.game_commands add column if not exists kind text;
alter table dungeon_private.game_commands add column if not exists payload_hash text;
create table if not exists dungeon_private.game_create_requests (
 player_id uuid not null references public.dungeon_players(id),
 request_id uuid not null,
 payload_hash text not null,
 game_id uuid not null references public.dungeon_games(id),
 created_at timestamptz not null default now(),
 primary key(player_id,request_id)
);
alter table dungeon_private.game_create_requests enable row level security;
revoke all on dungeon_private.game_create_requests from public,anon,authenticated;
create index if not exists dungeon_games_status_date_idx on public.dungeon_games(status,created_at desc,id);
create index if not exists dungeon_games_finished_idx on public.dungeon_games(finished_at desc,id desc) where status in ('finished','cancelled');

create or replace function dungeon_private.game_settings_valid(s jsonb)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(jsonb_typeof(s)='object'
  and dungeon_private.json_int(s->'maxPlayers',2,16)
  and s->>'cards' in ('open','hidden') and jsonb_typeof(s->'hints')='boolean',false);
$$;
create or replace function dungeon_private.game_map_json(v public.dungeon_map_versions)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',v.map_id,'versionId',v.id,'name',v.name,
  'fields',jsonb_array_length(v.document->'rooms'),
  'enemies',(select count(*) from jsonb_array_elements(v.document->'rooms') r where r->>'type' in ('monster','miniboss','boss')),
  'preview',(select coalesce(jsonb_agg(jsonb_build_object('id',r->'id','type',r->'type','x',r->'x','y',r->'y','w',r->'w','h',r->'h','start',r->'start')),'[]') from jsonb_array_elements(v.document->'rooms') r));
$$;
create or replace function dungeon_private.game_summary(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',g.id,'name',g.name,'status',g.status,'revision',g.revision,
  'settings',g.settings,'createdAt',g.created_at,'startedAt',g.started_at,'finishedAt',g.finished_at,
  'round',g.round_index,'phase',g.phase,'rollerId',g.roller_id,'pausedAt',g.paused_at,
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
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'seat',gp.seat,
    'active',gp.active,'eliminated',gp.eliminated,'online',gp.last_seen_at>now()-interval '45 seconds') order by gp.seat),'[]')
    from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id and (gp.active or g.status in ('finished','cancelled'))),
  'ownState',(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer),
  'states',(select coalesce(jsonb_agg(jsonb_build_object('playerId',s.player_id,'state',s.state,'revision',s.revision,'lastCompletedRound',s.last_completed_round)),'[]')
    from public.dungeon_game_player_states s where s.game_id=g.id and (s.player_id=p_viewer or g.settings->>'cards'='open')),
  'events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.id),'[]') from (
    select id,kind,payload,created_at as "createdAt" from public.dungeon_game_events where game_id=g.id
     and kind in ('created','joined','left','removed','host_changed','started','paused','resumed','cancelled','finished') order by id desc limit 30) e))
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,
   'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

-- Nur kleine Änderungszeichen. Keine Namen, Passwörter, Sitzungen oder Spielstände.
-- Fehlendes Realtime darf einen Spielvorgang nicht verhindern: Polling bleibt aktiv.
create or replace function dungeon_private.signal_game_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare topic text;
begin
 if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null then
  begin
   topic:='dungeon:game:'||new.id::text;
   execute 'select realtime.send($1,$2,$3,false)' using jsonb_build_object('revision',new.revision),'changed',topic;
   if new.status='lobby' or (tg_op='UPDATE' and old.status='lobby') or new.status in ('finished','cancelled') then
    execute 'select realtime.send($1,$2,$3,false)' using '{}'::jsonb,'changed','dungeon:lobbies';
   end if;
  exception when others then raise warning 'Dungeon realtime signal unavailable; clients will poll';
  end;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_game_signal on public.dungeon_games;
create trigger dungeon_game_signal after insert or update on public.dungeon_games for each row execute function dungeon_private.signal_game_change();

create or replace function public.list_game_maps(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 return jsonb_build_object('ok',true,'maps',(select coalesce(jsonb_agg(dungeon_private.game_map_json(v) order by v.name),'[]')
  from public.dungeon_map_versions v join public.dungeon_maps m on m.id=v.map_id where m.status='published'));
end;
$$;
create or replace function public.list_games(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);
begin
 return jsonb_build_object('ok',true,
  'lobbies',(select coalesce(jsonb_agg(dungeon_private.game_summary(g,player) order by g.created_at desc,g.id),'[]') from public.dungeon_games g where g.status='lobby'),
  'ongoing',(select coalesce(jsonb_agg(dungeon_private.game_summary(g,player) order by g.created_at desc,g.id),'[]')
   from public.dungeon_games g join public.dungeon_game_players p on p.game_id=g.id where p.player_id=player and p.active and g.status in ('playing','paused')));
end;
$$;
create or replace function public.get_game(p_session_token text,p_game_id uuid,p_include_definition boolean default true)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; membership public.dungeon_game_players%rowtype;
begin
 select * into g from public.dungeon_games where id=p_game_id;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 select * into membership from public.dungeon_game_players where game_id=g.id and player_id=player;
 if membership.player_id is not null and not membership.active and membership.departure_reason='removed' and g.status not in ('finished','cancelled') then
  return jsonb_build_object('ok',false,'error','GAME_REMOVED');
 end if;
 if membership.player_id is null or (not membership.active and g.status not in ('finished','cancelled')) then
  if g.status='lobby' then return jsonb_build_object('ok',false,'error','GAME_JOIN_REQUIRED','lobby',dungeon_private.game_summary(g,player)); end if;
  return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');
 end if;
 if membership.active and g.status in ('lobby','playing','paused') then
  update public.dungeon_game_players set last_seen_at=clock_timestamp() where game_id=g.id and player_id=player;
 end if;
 return jsonb_build_object('ok',true,'game',dungeon_private.game_detail(g,player,p_include_definition));
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

-- Alle Spielmutationen sperren dieselbe Spielzeile. Teilnehmerlimit und Start
-- können sich dadurch nicht gegenseitig überholen.
create or replace function dungeon_private.game_command_replay(p_game uuid,p_player uuid,p_request uuid,p_kind text,p_payload jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare previous dungeon_private.game_commands%rowtype;
begin
 if p_request is null then return jsonb_build_object('ok',false,'error','GAME_REQUEST_INVALID'); end if;
 select * into previous from dungeon_private.game_commands where game_id=p_game and player_id=p_player and request_id=p_request;
 if not found then return null; end if;
 if previous.kind is distinct from p_kind or previous.payload_hash is distinct from dungeon_private.token_hash(p_payload::text) then
  return jsonb_build_object('ok',false,'error','GAME_REQUEST_INVALID');
 end if;
 return previous.response;
end;
$$;
create or replace function dungeon_private.record_game_command(p_game uuid,p_player uuid,p_request uuid,p_kind text,p_payload jsonb,p_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare answer jsonb:=jsonb_build_object('ok',true,'gameId',p_game,'revision',p_revision);
begin
 insert into dungeon_private.game_commands(game_id,player_id,request_id,kind,payload_hash,response)
  values(p_game,p_player,p_request,p_kind,dungeon_private.token_hash(p_payload::text),answer);
 return answer;
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
create or replace function public.leave_game(p_session_token text,p_game_id uuid,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; replay jsonb; new_host uuid; was_host boolean;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'leave','{}');if replay is not null then return replay; end if;
 if g.status<>'lobby' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_STARTED'); end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 was_host:=g.host_id=player;
 update public.dungeon_game_players set active=false,removed_at=now(),departure_reason='left' where game_id=g.id and player_id=player;
 select player_id into new_host from public.dungeon_game_players where game_id=g.id and active order by seat limit 1;
 update public.dungeon_games set revision=revision+1,host_id=case when host_id=player and new_host is not null then new_host else host_id end,
  status=case when new_host is null then 'cancelled' else status end,phase=case when new_host is null then 'finished' else phase end,
  finished_at=case when new_host is null then now() else finished_at end where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'left',jsonb_build_object('playerId',player));
 if new_host is null then insert into public.dungeon_game_events(game_id,game_revision,kind) values(g.id,g.revision,'cancelled');
 elsif was_host then insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'host_changed',jsonb_build_object('playerId',new_host)); end if;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'leave','{}',g.revision);
end;
$$;
create or replace function public.start_game(p_session_token text,p_game_id uuid,p_expected_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype; replay jsonb; payload jsonb:=jsonb_build_object('revision',p_expected_revision); first_roller uuid;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'start',payload);if replay is not null then return replay; end if;
 if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY'); end if;
 if g.status<>'lobby' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_STARTED'); end if;
 if g.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','GAME_CHANGED'); end if;
 select player_id into first_roller from public.dungeon_game_players where game_id=g.id and active order by seat limit 1;
 if first_roller is null then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER'); end if;
 insert into public.dungeon_game_player_states(game_id,player_id,last_completed_round)
  select g.id,player_id,0 from public.dungeon_game_players where game_id=g.id and active;
 update public.dungeon_games set status='playing',started_at=now(),round_index=1,roller_id=first_roller,phase='waiting_roll',revision=revision+1 where id=g.id returning * into g;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'started',jsonb_build_object('playerId',player));
 return dungeon_private.record_game_command(g.id,player,p_request_id,'start',payload,g.revision);
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

create or replace function dungeon_private.game_result_json(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object('results',(select coalesce(jsonb_agg(jsonb_build_object(
  'playerId',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'points',r.total_points,'diamonds',r.diamonds,
  'lifePenalty',r.life_penalty,'monstersDefeated',r.monsters_defeated,'won',r.won) order by r.total_points desc,gp.seat),'[]')
  from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id join public.dungeon_game_players gp on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id));
$$;
create or replace function public.list_game_history(p_session_token text,p_scope text default 'all',p_query text default '',p_status text default 'finished',p_since timestamptz default null,p_until timestamptz default null,p_before timestamptz default null,p_before_id uuid default null,p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); entries jsonb; total int;
begin
 if p_scope not in ('all','mine','won') or p_status not in ('all','finished','cancelled') or p_limit is null or p_limit not between 1 and 100 or char_length(coalesce(p_query,''))>100
  or ((p_before is null)<>(p_before_id is null)) then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID'); end if;
 select coalesce(jsonb_agg(dungeon_private.game_result_json(e,player) order by e.finished_at desc,e.id desc),'[]') into entries from (
  select g.* from public.dungeon_games g join public.dungeon_map_versions v on v.id=g.map_version_id join public.dungeon_players host on host.id=g.host_id
   where g.status in ('finished','cancelled') and (p_status='all' or g.status=p_status)
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
create or replace function public.get_game_result(p_session_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); g public.dungeon_games%rowtype;
begin
 select * into g from public.dungeon_games where id=p_game_id and status in ('finished','cancelled');
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 return jsonb_build_object('ok',true,'game',dungeon_private.game_result_json(g,player));
end;
$$;
create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;

revoke all on all functions in schema dungeon_private from public,anon,authenticated;
revoke all on function public.list_game_maps(text), public.list_games(text), public.get_game(text,uuid,boolean), public.create_game(text,uuid,text,jsonb,text,uuid),
 public.join_game(text,uuid,text,uuid), public.leave_game(text,uuid,uuid), public.start_game(text,uuid,bigint,uuid), public.manage_game(text,uuid,text,bigint,uuid,uuid),
 public.list_game_history(text,text,text,text,timestamptz,timestamptz,timestamptz,uuid,integer), public.get_game_result(text,uuid) from public;
grant execute on function public.list_game_maps(text), public.list_games(text), public.get_game(text,uuid,boolean), public.create_game(text,uuid,text,jsonb,text,uuid),
 public.join_game(text,uuid,text,uuid), public.leave_game(text,uuid,uuid), public.start_game(text,uuid,bigint,uuid), public.manage_game(text,uuid,text,bigint,uuid,uuid),
 public.list_game_history(text,text,text,text,timestamptz,timestamptz,timestamptz,uuid,integer), public.get_game_result(text,uuid) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(3) on conflict do nothing;
notify pgrst,'reload schema';
commit;
