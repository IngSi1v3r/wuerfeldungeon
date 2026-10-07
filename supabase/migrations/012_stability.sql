-- Würfeldungeon 0.5.1: Wartesteuerung auch vor dem Würfeln.
-- Zusätzlich zu 010_phase5.sql ausführen; bestehende Spielstände bleiben erhalten.
begin;
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=5) then
  raise exception 'Bitte zuerst 010_phase5.sql installieren.';
 end if;
end$$;

alter table public.dungeon_games add column if not exists roll_wait_started_at timestamptz;

create or replace function dungeon_private.preserve_roll_wait_clock()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.phase='waiting_roll' and new.status in ('playing','paused')
  and not exists(select 1 from public.dungeon_game_players gp join public.dungeon_game_player_states s on s.game_id=gp.game_id and s.player_id=gp.player_id
   where gp.game_id=new.id and gp.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0) then
  if old.phase is distinct from new.phase or old.roller_id is distinct from new.roller_id
   or old.status not in ('playing','paused') or old.roll_wait_started_at is null then
   new.roll_wait_started_at:=case when new.status='paused' then coalesce(new.paused_at,now()) else now() end;
  elsif old.status='paused' and new.status='playing' and old.paused_at is not null then
   new.roll_wait_started_at:=old.roll_wait_started_at+(now()-old.paused_at);
  else new.roll_wait_started_at:=coalesce(new.roll_wait_started_at,old.roll_wait_started_at);
  end if;
 else new.roll_wait_started_at:=null;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_roll_wait_clock on public.dungeon_games;
create trigger dungeon_roll_wait_clock before update on public.dungeon_games for each row execute function dungeon_private.preserve_roll_wait_clock();
update public.dungeon_games set roll_wait_started_at=null where phase='waiting_roll' and status in ('playing','paused') and roll_wait_started_at is null;

-- game_summary wird auch für die Spielübersicht verwendet. Keine fremden
-- Spielzüge oder privaten Daten werden durch die zusätzliche Uhr sichtbar.
create or replace function dungeon_private.game_summary(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',g.id,'name',g.name,'status',g.status,'revision',g.revision,
  'settings',g.settings,'createdAt',g.created_at,'startedAt',g.started_at,'finishedAt',g.finished_at,
  'round',g.round_index,'phase',g.phase,'rollerId',g.roller_id,'pausedAt',g.paused_at,'rollWaitStartedAt',g.roll_wait_started_at,
  'host',(select jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path) from public.dungeon_players p where p.id=g.host_id),
  'map',(select dungeon_private.game_map_json(v) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'playerCount',(select count(*) from public.dungeon_game_players p where p.game_id=g.id and p.active),
  'passwordRequired',exists(select 1 from dungeon_private.game_passwords where game_id=g.id),
  'mine',exists(select 1 from public.dungeon_game_players p where p.game_id=g.id and p.player_id=p_viewer and p.active),
  'participated',exists(select 1 from public.dungeon_game_players p where p.game_id=g.id and p.player_id=p_viewer));
$$;

create or replace function public.resolve_game_wait(p_session_token text,p_game_id uuid,p_round integer,p_target_player_id uuid,p_action text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;gp public.dungeon_game_players%rowtype;replay jsonb;
 payload jsonb:=jsonb_build_object('round',p_round,'target',p_target_player_id,'action',p_action);next_roller uuid;roll_wait boolean;wait_start timestamptz;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND'); end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'wait',payload);if replay is not null then return replay; end if;
 if g.host_id<>player then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY'); end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED'); end if;
 if g.status<>'playing' or g.phase not in ('choosing','round_complete','waiting_roll') then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 if g.round_index is distinct from p_round then return jsonb_build_object('ok',false,'error','GAME_ROUND_CHANGED'); end if;
 if p_action is null or p_action not in ('skip','remove') or (p_action='remove' and p_target_player_id=player) then return jsonb_build_object('ok',false,'error','GAME_ACTION_INVALID'); end if;
 roll_wait:=g.phase='waiting_roll' and not exists(select 1 from public.dungeon_game_players gp2 join public.dungeon_game_player_states s on s.game_id=gp2.game_id and s.player_id=gp2.player_id
  where gp2.game_id=g.id and gp2.active and jsonb_array_length(coalesce(s.state->'pendingChests','[]'))>0);
 wait_start:=case when roll_wait then g.roll_wait_started_at else g.choice_started_at end;
 if wait_start is null or now()<wait_start+interval '60 seconds' then return jsonb_build_object('ok',false,'error','GAME_WAIT_TOO_SHORT'); end if;
 select * into gp from public.dungeon_game_players where game_id=g.id and player_id=p_target_player_id;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=p_target_player_id;
 if not coalesce(gp.active,false) or not (
  (roll_wait and g.roller_id=p_target_player_id and not gp.eliminated)
  or (not roll_wait and ((not gp.eliminated and g.phase='choosing' and ps.last_completed_round<g.round_index) or jsonb_array_length(coalesce(ps.state->'pendingChests','[]'))>0)))
  then return jsonb_build_object('ok',false,'error','GAME_TURN_DONE'); end if;
 if roll_wait then
  select player_id into next_roller from public.dungeon_game_players where game_id=g.id and active and not eliminated and player_id<>p_target_player_id
   order by (seat>gp.seat) desc,seat limit 1;
  if next_roller is null and p_action='skip' then return jsonb_build_object('ok',false,'error','GAME_NO_OTHER_ROLLER'); end if;
  -- Der Wurf wird weitergegeben, nicht der Spielzug übersprungen. Der Spieler
  -- bleibt bei "skip" dabei und darf nach dem Wurf ganz normal mitspielen.
  update public.dungeon_games set roller_id=next_roller,revision=revision+1 where id=g.id returning * into g;
 else
  update public.dungeon_game_player_states set state=state||jsonb_build_object('pendingChests','[]'::jsonb),
   last_completed_round=case when g.phase='choosing' then g.round_index else last_completed_round end,revision=revision+1,updated_at=now() where game_id=g.id and player_id=p_target_player_id;
  update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 end if;
 if p_action='remove' then
  update public.dungeon_game_players set active=false,removed_at=now(),departure_reason='removed' where game_id=g.id and player_id=p_target_player_id;
  -- Eine alte Partie kann vor dem Wurf noch eine Truhenauswahl besitzen.
  if not roll_wait and g.phase='waiting_roll' and g.roller_id=p_target_player_id then
   select player_id into next_roller from public.dungeon_game_players where game_id=g.id and active and not eliminated order by (seat>gp.seat) desc,seat limit 1;
   update public.dungeon_games set roller_id=next_roller where id=g.id returning * into g;
  end if;
 end if;
 insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,case when p_action='skip' then 'turn_skipped' else 'removed' end,
  jsonb_build_object('playerId',p_target_player_id,'round',g.round_index,'pendingChoicesSkipped',case when roll_wait then 0 else jsonb_array_length(coalesce(ps.state->'pendingChests','[]')) end,
   'skippedRoll',roll_wait,'nextRollerId',case when roll_wait then next_roller else null end));
 if roll_wait and next_roller is null then perform dungeon_private.finalize_game(g.id);
 else perform dungeon_private.settle_game_round(g.id); end if;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'wait',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
revoke all on function dungeon_private.preserve_roll_wait_clock() from public,anon,authenticated;
revoke all on function public.resolve_game_wait(text,uuid,integer,uuid,text,uuid) from public;
grant execute on function public.resolve_game_wait(text,uuid,integer,uuid,text,uuid) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(6) on conflict do nothing;
notify pgrst,'reload schema';
commit;
