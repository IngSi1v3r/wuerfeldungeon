-- Würfeldungeon 0.10.1 · nach 020_round_two.sql ausführen.
-- Bestehende Karten, Partien, Guthaben und Käufe bleiben erhalten.
begin;
do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte das bestehende Würfeldungeon-Projekt öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=10) then
  raise exception 'Bitte zuerst das Update 0.10.0 (020_round_two.sql) installieren.';
 end if;
end$$;

create table if not exists dungeon_private.cosmetic_catalog (
 category text not null check(category in ('diceStyle','cupStyle','campStyle')),
 value text not null,label text not null,price integer not null check(price>=0),position integer not null,
 primary key(category,value),unique(category,position)
);
insert into dungeon_private.cosmetic_catalog(category,value,label,price,position) values
 ('diceStyle','ivory','Elfenbein',0,0),('diceStyle','forest','Waldgrün',30,1),
 ('diceStyle','midnight','Mitternacht',40,2),('diceStyle','amber','Bernstein',50,3),
 ('cupStyle','leather','Leder',0,0),('cupStyle','wood','Holz',40,1),('cupStyle','runic','Runenbecher',60,2),
 ('campStyle','forest','Feenwald',0,0),('campStyle','dawn','Morgenlicht',40,1),
 ('campStyle','moon','Mondhain',60,2),('campStyle','autumn','Herbstwald',50,3)
 on conflict(category,value) do nothing;
create table if not exists dungeon_private.cosmetic_purchases (
 player_id uuid not null references public.dungeon_players(id),category text not null,value text not null,
 price integer not null check(price>=0),source text not null check(source in ('purchase','legacy')),
 purchased_at timestamptz not null default now(),primary key(player_id,category,value),
 foreign key(category,value) references dungeon_private.cosmetic_catalog(category,value)
);
create table if not exists dungeon_private.cosmetic_requests (
 player_id uuid not null references public.dungeon_players(id),request_id uuid not null,
 category text not null,value text not null,charged integer not null,already_owned boolean not null,
 created_at timestamptz not null default now(),primary key(player_id,request_id),
 foreign key(category,value) references dungeon_private.cosmetic_catalog(category,value)
);
alter table dungeon_private.cosmetic_catalog enable row level security;
alter table dungeon_private.cosmetic_purchases enable row level security;
alter table dungeon_private.cosmetic_requests enable row level security;
revoke all on dungeon_private.cosmetic_catalog,dungeon_private.cosmetic_purchases,dungeon_private.cosmetic_requests from public,anon,authenticated;

-- Bereits gewählte Varianten bleiben beim Wechsel zum Shop freigeschaltet.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=11) then
  insert into dungeon_private.cosmetic_purchases(player_id,category,value,price,source)
   select p.id,c.category,c.value,0,'legacy' from public.dungeon_players p
   join dungeon_private.cosmetic_catalog c on p.preferences->>c.category=c.value and c.price>0
   on conflict do nothing;
 end if;
end$$;

create or replace function dungeon_private.cosmetics_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',1,'cosmeticVersion',1,'balance',earned-spent,'earned',earned,'spent',spent,
  'unlocked',(select jsonb_agg(c.style order by c.position) from dungeon_private.marking_catalog c
   where c.style='cross' or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)),
  'cosmeticUnlocked',(select jsonb_object_agg(category,owned) from (
    select c.category,jsonb_agg(c.value order by c.position) owned from dungeon_private.cosmetic_catalog c
    where c.price=0 or exists(select 1 from dungeon_private.cosmetic_purchases p where p.player_id=p_player_id and p.category=c.category and p.value=c.value)
    group by c.category) categories))
 from (select coalesce((select sum(amount) from dungeon_private.marking_credits where player_id=p_player_id),0) earned,
  coalesce((select sum(price) from dungeon_private.marking_purchases where player_id=p_player_id),0)
  +coalesce((select sum(price) from dungeon_private.cosmetic_purchases where player_id=p_player_id),0) spent) amounts;
$$;

create or replace function dungeon_private.marking_shop_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(p_player_id),
  'items',(select jsonb_agg(jsonb_build_object('style',c.style,'label',c.label,'price',c.price,
   'owned',c.style='cross' or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)) order by c.position)
   from dungeon_private.marking_catalog c),
  'cosmeticItems',(select jsonb_agg(jsonb_build_object('category',c.category,'value',c.value,'label',c.label,'price',c.price,
   'owned',c.price=0 or exists(select 1 from dungeon_private.cosmetic_purchases p where p.player_id=p_player_id and p.category=c.category and p.value=c.value)) order by c.category,c.position)
   from dungeon_private.cosmetic_catalog c));
$$;

create or replace function public.buy_cosmetic(p_session_token text,p_category text,p_value text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);item dungeon_private.cosmetic_catalog%rowtype;
 previous dungeon_private.cosmetic_requests%rowtype;owned boolean;balance bigint;charged integer;
begin
 if p_request_id is null then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
 perform 1 from public.dungeon_players where id=player for update;
 select * into previous from dungeon_private.cosmetic_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.category is distinct from p_category or previous.value is distinct from p_value then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
  return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',previous.charged,'alreadyOwned',previous.already_owned,'replayed',true);
 end if;
 select * into item from dungeon_private.cosmetic_catalog where category=p_category and value=p_value;
 if not found then return jsonb_build_object('ok',false,'error','SHOP_STYLE_INVALID');end if;
 owned:=item.price=0 or exists(select 1 from dungeon_private.cosmetic_purchases where player_id=player and category=p_category and value=p_value);
 charged:=case when owned then 0 else item.price end;balance:=(dungeon_private.cosmetics_json(player)->>'balance')::bigint;
 if balance<charged then return jsonb_build_object('ok',false,'error','SHOP_INSUFFICIENT_DIAMONDS','balance',balance,'price',charged);end if;
 if not owned then
  insert into dungeon_private.cosmetic_purchases(player_id,category,value,price,source) values(player,p_category,p_value,charged,'purchase');
  update public.dungeon_players set revision=revision+1,updated_at=now() where id=player;
 end if;
 insert into dungeon_private.cosmetic_requests(player_id,request_id,category,value,charged,already_owned) values(player,p_request_id,p_category,p_value,charged,owned);
 return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',charged,'alreadyOwned',owned,'replayed',false);
end;
$$;

create or replace function dungeon_private.powerup_selection_valid(powers jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare value jsonb;seen text[]:='{}';
begin
 if jsonb_typeof(powers) is distinct from 'array' then return false;end if;
 if jsonb_array_length(powers)>6 then return false;end if;
 for value in select v from jsonb_array_elements(powers) v loop
  if jsonb_typeof(value)<>'string' or value#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (value#>>'{}')=any(seen) then return false;end if;
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
  and (not s ? 'allowedPowerups' or dungeon_private.powerup_selection_valid(s->'allowedPowerups')),false);
$$;

create or replace function dungeon_private.game_powerup_pool(g public.dungeon_games)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(g.settings->'allowedPowerups',v.allowed_powerups,'[]'::jsonb) from public.dungeon_map_versions v where v.id=g.map_version_id;
$$;
create or replace function dungeon_private.game_available_powerups(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements(dungeon_private.game_powerup_pool(g)) value
 where not coalesce(s->'powerups','[]') @> jsonb_build_array(value)
 and (value not in ('"binocular"'::jsonb,'"horn"'::jsonb) or (g.rules_version>=7 and g.settings->'fog'='true'::jsonb));
$$;

create or replace function public.update_lobby_powerups(p_session_token text,p_game_id uuid,p_powerups jsonb,p_expected_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;replay jsonb;
 payload jsonb:=jsonb_build_object('powerups',p_powerups,'revision',p_expected_revision);
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 if g.host_id<>player or not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active) then return jsonb_build_object('ok',false,'error','GAME_HOST_ONLY');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'lobby_powerups',payload);if replay is not null then return replay;end if;
 if g.status<>'lobby' then return jsonb_build_object('ok',false,'error','GAME_ALREADY_STARTED');end if;
 if g.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','GAME_CHANGED');end if;
 if not dungeon_private.powerup_selection_valid(p_powerups) then return jsonb_build_object('ok',false,'error','GAME_SETTINGS_INVALID');end if;
 update public.dungeon_games set settings=settings||jsonb_build_object('allowedPowerups',p_powerups),revision=revision+1 where id=g.id returning * into g;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'lobby_powerups',payload,g.revision);
end;
$$;

-- Weitere Funktionen auf Basis der unveränderten Migrationen von 0.10.0.
-- Auch ältere, noch offene Warteräume verwenden den eigenen Powerup-Pool.
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
  if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when defeated and not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'middleCellId',p_middle_cell_id,'axeUsed',p_use_axe,'round',g.round_index,'redUsed',chosen->'redOnly','reward',reward+intermediate_reward));
  if defeated then insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'enemy_defeated',jsonb_build_object('playerId',player,'cellId',c.cell_id,'round',g.round_index,'name',coalesce(nullif(c.definition->>'name',''),'Gegner #'||c.cell_id))); end if;
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,(select revision from public.dungeon_games where id=g.id));
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
 if p_settings ? 'allowedPowerups' then settings:=settings||jsonb_build_object('allowedPowerups',p_settings->'allowedPowerups');end if;
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

create or replace function dungeon_private.game_map_json(v public.dungeon_map_versions)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('allowedPowerups',v.allowed_powerups,'previewImage',v.document->'previewImage','id',v.map_id,'versionId',v.id,'name',v.name,
  'fields',jsonb_array_length(v.document->'rooms'),
  'enemies',(select count(*) from jsonb_array_elements(v.document->'rooms') r where r->>'type' in ('monster','miniboss','boss')),
  'preview',(select coalesce(jsonb_agg(jsonb_build_object('id',r->'id','type',r->'type','x',r->'x','y',r->'y','w',r->'w','h',r->'h','start',r->'start')),'[]') from jsonb_array_elements(v.document->'rooms') r));
$$;

create or replace function dungeon_private.game_detail(g public.dungeon_games,p_viewer uuid,p_definition boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object(
  'powerupPool',dungeon_private.game_powerup_pool(g),'roundRequirements',g.round_requirements,'visibleCells',dungeon_private.game_visible_cells(g,(select state from public.dungeon_game_player_states where game_id=g.id and player_id=p_viewer)),
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
  ||case when p_definition then jsonb_build_object('definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',dungeon_private.game_powerup_pool(g),'graph',v.compiled_graph,'contentHash',v.content_hash,'version',v.definition_version) from public.dungeon_map_versions v where v.id=g.map_version_id)) else '{}'::jsonb end;
$$;

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
  'definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',dungeon_private.game_powerup_pool(g),'graph',v.compiled_graph) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'players',players);
end;
$$;

create or replace function public.update_player_preferences(p_session_token text,p_preferences jsonb,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;prefs jsonb;current_revision bigint;current_preferences jsonb;
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
 select revision,preferences into current_revision,current_preferences from public.dungeon_players where id=player for update;
 if current_revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED');end if;
 if p_preferences->>'markStyle'<>'cross' and not exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_preferences->>'markStyle') then
  return jsonb_build_object('ok',false,'error','SHOP_STYLE_LOCKED');
 end if;
 if exists(select 1 from dungeon_private.cosmetic_catalog c
  where c.price>0 and c.value=coalesce(p_preferences->>c.category,current_preferences->>c.category,
    case c.category when 'diceStyle' then 'ivory' when 'cupStyle' then 'leather' else 'forest' end)
  and not exists(select 1 from dungeon_private.cosmetic_purchases owned where owned.player_id=player and owned.category=c.category and owned.value=c.value)) then
  return jsonb_build_object('ok',false,'error','SHOP_STYLE_LOCKED');
 end if;
 prefs:=jsonb_build_object('markStyle',p_preferences->'markStyle','sound',p_preferences->'sound','music',p_preferences->'music','reduceMotion',p_preferences->'reduceMotion');
 -- Alte Clients bewahren bereits gespeicherte Kosmetik und Animationsdauer.
 prefs:=current_preferences||prefs;
 if p_preferences ? 'diceStyle' then prefs:=prefs||jsonb_build_object('diceStyle',p_preferences->'diceStyle');end if;
 if p_preferences ? 'cupStyle' then prefs:=prefs||jsonb_build_object('cupStyle',p_preferences->'cupStyle');end if;
 if p_preferences ? 'campStyle' then prefs:=prefs||jsonb_build_object('campStyle',p_preferences->'campStyle');end if;
 if p_preferences ? 'diceAnimation' then prefs:=prefs||jsonb_build_object('diceAnimation',p_preferences->'diceAnimation');end if;
 update public.dungeon_players set preferences=prefs,revision=revision+1,updated_at=now() where id=player;
 return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player));
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;

revoke all on function public.buy_cosmetic(text,text,text,uuid),public.update_lobby_powerups(text,uuid,jsonb,bigint,uuid) from public;
grant execute on function public.buy_cosmetic(text,text,text,uuid),public.update_lobby_powerups(text,uuid,jsonb,bigint,uuid) to anon,authenticated;
revoke all on function dungeon_private.powerup_selection_valid(jsonb),dungeon_private.game_powerup_pool(public.dungeon_games) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(11) on conflict do nothing;
notify pgrst,'reload schema';
commit;
