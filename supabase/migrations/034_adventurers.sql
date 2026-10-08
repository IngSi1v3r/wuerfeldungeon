-- Würfeldungeon 1.2.0 · Abenteurer, zwei Folgerunden und Entscheidungsanalyse.
-- Einmal nach 032 installieren; wiederholbar. Keine bestehenden Daten löschen.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then raise exception 'Bitte zuerst Würfeldungeon 1.1.0 (032) installieren.';end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=16) then raise exception 'Bitte zuerst Würfeldungeon 1.1.0 (032) installieren.';end if;
end$$;
lock table dungeon_private.schema_migrations in exclusive mode;
create table if not exists dungeon_private.adventurer_decisions(
 id bigint generated always as identity primary key,
 game_id uuid not null references public.dungeon_games(id) on delete cascade,
 player_id uuid not null references public.dungeon_players(id),request_id uuid not null,
 round_index integer not null,state_revision bigint not null,algorithm_version integer not null,
 character text not null,kind text not null,cell_id text,middle_cell_id text,
 dice jsonb,state_before jsonb not null,analysis jsonb not null,recorded_at timestamptz not null default now(),
 unique(game_id,player_id,request_id)
);
create index if not exists dungeon_adventurer_journal_idx on dungeon_private.adventurer_decisions(game_id,id);
alter table dungeon_private.adventurer_decisions enable row level security;
revoke all on dungeon_private.adventurer_decisions from public,anon,authenticated;
-- Bestehende Abenteurer bekommen einen Charakter, ohne ihre Spielfortschritte
-- oder Markierungen zu ändern. Ihre bisherigen Namenszusätze entfallen.
update public.dungeon_players p set display_name=regexp_replace(p.display_name,' · KI$',''),
 preferences=p.preferences||jsonb_build_object('adventurerCharacter',(array['berserker','warden','treasure','rival','lucky'])[b.seat%5+1],
 'adventurerColor',(array['#d96355','#67b7ce','#dfb653','#b58cdb','#8bb967','#ee9b58','#e68baa','#86bdab'])[b.seat%8+1])
 from (select distinct on (gp.player_id) gp.player_id,gp.seat from public.dungeon_game_players gp order by gp.player_id,gp.seat) b
 where p.id=b.player_id and p.is_bot and not p.preferences ? 'adventurerCharacter';

create or replace function public.create_solo_game(p_session_token text,p_map_version_id uuid,p_name text,p_settings jsonb,p_bot_count integer,p_red_every integer,p_ai_only boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);previous dungeon_private.solo_create_requests%rowtype;
 hash text;answer jsonb;g public.dungeon_games%rowtype;bot uuid;count_players integer;q integer;i integer;settings jsonb;
 character text;characters jsonb;styles text[]:=array['cross','pencil','weave','spiral','claws','runes','stars','waves'];
 colors text[]:=array['#d96355','#67b7ce','#dfb653','#b58cdb','#8bb967','#ee9b58','#e68baa','#86bdab'];
 kinds text[]:=array['berserker','warden','treasure','rival','lucky'];
 names text[]:=array['Kupferklinge','Nebelpfote','Runenwacht','Glutfeder','Silberzahn','Moosschatten','Frostfunke','Steinherz'];
begin
 if p_request_id is null or p_ai_only is null or p_bot_count is null or p_bot_count not between 0 and 8
  or (p_ai_only and p_bot_count<1) or (not p_ai_only and p_bot_count>7)
  or p_red_every is null or p_red_every not between 0 and 16 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 characters:=coalesce(p_settings->'adventurers','[]'::jsonb);
 if jsonb_typeof(characters)<>'array' or jsonb_array_length(characters)>8 or exists(select 1 from jsonb_array_elements_text(characters) c where c not in ('berserker','warden','treasure','rival','lucky')) then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 count_players:=p_bot_count+case when p_ai_only then 0 else 1 end;
 q:=case when p_red_every=0 then count_players else p_red_every end;
 hash:=dungeon_private.token_hash(jsonb_build_object('map',p_map_version_id,'name',p_name,'settings',p_settings,'bots',p_bot_count,'q',q,'test',p_ai_only)::text);
 perform 1 from public.dungeon_players where id=player for no key update;
 select * into previous from dungeon_private.solo_create_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.payload_hash<>hash then return jsonb_build_object('ok',false,'error','GAME_REQUEST_INVALID');end if;
  return jsonb_build_object('ok',true,'gameId',previous.game_id);
 end if;
 settings:=(p_settings-'adventurers'-'aiVersion')||jsonb_build_object('maxPlayers',greatest(2,count_players));
 answer:=public.create_game(p_session_token,p_map_version_id,p_name,settings,'',p_request_id);
 if answer->'ok'<>'true'::jsonb then return answer;end if;
 select * into g from public.dungeon_games where id=(answer->>'gameId')::uuid for update;
 update public.dungeon_games game set mode=case when p_ai_only then 'ai_test' else 'solo' end,
  settings=game.settings||jsonb_build_object('redEvery',q,'aiVersion',2,'adventurers',characters) where id=g.id;
 if p_ai_only then delete from public.dungeon_game_players where game_id=g.id and player_id=player;end if;
 for i in 1..p_bot_count loop
  bot:=gen_random_uuid();character:=coalesce(characters->>(i-1),kinds[(i-1)%5+1]);
  insert into public.dungeon_players(id,username,display_name,is_bot,preferences)
   values(bot,'ki_'||substr(replace(bot::text,'-',''),1,28),names[i],true,jsonb_build_object('markStyle',styles[i],'adventurerCharacter',character,'adventurerColor',colors[i]));
  insert into public.dungeon_game_players(game_id,player_id,seat,last_seen_at)
   values(g.id,bot,case when p_ai_only then i-1 else i end,now());
 end loop;
 answer:=public.start_game(p_session_token,g.id,g.revision,gen_random_uuid());
 if answer->'ok'<>'true'::jsonb then raise exception 'SOLO_START_FAILED';end if;
 insert into dungeon_private.solo_create_requests values(player,p_request_id,hash,g.id);
 return jsonb_build_object('ok',true,'gameId',g.id);
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
  ctx:=jsonb_build_object('gameId',g.id,'character',coalesce(ps.preferences->>'adventurerCharacter','warden'),'seat',ps.seat,'redEvery',g.settings->'redEvery','dice',g.dice,'availablePool',dungeon_private.game_powerup_pool(g),'mandatoryCount',(select count(*) from public.dungeon_map_cells where version_id=g.map_version_id and kind in ('monster','boss','miniboss')),'playerId',ps.player_id,'round',g.round_index,'revision',ps.revision,'state',ps.state,'fog',g.settings->'fog','freeRed',dungeon_private.game_red_free(g,ps.player_id),
   'canRoll',t->'canRoll','canAct',t->'canAct','canLoseLife',t->'canLoseLife','pendingChest',ps.state->'pendingChests'->0,'availablePowerups',t->'availablePowerups',
   'roundRequirements',g.round_requirements,'tasks',dungeon_private.task_view(g,ps.player_id,ps.state),'taskClaims',(select coalesce(jsonb_agg(jsonb_build_object('key',task_key,'completedInRound',completed_in_round)),'[]') from public.dungeon_game_task_claims where game_id=g.id),'definition',jsonb_build_object('document',doc,'rules',v.rules,'graph',edges),
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

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'powerupPool',dungeon_private.game_powerup_pool(g),'roundRequirements',g.round_requirements,'visibleCells',dungeon_private.game_visible_cells(g,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'traps',(select coalesce(jsonb_agg(jsonb_build_object('cellId',cell_id,'activatedInRound',activated_in_round,'armed',activated_in_round<g.round_index)),'[]') from public.dungeon_game_trap_claims where game_id=g.id),
  'dice',g.dice,'choiceStartedAt',g.choice_started_at,'finalRound',g.final_round,'serverNow',now(),'rulesVersion',g.rules_version,
  'tasks',dungeon_private.task_view(g,p_viewer,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
  'results',case when g.status='finished' then dungeon_private.game_result_json(g,p_viewer)->'results' else '[]'::jsonb end,
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'isBot',p.is_bot,'character',coalesce(p.preferences->>'adventurerCharacter','warden'),'color',p.preferences->>'adventurerColor','markStyle',coalesce(p.preferences->>'markStyle','pencil'),'seat',gp.seat,
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

-- Die bestehenden Zug-RPCs bleiben die einzige verbindliche Regelprüfung.
-- Ein Protokoll entsteht nur für einen tatsächlich angenommenen Befehl.
create or replace function public.perform_adventurer_action(p_session_token text,p_game_id uuid,p_bot_id uuid,p_round integer,p_state_revision bigint,p_kind text,p_cell_id text,p_middle_cell_id text,p_use_red boolean,p_use_axe boolean,p_powerup text,p_request_id uuid,p_analysis jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare host uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;s jsonb;character text;answer jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.host_id<>host or g.mode='multiplayer' or not exists(select 1 from public.dungeon_game_players gp join public.dungeon_players p on p.id=gp.player_id where gp.game_id=g.id and p.id=p_bot_id and p.is_bot and gp.active) then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY');end if;
 if p_analysis is null or jsonb_typeof(p_analysis)<>'object' or octet_length(p_analysis::text)>250000 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 select state into s from public.dungeon_game_player_states where game_id=g.id and player_id=p_bot_id;
 select coalesce(preferences->>'adventurerCharacter','warden') into character from public.dungeon_players where id=p_bot_id;
 answer:=public.perform_ai_action(p_session_token,p_game_id,p_bot_id,p_round,p_state_revision,p_kind,p_cell_id,p_middle_cell_id,p_use_red,p_use_axe,p_powerup,p_request_id);
 if answer->'ok'='true'::jsonb and p_kind<>'roll' then
  insert into dungeon_private.adventurer_decisions(game_id,player_id,request_id,round_index,state_revision,algorithm_version,character,kind,cell_id,middle_cell_id,dice,state_before,analysis)
  values(g.id,p_bot_id,p_request_id,p_round,p_state_revision,2,character,p_kind,p_cell_id,p_middle_cell_id,g.dice,coalesce(s,'{}'),p_analysis) on conflict do nothing;
 end if;return answer;
end;
$$;
-- Inkrementeller Verlauf für den privaten Beobachter. Auch laufende Partien
-- können betrachtet werden; das Zurückblättern verändert keinen Spielzustand.
create or replace function public.get_adventurer_journal(p_session_token text,p_game_id uuid,p_after_frame bigint default 0,p_after_decision bigint default 0,p_after_roll bigint default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare host uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;frames jsonb;decisions jsonb;rolls jsonb;
begin
 select * into g from public.dungeon_games where id=p_game_id;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.host_id<>host or g.mode='multiplayer' then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY');end if;
 if p_after_frame is null or p_after_decision is null or p_after_roll is null or least(p_after_frame,p_after_decision,p_after_roll)<0 then return jsonb_build_object('ok',false,'error','GAME_INPUT_INVALID');end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'playerId',f.player_id,'round',f.round_index,'state',f.state,'dice',f.dice,'roundRequirements',f.round_requirements,'initial',f.initial_frame) order by f.id),'[]') into frames
 from (select * from dungeon_private.replay_frames where game_id=g.id and id>p_after_frame order by id limit 1000) f;
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'playerId',d.player_id,'round',d.round_index,'version',d.algorithm_version,'character',d.character,'kind',d.kind,'cellId',d.cell_id,'middleCellId',d.middle_cell_id,'dice',d.dice,'stateBefore',d.state_before,'analysis',d.analysis) order by d.id),'[]') into decisions
 from (select * from dungeon_private.adventurer_decisions where game_id=g.id and id>p_after_decision order by id limit 1000) d;
 select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'round',e.payload->'round','dice',e.payload->'dice') order by e.id),'[]') into rolls
 from (select * from public.dungeon_game_events where game_id=g.id and kind='rolled' and id>p_after_roll order by id limit 1000) e;
 return jsonb_build_object('ok',true,'frames',frames,'decisions',decisions,'rolls',rolls,'more',jsonb_array_length(frames)=1000 or jsonb_array_length(decisions)=1000 or jsonb_array_length(rolls)=1000,'version',2);
end;
$$;
revoke all on function public.perform_adventurer_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid,jsonb),public.get_adventurer_journal(text,uuid,bigint,bigint,bigint) from public;
grant execute on function public.perform_adventurer_action(text,uuid,uuid,integer,bigint,text,text,text,boolean,boolean,text,uuid,jsonb),public.get_adventurer_journal(text,uuid,bigint,bigint,bigint) to anon,authenticated,service_role;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'soloAIVersion',1,'highscoreVersion',1,'adventurerVersion',2,'releaseVersion','1.2.0','runeHitsVersion',1,'starterCosmeticsVersion',1,'portalFogVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;

insert into dungeon_private.schema_migrations(version) values(17) on conflict do nothing;
notify pgrst,'reload schema';
commit;
