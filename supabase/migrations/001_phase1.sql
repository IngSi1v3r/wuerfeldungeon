-- Würfeldungeon 0.1.0 / Phase 1
-- Einmal im SQL Editor des richtigen Supabase-Projekts ausführen.
-- Erneutes Ausführen verändert keine vorhandenen Spieler oder Karten.
-- Kein Passwort und kein Registrierungscode stehen in diesem Skript.
begin;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists dungeon_private;
revoke all on schema dungeon_private from public, anon, authenticated;

-- Explizit qualifizierte Kryptofunktionen funktionieren auch, wenn pgcrypto
-- in einem bestehenden Projekt nicht im Schema "extensions" installiert ist.
do $install_crypto$
declare ns text;
begin
  select n.nspname into ns from pg_catalog.pg_extension e
    join pg_catalog.pg_namespace n on n.oid = e.extnamespace
    where e.extname = 'pgcrypto';
  execute format($ddl$
    create or replace function dungeon_private.hash_password(p_value text)
    returns text language sql volatile set search_path = ''
    as $fn$ select %1$I.crypt(p_value, %1$I.gen_salt('bf', 10)) $fn$;
  $ddl$, ns);
  execute format($ddl$
    create or replace function dungeon_private.password_matches(p_value text, p_hash text)
    returns boolean language sql stable set search_path = ''
    as $fn$ select p_hash is not null and %1$I.crypt(p_value, p_hash) = p_hash $fn$;
  $ddl$, ns);
  execute format($ddl$
    create or replace function dungeon_private.token_hash(p_value text)
    returns text language sql immutable set search_path = ''
    as $fn$ select pg_catalog.encode(%1$I.digest(p_value, 'sha256'), 'hex') $fn$;
  $ddl$, ns);
  execute format($ddl$
    create or replace function dungeon_private.new_token()
    returns text language sql volatile set search_path = ''
    as $fn$ select pg_catalog.encode(%1$I.gen_random_bytes(32), 'hex') $fn$;
  $ddl$, ns);
end;
$install_crypto$;

create table if not exists dungeon_private.schema_migrations (
  version integer primary key,
  installed_at timestamptz not null default now()
);
create table if not exists dungeon_private.app_config (
  singleton boolean primary key default true check (singleton),
  registration_enabled boolean not null default true,
  registration_code_hash text,
  updated_at timestamptz not null default now()
);
insert into dungeon_private.app_config (singleton) values (true)
  on conflict (singleton) do nothing;

create table if not exists public.dungeon_players (
  id uuid primary key default gen_random_uuid(),
  username text not null unique check (username ~ '^[a-z0-9._-]{3,32}$'),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  avatar_path text,
  preferences jsonb not null default '{"markStyle":"pencil","sound":true,"music":false,"reduceMotion":false}',
  revision bigint not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists dungeon_private.player_credentials (
  player_id uuid primary key references public.dungeon_players(id) on delete cascade,
  password_hash text not null,
  password_updated_at timestamptz not null default now()
);
create table if not exists dungeon_private.player_sessions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.dungeon_players(id) on delete cascade,
  token_hash text not null unique check (char_length(token_hash) = 64),
  device_label text not null default 'Browser' check (char_length(device_label) <= 80),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '180 days'),
  revoked_at timestamptz
);
create index if not exists dungeon_sessions_player_idx
  on dungeon_private.player_sessions(player_id);
create table if not exists dungeon_private.auth_attempts (
  bucket text primary key,
  window_start timestamptz not null default now(),
  attempt_count integer not null default 0
);

-- Grundlage für Phase 2. Nicht veröffentlichte Karten bleiben bearbeitbar.
-- Veröffentlichte Definitionen werden separat eingefroren und NIE überschrieben.
create table if not exists public.dungeon_maps (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  status text not null default 'draft' check (status in ('draft','published','archived')),
  document jsonb not null default '{"format":"dungeon-layout-v6","rooms":[],"closedDoors":{},"nextId":1,"background":null}',
  document_version integer not null default 1,
  revision bigint not null default 1,
  allowed_powerups jsonb not null default '["extraLife","redDice","torch"]',
  cover_path text,
  created_by uuid not null references public.dungeon_players(id),
  updated_by uuid not null references public.dungeon_players(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz,
  check (jsonb_typeof(document) = 'object'),
  check (jsonb_typeof(allowed_powerups) = 'array')
);
create unique index if not exists dungeon_maps_name_idx
  on public.dungeon_maps(lower(btrim(name)));
create table if not exists public.dungeon_map_versions (
  id uuid primary key default gen_random_uuid(),
  map_id uuid not null unique references public.dungeon_maps(id) on delete restrict,
  name text not null,
  document jsonb not null,
  compiled_graph jsonb not null,
  rules jsonb not null default '{}',
  allowed_powerups jsonb not null,
  definition_version integer not null default 1,
  content_hash text not null,
  published_by uuid not null references public.dungeon_players(id),
  published_at timestamptz not null default now()
);
create table if not exists public.dungeon_map_cells (
  version_id uuid not null references public.dungeon_map_versions(id) on delete restrict,
  cell_id text not null,
  kind text not null check (kind in ('normal','diamond','chest','special','monster','miniboss','boss')),
  x integer not null, y integer not null,
  w integer not null check (w > 0), h integer not null check (h > 0),
  definition jsonb not null,
  primary key (version_id, cell_id)
);
create table if not exists public.dungeon_map_connections (
  version_id uuid not null,
  cell_a text not null,
  cell_b text not null,
  primary key (version_id, cell_a, cell_b),
  foreign key (version_id, cell_a) references public.dungeon_map_cells(version_id, cell_id),
  foreign key (version_id, cell_b) references public.dungeon_map_cells(version_id, cell_id),
  check (cell_a < cell_b)
);
create table if not exists dungeon_private.map_edit_locks (
  map_id uuid primary key references public.dungeon_maps(id) on delete cascade,
  player_id uuid not null references public.dungeon_players(id),
  session_id uuid not null references dungeon_private.player_sessions(id) on delete cascade,
  lease_until timestamptz not null,
  acquired_at timestamptz not null default now()
);

-- Grundlage für Phase 3–5. Noch keine öffentlichen Spiel-Schreibfunktionen.
create table if not exists public.dungeon_games (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  host_id uuid not null references public.dungeon_players(id),
  map_version_id uuid not null references public.dungeon_map_versions(id),
  status text not null default 'lobby' check (status in ('lobby','playing','paused','finished','cancelled')),
  settings jsonb not null default '{"maxPlayers":8,"cards":"open","hints":true}',
  revision bigint not null default 1,
  round_index integer not null default 0,
  roller_id uuid references public.dungeon_players(id),
  phase text not null default 'waiting_roll' check (phase in ('waiting_roll','choosing','round_complete','finished')),
  dice jsonb,
  paused_at timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  unique (id, map_version_id)
);
create table if not exists dungeon_private.game_passwords (
  game_id uuid primary key references public.dungeon_games(id) on delete cascade,
  password_hash text not null
);
create table if not exists public.dungeon_game_players (
  game_id uuid not null references public.dungeon_games(id) on delete cascade,
  player_id uuid not null references public.dungeon_players(id),
  seat integer not null check (seat >= 0),
  active boolean not null default true,
  eliminated boolean not null default false,
  joined_at timestamptz not null default now(),
  removed_at timestamptz,
  primary key (game_id, player_id),
  unique (game_id, seat)
);
create index if not exists dungeon_game_players_player_idx
  on public.dungeon_game_players(player_id);
create table if not exists public.dungeon_game_player_states (
  game_id uuid not null,
  player_id uuid not null,
  state jsonb not null default '{"reached":[],"monsterHits":{},"redUses":3,"torchUses":0,"axeUses":0,"lostLives":0,"extraLives":0,"diamonds":0,"powerups":[]}',
  last_completed_round integer not null default -1,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (game_id, player_id),
  foreign key (game_id, player_id) references public.dungeon_game_players(game_id, player_id) on delete cascade
);
create table if not exists public.dungeon_game_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.dungeon_games(id) on delete cascade,
  game_revision bigint not null,
  kind text not null,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists dungeon_game_events_game_idx
  on public.dungeon_game_events(game_id, id);
-- Ein globaler Erstbesieger pro Gegner und Spiel. Die eindeutige Zeile
-- ermöglicht später atomare Vergabe auch bei nahezu gleichzeitigen Angriffen.
create table if not exists public.dungeon_game_monster_claims (
  game_id uuid not null,
  map_version_id uuid not null,
  monster_cell_id text not null,
  first_player_id uuid not null,
  claimed_in_round integer not null check (claimed_in_round >= 0),
  created_at timestamptz not null default now(),
  primary key (game_id, monster_cell_id),
  foreign key (game_id, map_version_id) references public.dungeon_games(id, map_version_id),
  foreign key (map_version_id, monster_cell_id) references public.dungeon_map_cells(version_id, cell_id),
  foreign key (game_id, first_player_id) references public.dungeon_game_players(game_id, player_id)
);
create table if not exists dungeon_private.game_commands (
  game_id uuid not null references public.dungeon_games(id) on delete cascade,
  player_id uuid not null references public.dungeon_players(id),
  request_id uuid not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (game_id, player_id, request_id)
);
create table if not exists public.dungeon_game_results (
  game_id uuid not null,
  player_id uuid not null,
  total_points integer not null,
  diamonds integer not null default 0 check (diamonds >= 0),
  life_penalty integer not null default 0 check (life_penalty <= 0),
  monsters_defeated integer not null default 0 check (monsters_defeated >= 0),
  won boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (game_id, player_id),
  foreign key (game_id, player_id) references public.dungeon_game_players(game_id, player_id)
);
create index if not exists dungeon_game_results_player_idx
  on public.dungeon_game_results(player_id);
create table if not exists dungeon_private.assets (
  path text primary key,
  kind text not null check (kind in ('avatar','map')),
  owner_id uuid not null references public.dungeon_players(id),
  mime_type text not null,
  bytes integer not null check (bytes > 0),
  created_at timestamptz not null default now()
);

create or replace function dungeon_private.prevent_published_changes()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'PUBLISHED_MAP_IMMUTABLE';
end;
$$;
drop trigger if exists dungeon_immutable_versions on public.dungeon_map_versions;
create trigger dungeon_immutable_versions before update or delete on public.dungeon_map_versions
  for each row execute function dungeon_private.prevent_published_changes();
drop trigger if exists dungeon_immutable_cells on public.dungeon_map_cells;
create trigger dungeon_immutable_cells before update or delete on public.dungeon_map_cells
  for each row execute function dungeon_private.prevent_published_changes();
drop trigger if exists dungeon_immutable_connections on public.dungeon_map_connections;
create trigger dungeon_immutable_connections before update or delete on public.dungeon_map_connections
  for each row execute function dungeon_private.prevent_published_changes();

-- Tabellen sind NICHT über den öffentlichen Browser-Schlüssel les-/schreibbar.
-- Eigene Sitzungen sind keine Supabase-Auth-Benutzer; auth.uid()-Policies wären
-- hier falsch. Alle erlaubten Zugriffe erfolgen über die folgenden RPCs.
do $permissions$
declare item record;
begin
  for item in select table_schema, table_name from information_schema.tables
    where (table_schema = 'public' and table_name like 'dungeon\_%' escape '\')
      or table_schema = 'dungeon_private'
  loop
    execute format('alter table %I.%I enable row level security', item.table_schema, item.table_name);
    execute format('revoke all on table %I.%I from public, anon, authenticated', item.table_schema, item.table_name);
  end loop;
end;
$permissions$;

-- Kleine, serverseitige Bremse gegen versehentliche / automatisierte Versuche.
-- Rückgaben statt Exceptions erhalten den Versuchszähler auch bei Fehlern.
create or replace function dungeon_private.allow_auth_attempt(p_kind text, p_user text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare headers jsonb; ip text; key text; tries integer; limit_count integer;
begin
  begin
    headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  exception when others then headers := '{}'; end;
  ip := left(coalesce(headers ->> 'cf-connecting-ip', headers ->> 'x-forwarded-for', 'shared'), 180);
  key := dungeon_private.token_hash(p_kind || ':' || ip || ':' || coalesce(p_user, ''));
  limit_count := case when p_kind = 'register' then 20 else 15 end;
  delete from dungeon_private.auth_attempts where window_start < now() - interval '1 day';
  insert into dungeon_private.auth_attempts as attempts (bucket, window_start, attempt_count)
    values (key, now(), 1)
    on conflict (bucket) do update set
      window_start = case when attempts.window_start < now() - interval '10 minutes' then now() else attempts.window_start end,
      attempt_count = case when attempts.window_start < now() - interval '10 minutes' then 1 else least(attempts.attempt_count + 1, 1000) end
    returning attempt_count into tries;
  return tries <= limit_count;
end;
$$;

create or replace function dungeon_private.issue_session(p_player_id uuid, p_device_label text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare token text; session_id uuid; expires timestamptz;
begin
  token := dungeon_private.new_token();
  delete from dungeon_private.player_sessions
    where expires_at < now() - interval '30 days' or revoked_at < now() - interval '30 days';
  insert into dungeon_private.player_sessions (player_id, token_hash, device_label)
    values (p_player_id, dungeon_private.token_hash(token), coalesce(nullif(left(btrim(p_device_label),80),''),'Browser'))
    returning id, expires_at into session_id, expires;
  return jsonb_build_object('token',token,'id',session_id,'expiresAt',expires);
end;
$$;

create or replace function dungeon_private.require_player(p_session_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare s dungeon_private.player_sessions%rowtype;
begin
  if p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$' then
    raise exception 'SESSION_INVALID';
  end if;
  select * into s from dungeon_private.player_sessions
    where token_hash = dungeon_private.token_hash(p_session_token)
      and revoked_at is null and expires_at > now();
  if not found then raise exception 'SESSION_INVALID'; end if;
  -- Gleitende 180 Tage; nicht bei jedem Seitenklick eine Schreiboperation.
  if s.last_seen_at < now() - interval '1 day' then
    update dungeon_private.player_sessions set last_seen_at = now(), expires_at = now() + interval '180 days'
      where id = s.id and revoked_at is null;
  end if;
  return s.player_id;
end;
$$;

create or replace function dungeon_private.profile_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id',p.id,'username',p.username,'displayName',p.display_name,
    'avatarPath',p.avatar_path,'preferences',p.preferences,'revision',p.revision,
    'createdAt',p.created_at,
    'stats',jsonb_build_object(
      'gamesPlayed',(select count(*) from public.dungeon_game_results r where r.player_id=p.id),
      'totalPoints',(select coalesce(sum(r.total_points),0) from public.dungeon_game_results r where r.player_id=p.id),
      'averagePoints',(select coalesce(round(avg(r.total_points),1),0) from public.dungeon_game_results r where r.player_id=p.id),
      'wins',(select count(*) from public.dungeon_game_results r where r.player_id=p.id and r.won),
      'monstersDefeated',(select coalesce(sum(r.monsters_defeated),0) from public.dungeon_game_results r where r.player_id=p.id)
    )
  ) from public.dungeon_players p where p.id=p_player_id;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok',true,'schemaVersion',1,
    'registrationOpen',registration_enabled and registration_code_hash is not null)
    from dungeon_private.app_config where singleton;
$$;

create or replace function public.register_player(
  p_username text, p_display_name text, p_password text, p_access_code text,
  p_device_label text default 'Browser'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare user_name text := lower(btrim(p_username)); display text := btrim(p_display_name);
  config dungeon_private.app_config%rowtype; player_id uuid; session_data jsonb;
begin
  if not dungeon_private.allow_auth_attempt('register','') then
    return jsonb_build_object('ok',false,'error','RATE_LIMIT');
  end if;
  select * into config from dungeon_private.app_config where singleton;
  if not config.registration_enabled or config.registration_code_hash is null then
    return jsonb_build_object('ok',false,'error','REGISTRATION_CLOSED');
  end if;
  if p_access_code is null or octet_length(p_access_code) > 72
    or not dungeon_private.password_matches(p_access_code, config.registration_code_hash) then
    return jsonb_build_object('ok',false,'error','ACCESS_CODE_INVALID');
  end if;
  if user_name is null or user_name !~ '^[a-z0-9._-]{3,32}$' then
    return jsonb_build_object('ok',false,'error','USERNAME_INVALID');
  end if;
  if display is null or char_length(display) not between 1 and 40 then
    return jsonb_build_object('ok',false,'error','DISPLAY_NAME_INVALID');
  end if;
  if p_password is null or char_length(p_password) < 6 or octet_length(p_password) > 72 then
    return jsonb_build_object('ok',false,'error','PASSWORD_INVALID');
  end if;
  begin
    insert into public.dungeon_players (username, display_name) values (user_name, display)
      returning id into player_id;
  exception when unique_violation then
    return jsonb_build_object('ok',false,'error','USERNAME_TAKEN');
  end;
  insert into dungeon_private.player_credentials (player_id, password_hash)
    values (player_id, dungeon_private.hash_password(p_password));
  session_data := dungeon_private.issue_session(player_id, p_device_label);
  return jsonb_build_object('ok',true,'session',session_data,
    'profile',dungeon_private.profile_json(player_id));
end;
$$;

create or replace function public.login_player(
  p_username text, p_password text, p_device_label text default 'Browser'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare user_name text := lower(btrim(p_username)); player_id uuid; password_hash text;
  session_data jsonb;
begin
  if not dungeon_private.allow_auth_attempt('login',coalesce(user_name,'')) then
    return jsonb_build_object('ok',false,'error','RATE_LIMIT');
  end if;
  if p_password is null or octet_length(p_password) > 72 or user_name is null
    or user_name !~ '^[a-z0-9._-]{3,32}$' then
    return jsonb_build_object('ok',false,'error','LOGIN_INVALID');
  end if;
  select p.id,c.password_hash into player_id,password_hash
    from public.dungeon_players p join dungeon_private.player_credentials c on c.player_id=p.id
    where p.username=user_name;
  if player_id is null or not dungeon_private.password_matches(p_password,password_hash) then
    return jsonb_build_object('ok',false,'error','LOGIN_INVALID');
  end if;
  session_data := dungeon_private.issue_session(player_id,p_device_label);
  return jsonb_build_object('ok',true,'session',session_data,
    'profile',dungeon_private.profile_json(player_id));
end;
$$;

create or replace function public.validate_player_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare player_id uuid; expires timestamptz;
begin
  player_id := dungeon_private.require_player(p_session_token);
  select expires_at into expires from dungeon_private.player_sessions
    where token_hash=dungeon_private.token_hash(p_session_token);
  return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player_id),'expiresAt',expires);
end;
$$;

create or replace function public.get_player_profile(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(dungeon_private.require_player(p_session_token)));
end;
$$;

create or replace function public.get_home_data(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_player_id uuid;
begin
  v_player_id := dungeon_private.require_player(p_session_token);
  return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(v_player_id),
    'counts',jsonb_build_object(
      'publishedMaps',(select count(*) from public.dungeon_maps where status='published'),
      'openLobbies',(select count(*) from public.dungeon_games where status='lobby'),
      'activeGames',(select count(*) from public.dungeon_games g
        join public.dungeon_game_players gp on gp.game_id=g.id
        where gp.player_id=v_player_id and gp.active and g.status in ('playing','paused'))
    ));
end;
$$;

create or replace function public.update_player_profile(
  p_session_token text, p_display_name text, p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare player_id uuid; display text := btrim(p_display_name); changed uuid;
begin
  player_id := dungeon_private.require_player(p_session_token);
  if display is null or char_length(display) not between 1 and 40 then
    return jsonb_build_object('ok',false,'error','DISPLAY_NAME_INVALID');
  end if;
  update public.dungeon_players set display_name=display,revision=revision+1,updated_at=now()
    where id=player_id and revision=p_expected_revision returning id into changed;
  if changed is null then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED'); end if;
  return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player_id));
end;
$$;

create or replace function public.update_player_preferences(
  p_session_token text, p_preferences jsonb, p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare player_id uuid; prefs jsonb; changed uuid;
begin
  player_id := dungeon_private.require_player(p_session_token);
  if p_preferences is null or jsonb_typeof(p_preferences)<>'object'
    or coalesce(p_preferences ->> 'markStyle','') not in ('pencil','cross','solid','waves')
    or jsonb_typeof(p_preferences -> 'sound') is distinct from 'boolean'
    or jsonb_typeof(p_preferences -> 'music') is distinct from 'boolean'
    or jsonb_typeof(p_preferences -> 'reduceMotion') is distinct from 'boolean' then
    return jsonb_build_object('ok',false,'error','PREFERENCES_INVALID');
  end if;
  prefs := jsonb_build_object('markStyle',p_preferences -> 'markStyle',
    'sound',p_preferences -> 'sound','music',p_preferences -> 'music','reduceMotion',p_preferences -> 'reduceMotion');
  update public.dungeon_players set preferences=prefs,revision=revision+1,updated_at=now()
    where id=player_id and revision=p_expected_revision returning id into changed;
  if changed is null then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED'); end if;
  return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player_id));
end;
$$;

create or replace function public.list_player_sessions(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_player_id uuid; current_hash text;
begin
  v_player_id := dungeon_private.require_player(p_session_token);
  current_hash := dungeon_private.token_hash(p_session_token);
  return jsonb_build_object('ok',true,'sessions',coalesce((
    select jsonb_agg(jsonb_build_object('id',s.id,'deviceLabel',s.device_label,
      'createdAt',s.created_at,'lastSeenAt',s.last_seen_at,'current',s.token_hash=current_hash)
      order by s.created_at desc)
    from dungeon_private.player_sessions s
    where s.player_id=v_player_id and s.revoked_at is null and s.expires_at>now()
  ),'[]'::jsonb));
end;
$$;

create or replace function public.revoke_player_session(p_session_token text, p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_player_id uuid;
begin
  v_player_id := dungeon_private.require_player(p_session_token);
  update dungeon_private.player_sessions set revoked_at=now()
    where player_sessions.player_id=v_player_id and id=p_session_id and revoked_at is null;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.logout_player_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  -- Logout ist idempotent, auch für eine abgelaufene Sitzung.
  if p_session_token ~ '^[a-f0-9]{64}$' then
    update dungeon_private.player_sessions set revoked_at=now()
      where token_hash=dungeon_private.token_hash(p_session_token) and revoked_at is null;
  end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.remove_player_avatar(p_session_token text, p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare player_id uuid; old_path text;
begin
  player_id := dungeon_private.require_player(p_session_token);
  select avatar_path into old_path from public.dungeon_players
    where id=player_id and revision=p_expected_revision for update;
  if not found then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED'); end if;
  update public.dungeon_players set avatar_path=null,revision=revision+1,updated_at=now()
    where id=player_id;
  return jsonb_build_object('ok',true,'oldPath',old_path,'profile',dungeon_private.profile_json(player_id));
end;
$$;

-- Ausschließlich die Edge Function (service_role) darf diesen RPC aufrufen.
-- Der Sitzungsschlüssel wird auch hier NOCH EINMAL geprüft.
create or replace function public.app_finish_avatar_upload(
  p_session_token text, p_path text, p_bytes integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare player_id uuid; old_path text;
begin
  player_id := dungeon_private.require_player(p_session_token);
  if p_path is null or p_path !~ ('^' || player_id::text || '/[a-f0-9-]{36}\.webp$')
    or p_bytes is null or p_bytes not between 1 and 524288 then
    raise exception 'AVATAR_INVALID';
  end if;
  select avatar_path into old_path from public.dungeon_players where id=player_id for update;
  insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes)
    values(p_path,'avatar',player_id,'image/webp',p_bytes);
  update public.dungeon_players set avatar_path=p_path,revision=revision+1,updated_at=now() where id=player_id;
  return jsonb_build_object('ok',true,'oldPath',old_path,'profile',dungeon_private.profile_json(player_id));
end;
$$;

-- Supabase legt das Schema storage an. In lokalen SQL-Tests wird nur diese
-- vorhandene Plattform-Tabelle nachgebildet; das Storage-System selbst nicht.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
  values ('avatars','avatars',true,524288,array['image/webp']),
    ('map-assets','map-assets',true,8388608,array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set public=excluded.public,
    file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
-- Keine INSERT/UPDATE/DELETE-Policies für anon auf storage.objects erstellen!
-- Uploads laufen nur nach eigener Sitzungsprüfung durch die Edge Function.

revoke all on all functions in schema dungeon_private from public, anon, authenticated;
revoke all on function public.app_status() from public;
revoke all on function public.register_player(text,text,text,text,text) from public;
revoke all on function public.login_player(text,text,text) from public;
revoke all on function public.validate_player_session(text) from public;
revoke all on function public.get_player_profile(text) from public;
revoke all on function public.get_home_data(text) from public;
revoke all on function public.update_player_profile(text,text,bigint) from public;
revoke all on function public.update_player_preferences(text,jsonb,bigint) from public;
revoke all on function public.list_player_sessions(text) from public;
revoke all on function public.revoke_player_session(text,uuid) from public;
revoke all on function public.logout_player_session(text) from public;
revoke all on function public.remove_player_avatar(text,bigint) from public;
revoke all on function public.app_finish_avatar_upload(text,text,integer) from public, anon, authenticated;

grant execute on function public.app_status() to anon, authenticated, service_role;
grant execute on function public.register_player(text,text,text,text,text) to anon, authenticated, service_role;
grant execute on function public.login_player(text,text,text) to anon, authenticated, service_role;
grant execute on function public.validate_player_session(text) to anon, authenticated, service_role;
grant execute on function public.get_player_profile(text) to anon, authenticated, service_role;
grant execute on function public.get_home_data(text) to anon, authenticated, service_role;
grant execute on function public.update_player_profile(text,text,bigint) to anon, authenticated, service_role;
grant execute on function public.update_player_preferences(text,jsonb,bigint) to anon, authenticated, service_role;
grant execute on function public.list_player_sessions(text) to anon, authenticated, service_role;
grant execute on function public.revoke_player_session(text,uuid) to anon, authenticated, service_role;
grant execute on function public.logout_player_session(text) to anon, authenticated, service_role;
grant execute on function public.remove_player_avatar(text,bigint) to anon, authenticated, service_role;
grant execute on function public.app_finish_avatar_upload(text,text,integer) to service_role;

insert into dungeon_private.schema_migrations(version) values(1) on conflict do nothing;
notify pgrst, 'reload schema';
commit;
