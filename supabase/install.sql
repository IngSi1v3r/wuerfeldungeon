-- Würfeldungeon 1.2.0: vollständige Einrichtung eines LEEREN Supabase-Projekts.
-- Bestehende Version 1.1.0 ausschließlich mit 034_adventurers.sql aktualisieren.
-- Registrierung ohne Zugangscode; der optionale Code kann später aktiviert werden.
begin;
do $$begin
 if to_regclass('public.dungeon_players') is not null then
  raise exception 'Dieses Projekt ist bereits eingerichtet. Bitte das Upgrade statt install.sql verwenden.';
 end if;
end$$;

-- Einmal im SQL Editor des richtigen Supabase-Projekts ausführen.
-- Erneutes Ausführen verändert keine vorhandenen Spieler oder Karten.
-- Kein Passwort und kein Registrierungscode stehen in diesem Skript.

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

-- Spieler, Sitzungsschlüssel und privater Registrierungscode bleiben erhalten.

alter table dungeon_private.map_edit_locks add column if not exists editor_id uuid not null default gen_random_uuid();
create table if not exists dungeon_private.map_save_requests (
  map_id uuid not null references public.dungeon_maps(id) on delete cascade,
  request_id uuid not null,
  editor_id uuid not null,
  payload_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (map_id,request_id)
);
alter table dungeon_private.map_save_requests enable row level security;
revoke all on dungeon_private.map_save_requests from public,anon,authenticated;

create or replace function dungeon_private.json_int(v jsonb,lo numeric,hi numeric)
returns boolean language sql immutable set search_path='' as $$
  select case when jsonb_typeof(v)='number' then (v::text)::numeric between lo and hi and trunc((v::text)::numeric)=(v::text)::numeric else false end;
$$;
create or replace function dungeon_private.dice_number(v jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(v='"doubles"'::jsonb or dungeon_private.json_int(v,2,12),false);
$$;
create or replace function dungeon_private.map_image_valid(v jsonb)
returns boolean language plpgsql stable set search_path='' as $$
begin
  if v is null or v='null'::jsonb then return true; end if;
  return coalesce(jsonb_typeof(v)='object'
    and jsonb_typeof(v->'src')='string'
    and v->>'src' ~ '^asset:[a-f0-9-]{36}/[a-f0-9-]{36}\.(png|jpg|webp)$'
    and dungeon_private.json_int(v->'width',1,4096) and dungeon_private.json_int(v->'height',1,4096)
    and jsonb_typeof(v->'name')='string' and char_length(v->>'name')<=200
    and exists(select 1 from dungeon_private.assets a where a.path=substring(v->>'src' from 7) and a.kind='map'),false);
end;
$$;

create or replace function dungeon_private.empty_map_document()
returns jsonb language sql immutable set search_path='' as $$
 select '{"format":"dungeon-layout-v6","rooms":[],"closedDoors":{},"nextId":1,"background":null,"printLayout":{"format":"auto","padding":24,"name":"","board":{"x":0,"y":0,"scale":1},"title":{"image":null,"x":0,"y":0,"scale":1},"rule":{"image":null,"x":0,"y":0,"scale":1}},"rules":{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}},"allowedPowerups":["extraLife","redDice","torch"]}'::jsonb;
$$;
create or replace function dungeon_private.map_json(m public.dungeon_maps,p_full boolean default false)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',m.id,'name',m.name,'status',m.status,'revision',m.revision,
  'createdAt',m.created_at,'updatedAt',m.updated_at,'publishedAt',m.published_at,'allowedPowerups',m.allowed_powerups,
  'creator',(select display_name from public.dungeon_players where id=m.created_by),
  'updatedBy',(select display_name from public.dungeon_players where id=m.updated_by),
  'versionId',(select id from public.dungeon_map_versions where map_id=m.id),
  'fields',jsonb_array_length(m.document->'rooms'),
  'enemies',(select count(*) from jsonb_array_elements(m.document->'rooms') r where r->>'type' in ('monster','miniboss','boss')),
  'bosses',(select count(*) from jsonb_array_elements(m.document->'rooms') r where r->>'type' in ('boss','miniboss')),
  'preview',(select coalesce(jsonb_agg(jsonb_build_object('id',r->'id','type',r->'type','x',r->'x','y',r->'y','w',r->'w','h',r->'h','start',r->'start')),'[]') from jsonb_array_elements(m.document->'rooms') r),
  'lock',(select jsonb_build_object('holder',p.display_name,'until',l.lease_until) from dungeon_private.map_edit_locks l
    join public.dungeon_players p on p.id=l.player_id join dungeon_private.player_sessions s on s.id=l.session_id
    where l.map_id=m.id and l.lease_until>now() and s.revoked_at is null and s.expires_at>now()))
  || case when p_full then jsonb_build_object('document',m.document) else '{}'::jsonb end;
$$;
create or replace function dungeon_private.owns_map_lock(p_session_token text,p_map_id uuid,p_editor_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from dungeon_private.map_edit_locks l join dungeon_private.player_sessions s on s.id=l.session_id
  where l.map_id=p_map_id and l.editor_id=p_editor_id and l.lease_until>now()
    and s.token_hash=dungeon_private.token_hash(p_session_token) and s.revoked_at is null and s.expires_at>now());
$$;

create or replace function public.list_maps(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 return jsonb_build_object('ok',true,'maps',(select coalesce(jsonb_agg(dungeon_private.map_json(m) order by m.updated_at desc,m.id),'[]') from public.dungeon_maps m));
end;
$$;
create or replace function public.get_map(p_session_token text,p_map_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.dungeon_maps%rowtype;
begin
 perform dungeon_private.require_player(p_session_token);
 select * into m from public.dungeon_maps where id=p_map_id;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true));
end;
$$;
create or replace function public.create_map(p_session_token text,p_name text,p_document jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; d jsonb:=coalesce(p_document,dungeon_private.empty_map_document());
begin
 if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then return jsonb_build_object('ok',false,'error','MAP_NAME_INVALID'); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 insert into public.dungeon_maps(name,document,allowed_powerups,created_by,updated_by) values(btrim(p_name),d,d->'allowedPowerups',player,player) returning * into m;
 return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true));
exception when unique_violation then return jsonb_build_object('ok',false,'error','MAP_NAME_TAKEN');
end;
$$;
create or replace function public.copy_map(p_session_token text,p_map_id uuid,p_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d jsonb;
begin
 perform dungeon_private.require_player(p_session_token);
 select document into d from public.dungeon_maps where id=p_map_id;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 return public.create_map(p_session_token,p_name,d);
end;
$$;

create or replace function public.acquire_map_lock(p_session_token text,p_map_id uuid,p_editor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; sid uuid; l dungeon_private.map_edit_locks%rowtype;
begin
 if p_editor_id is null then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 if m.status<>'draft' then return jsonb_build_object('ok',true,'acquired',false,'map',dungeon_private.map_json(m,true)); end if;
 select id into sid from dungeon_private.player_sessions where token_hash=dungeon_private.token_hash(p_session_token);
 select * into l from dungeon_private.map_edit_locks where map_id=p_map_id;
 if found and l.lease_until>now() and (l.session_id<>sid or l.editor_id<>p_editor_id)
   and exists(select 1 from dungeon_private.player_sessions where id=l.session_id and revoked_at is null and expires_at>now()) then
   return jsonb_build_object('ok',true,'acquired',false,'map',dungeon_private.map_json(m,true));
 end if;
 insert into dungeon_private.map_edit_locks(map_id,player_id,session_id,editor_id,lease_until)
   values(p_map_id,player,sid,p_editor_id,now()+interval '120 seconds') on conflict(map_id) do update
   set player_id=excluded.player_id,session_id=excluded.session_id,editor_id=excluded.editor_id,lease_until=excluded.lease_until,acquired_at=now();
 return jsonb_build_object('ok',true,'acquired',true,'map',dungeon_private.map_json(m,true),'leaseUntil',now()+interval '120 seconds');
end;
$$;
create or replace function public.heartbeat_map_lock(p_session_token text,p_map_id uuid,p_editor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 -- Derselbe Zeilen-Lock wie beim Übernehmen verhindert ein Verlängern einer
 -- gerade von einem anderen Editor übernommenen Sperre.
 perform 1 from public.dungeon_maps where id=p_map_id for update;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 update dungeon_private.map_edit_locks set lease_until=now()+interval '120 seconds' where map_id=p_map_id;
 return jsonb_build_object('ok',true,'leaseUntil',now()+interval '120 seconds');
end;
$$;
create or replace function public.release_map_lock(p_session_token text,p_map_id uuid,p_editor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 perform 1 from public.dungeon_maps where id=p_map_id for update;
 delete from dungeon_private.map_edit_locks l using dungeon_private.player_sessions s where l.session_id=s.id
   and l.map_id=p_map_id and l.editor_id=p_editor_id and s.token_hash=dungeon_private.token_hash(p_session_token);
 return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.save_map(p_session_token text,p_map_id uuid,p_editor_id uuid,p_expected_revision bigint,p_name text,p_document jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; request dungeon_private.map_save_requests%rowtype;
  hash text:=md5(jsonb_build_object('name',btrim(p_name),'document',p_document,'expectedRevision',p_expected_revision)::text); result jsonb;
begin
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 if m.status<>'draft' then return jsonb_build_object('ok',false,'error','MAP_READ_ONLY'); end if;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 if p_request_id is null then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 select * into request from dungeon_private.map_save_requests where map_id=p_map_id and request_id=p_request_id;
 if found then
   if request.editor_id<>p_editor_id or request.payload_hash<>hash then return jsonb_build_object('ok',false,'error','MAP_REQUEST_INVALID'); end if;
   return request.response;
 end if;
 if m.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','MAP_CHANGED','revision',m.revision); end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then return jsonb_build_object('ok',false,'error','MAP_NAME_INVALID'); end if;
 if not dungeon_private.map_document_valid(p_document) then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 update public.dungeon_maps set name=btrim(p_name),document=p_document,allowed_powerups=p_document->'allowedPowerups',revision=revision+1,updated_by=player,updated_at=now() where id=p_map_id returning * into m;
 result:=jsonb_build_object('ok',true,'map',dungeon_private.map_json(m));
 insert into dungeon_private.map_save_requests(map_id,request_id,editor_id,payload_hash,response) values(p_map_id,p_request_id,p_editor_id,hash,result);
 delete from dungeon_private.map_save_requests where map_id=p_map_id and created_at<now()-interval '7 days';
 return result;
exception when unique_violation then return jsonb_build_object('ok',false,'error','MAP_NAME_TAKEN');
end;
$$;
create or replace function public.check_map(p_session_token text,p_map_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare m public.dungeon_maps%rowtype;
begin
 perform dungeon_private.require_player(p_session_token);
 select * into m from public.dungeon_maps where id=p_map_id;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 return jsonb_build_object('ok',true,'revision',m.revision,'report',dungeon_private.map_report(m.document));
end;
$$;
create or replace function public.publish_map(p_session_token text,p_map_id uuid,p_editor_id uuid,p_expected_revision bigint,p_accept_warnings boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; report jsonb; version_id uuid; frozen_rules jsonb;
begin
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 if m.status='published' then return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true)); end if;
 if m.status<>'draft' then return jsonb_build_object('ok',false,'error','MAP_READ_ONLY'); end if;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 if m.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','MAP_CHANGED'); end if;
 report:=dungeon_private.map_report(m.document);
 if jsonb_array_length(report->'errors')>0 then return jsonb_build_object('ok',false,'error','MAP_INCOMPLETE','report',report); end if;
 if jsonb_array_length(report->'warnings')>0 and not p_accept_warnings then return jsonb_build_object('ok',false,'error','MAP_WARNINGS','report',report); end if;
 frozen_rules:=m.document->'rules'||jsonb_build_object('specialCellIds',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(m.document->'rooms') r where r->>'type'='special'));
 insert into public.dungeon_map_versions(map_id,name,document,compiled_graph,rules,allowed_powerups,definition_version,content_hash,published_by)
  values(m.id,m.name,m.document,report->'graph',frozen_rules,m.allowed_powerups,1,dungeon_private.token_hash(m.document::text),player) returning id into version_id;
 insert into public.dungeon_map_cells(version_id,cell_id,kind,x,y,w,h,definition)
  select version_id,r->>'id',r->>'type',(r->>'x')::int,(r->>'y')::int,(r->>'w')::int,(r->>'h')::int,r from jsonb_array_elements(m.document->'rooms') r;
 insert into public.dungeon_map_connections(version_id,cell_a,cell_b) select version_id,cell_a,cell_b from dungeon_private.map_edges(m.document);
 update public.dungeon_maps set status='published',published_at=now(),updated_at=now(),updated_by=player,revision=revision+1 where id=m.id returning * into m;
 delete from dungeon_private.map_edit_locks where map_id=m.id;
 return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true),'report',report);
end;
$$;
create or replace function public.delete_map(p_session_token text,p_map_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype;
begin
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',true,'deleted',true); end if;
 if m.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','MAP_CHANGED'); end if;
 if exists(select 1 from dungeon_private.map_edit_locks l join dungeon_private.player_sessions s on s.id=l.session_id where l.map_id=m.id and l.lease_until>now() and s.revoked_at is null and s.expires_at>now()) then return jsonb_build_object('ok',false,'error','MAP_BUSY'); end if;
 if m.status='draft' then
   delete from public.dungeon_maps where id=m.id;
   return jsonb_build_object('ok',true,'deleted',true);
 end if;
 update public.dungeon_maps set status='archived',revision=revision+1,updated_at=now(),updated_by=player where id=m.id;
 return jsonb_build_object('ok',true,'archived',true);
end;
$$;

create or replace function public.app_authorize_map_asset(p_session_token text,p_map_id uuid,p_editor_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 if not exists(select 1 from public.dungeon_maps where id=p_map_id and status='draft') then return jsonb_build_object('ok',false,'error','MAP_READ_ONLY'); end if;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 return jsonb_build_object('ok',true);
end;
$$;
create or replace function public.app_finish_map_asset(p_session_token text,p_map_id uuid,p_editor_id uuid,p_path text,p_mime text,p_bytes integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); result jsonb; extension text;
begin
 perform 1 from public.dungeon_maps where id=p_map_id for update;
 result:=public.app_authorize_map_asset(p_session_token,p_map_id,p_editor_id);
 if not (result->>'ok')::boolean then return result; end if;
 extension:=case p_mime when 'image/png' then '.png' when 'image/jpeg' then '.jpg' else '.webp' end;
 if p_path is null or p_path !~ ('^'||p_map_id::text||'/[a-f0-9-]{36}\.(png|jpg|webp)$')
   or p_mime is null or p_mime not in ('image/png','image/jpeg','image/webp') or p_bytes is null or p_bytes not between 1 and 8388608
   or right(p_path,char_length(extension))<>extension then
   return jsonb_build_object('ok',false,'error','MAP_IMAGE_INVALID');
 end if;
 insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values(p_path,'map',player,p_mime,p_bytes);
 return jsonb_build_object('ok',true,'path',p_path);
end;
$$;

create or replace function dungeon_private.guard_map_definition()
returns trigger language plpgsql set search_path='' as $$
begin
 if old.status<>'draft' then
   if tg_op='DELETE' then raise exception 'PUBLISHED_MAP_IMMUTABLE'; end if;
   if new.document is distinct from old.document or new.name is distinct from old.name or new.allowed_powerups is distinct from old.allowed_powerups or new.status='draft' then raise exception 'PUBLISHED_MAP_IMMUTABLE'; end if;
 end if;
 return case when tg_op='DELETE' then old else new end;
end;
$$;
drop trigger if exists dungeon_map_definition_guard on public.dungeon_maps;
create trigger dungeon_map_definition_guard before update or delete on public.dungeon_maps for each row execute function dungeon_private.guard_map_definition();

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare r jsonb; a jsonb; b jsonb; l jsonb; rules jsonb; goal jsonb; n integer; ids text[]:='{}'; attacks text[]; powerups text[]:='{}'; image jsonb;
begin
  if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000
    or d->>'format' is distinct from 'dungeon-layout-v6' or jsonb_typeof(d->'rooms') is distinct from 'array'
    or jsonb_array_length(d->'rooms')>3000 or jsonb_typeof(d->'closedDoors') is distinct from 'object' then return false; end if;
  for r in select value from jsonb_array_elements(d->'rooms') loop
    if jsonb_typeof(r) is distinct from 'object' or not dungeon_private.json_int(r->'id',1,9007199254740990)
      or (r->>'id')=any(ids) or r->>'type' not in ('normal','diamond','chest','special','monster','miniboss','boss') or r->>'type' is null
      or not dungeon_private.json_int(r->'x',-2000,2000) or not dungeon_private.json_int(r->'y',-2000,2000)
      or not dungeon_private.json_int(r->'w',1,4000) or not dungeon_private.json_int(r->'h',1,4000)
      or jsonb_typeof(r->'start') is distinct from 'boolean' or jsonb_typeof(r->'dimmed') is distinct from 'boolean'
      or (r->'number' is not null and r->'number'<>'null'::jsonb and not dungeon_private.dice_number(r->'number')) then return false; end if;
    ids:=array_append(ids,r->>'id');
    n:=case when r->>'type' in ('monster','boss') then 8 else 4 end;
    if (r->>'w')::int<n or (r->>'h')::int<n or (r->>'type' in ('normal','special') and ((r->>'w')::int<>4 or (r->>'h')::int<>4)) then return false; end if;
    if r->>'type'='normal' and (r->>'start')::boolean and (r->>'dimmed')::boolean then return false; end if;
    if r->>'type' in ('monster','miniboss','boss') then
      if jsonb_typeof(r->'name') is distinct from 'string' or char_length(r->>'name')>80
        or not dungeon_private.json_int(r->'hits',1,100) or not dungeon_private.json_int(r->'rewardFirst',0,999)
        or not dungeon_private.json_int(r->'rewardLater',0,999) or jsonb_typeof(r->'attacks') is distinct from 'array'
        or jsonb_array_length(r->'attacks')>12 or not dungeon_private.map_image_valid(r->'image') then return false; end if;
      attacks:='{}';
      for a in select value from jsonb_array_elements(r->'attacks') loop
        if not dungeon_private.dice_number(a->'number') or a->>'state' is null or a->>'state' not in ('active','locked') or (a->'number')::text=any(attacks) then return false; end if;
        attacks:=array_append(attacks,(a->'number')::text);
      end loop;
      l:=r->'imageLayout';
      if l is not null and l<>'null'::jsonb then
        if r->'image' is null or r->'image'='null'::jsonb or jsonb_typeof(l) is distinct from 'object' then return false; end if;
        for a in select value from jsonb_each(l) loop if jsonb_typeof(a) is distinct from 'number' then return false; end if; end loop;
        if not (l ?& array['x','y','w','h']) or (l->>'w')::numeric<=0 or (l->>'h')::numeric<=0
          or (l->>'x')::numeric < -4 or (l->>'y')::numeric < -4
          or (l->>'x')::numeric+(l->>'w')::numeric>(r->>'w')::numeric+4
          or (l->>'y')::numeric+(l->>'h')::numeric>(r->>'h')::numeric+4 then return false; end if;
      end if;
    end if;
  end loop;
  if exists(select 1 from jsonb_array_elements(d->'rooms') a, jsonb_array_elements(d->'rooms') b
    where (a->>'id')::bigint<(b->>'id')::bigint and (a->>'x')::int<(b->>'x')::int+(b->>'w')::int
      and (a->>'x')::int+(a->>'w')::int>(b->>'x')::int and (a->>'y')::int<(b->>'y')::int+(b->>'h')::int
      and (a->>'y')::int+(a->>'h')::int>(b->>'y')::int) then return false; end if;
  if exists(select 1 from jsonb_each(d->'closedDoors') where key !~ '^[1-9][0-9]*:[1-9][0-9]*$' or value<>'true'::jsonb) then return false; end if;
  b:=d->'background';
  if b is not null and b<>'null'::jsonb then
    if not dungeon_private.json_int(b->'x',-2000,2000) or not dungeon_private.json_int(b->'y',-2000,2000)
      or not dungeon_private.json_int(b->'w',1,4000) or not dungeon_private.json_int(b->'h',1,4000) or not dungeon_private.map_image_valid(b->'image') or b->'image'='null'::jsonb or b->'image' is null then return false; end if;
  end if;
  l:=d->'printLayout';
  if jsonb_typeof(l) is distinct from 'object' or l->>'format' is null or l->>'format' not in ('auto','portrait','landscape')
    or jsonb_typeof(l->'name') is distinct from 'string' or char_length(l->>'name')>80
    or jsonb_typeof(l->'padding') is distinct from 'number' or (l->>'padding')::numeric not between 8 and 100 then return false; end if;
  for a in select l->key from unnest(array['board','title','rule']) as key loop
    if jsonb_typeof(a) is distinct from 'object' or jsonb_typeof(a->'x') is distinct from 'number' or jsonb_typeof(a->'y') is distinct from 'number'
      or abs((a->>'x')::numeric)>2 or abs((a->>'y')::numeric)>2 or jsonb_typeof(a->'scale') is distinct from 'number'
      or (a->>'scale')::numeric not between .1 and 3 or not dungeon_private.map_image_valid(a->'image') then return false; end if;
  end loop;
  if (l->'board'->>'scale')::numeric>2 then return false; end if;
  if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>4 then return false; end if;
  for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
    if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe') or (a#>>'{}')=any(powerups) then return false; end if;
    powerups:=array_append(powerups,a#>>'{}');
  end loop;
  rules:=d->'rules';goal:=rules->'customGoal';
  if jsonb_typeof(rules) is distinct from 'object' or rules->'version' is distinct from '1'::jsonb
    or jsonb_typeof(rules->'unlocks') is distinct from 'array' or jsonb_array_length(rules->'unlocks')>36000
    or jsonb_typeof(goal) is distinct from 'object' or goal->>'type' is null or goal->>'type' not in ('none','reachFields','defeatEnemies','collectDiamonds')
    or jsonb_typeof(goal->'cellIds') is distinct from 'array' or not dungeon_private.json_int(goal->'diamonds',1,999)
    or rules->'specialReward' is distinct from '{"first":3,"later":1}'::jsonb then return false; end if;
  for a in select value from jsonb_array_elements(goal->'cellIds') loop if not dungeon_private.json_int(a,1,9007199254740990) then return false; end if; end loop;
  for a in select value from jsonb_array_elements(rules->'unlocks') loop
    if not dungeon_private.json_int(a->'sourceCellId',1,9007199254740990) or not dungeon_private.json_int(a->'targetCellId',1,9007199254740990) or not dungeon_private.dice_number(a->'number') then return false; end if;
  end loop;
  return true;
exception when others then return false;
end;
$$;

create or replace function dungeon_private.map_edges(d jsonb)
returns table(cell_a text,cell_b text) language sql stable set search_path='' as $$
  with cells as (select r->>'id' as id,(r->>'id')::bigint as n,(r->>'x')::int x,(r->>'y')::int y,(r->>'w')::int w,(r->>'h')::int h from jsonb_array_elements(d->'rooms') r)
  select least(a.id,b.id),greatest(a.id,b.id) from cells a join cells b on a.n<b.n
  where (((a.x+a.w=b.x or b.x+b.w=a.x) and least(a.y+a.h,b.y+b.h)-greatest(a.y,b.y)>=1)
    or ((a.y+a.h=b.y or b.y+b.h=a.y) and least(a.x+a.w,b.x+b.w)-greatest(a.x,b.x)>=1))
    and coalesce(d->'closedDoors'->(a.id||':'||b.id),'false'::jsonb)<>'true'::jsonb;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; u jsonb; g jsonb; id text; reachable text[]; graph jsonb; starts int; enemies int; count_chests int; specials int;
begin
  if not dungeon_private.map_document_valid(d) then
    return jsonb_build_object('errors',jsonb_build_array(jsonb_build_object('message','Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen.')),'warnings',warnings,'stats','{}'::jsonb);
  end if;
  select count(*) filter(where (value->>'start')::boolean),count(*) filter(where value->>'type' in ('monster','miniboss','boss')),
    count(*) filter(where value->>'type'='chest'),count(*) filter(where value->>'type'='special') into starts,enemies,count_chests,specials from jsonb_array_elements(d->'rooms');
  if jsonb_array_length(d->'rooms')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Karte hat noch keine Felder.')); end if;
  if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
  if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster, Mini-Boss oder Boss ist für das Spielende erforderlich.')); end if;
  if count_chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
  if count_chests<>2 then warnings:=warnings||jsonb_build_array(jsonb_build_object('message',format('%s Schatzkisten vorhanden; die Originallevel haben zwei.',count_chests))); end if;
  for r in select value from jsonb_array_elements(d->'rooms') loop
    id:=r->>'id';
    if r->>'type' not in ('monster','miniboss','boss') then
      if r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Feld #%s hat noch keine Zahl oder Pasch.',id))); end if;
    else
      if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Gegner #%s hat keine Angriffszahl.',id))); end if;
      if btrim(r->>'name')='' then warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Gegner #%s hat noch keinen Namen.',id))); end if;
      if r->'image' is null or r->'image'='null'::jsonb then warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Gegner #%s hat noch kein Bild.',id))); end if;
      if r->>'type'='boss' and (r->>'rewardLater')::int<>0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Boss #%s: Belohnung 2 muss gemäß Bossregel 0 sein.',id))); end if;
      for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
        if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then
          errors:=errors||jsonb_build_array(jsonb_build_object('cellId',id,'message',format('Gesperrter Angriff %s bei Gegner #%s braucht ein freischaltendes X-Feld.',case when a->>'number'='doubles' then 'Pasch' else a->>'number' end,id)));
        end if;
      end loop;
    end if;
  end loop;
  for u in select value from jsonb_array_elements(d->'rules'->'unlocks') loop
    if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=u->'sourceCellId' and r->>'type'='special')
      or not exists(select 1 from jsonb_array_elements(d->'rooms') r,jsonb_array_elements(r->'attacks') a where r->'id'=u->'targetCellId' and r->>'type' in ('monster','miniboss','boss') and a->'number'=u->'number' and a->>'state'='locked') then
      errors:=errors||jsonb_build_array(jsonb_build_object('message','Eine Freischaltung verweist auf ein gelöschtes Feld oder einen nicht mehr grauen Angriff. In „Spielregeln“ entfernen oder korrigieren.'));
    end if;
  end loop;
  g:=d->'rules'->'customGoal';
  if g->>'type'='none' and d->'printLayout'->'rule'->'image' is not null and d->'printLayout'->'rule'->'image'<>'null'::jsonb then
    warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Ein Regelbild ist vorhanden, aber keine zweite Spezialaufgabe fürs Online-Spiel definiert. Bei Bedarf in „Spielregeln“ ergänzen.'));
  end if;
  if g->>'type' in ('reachFields','defeatEnemies') then
    if jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für die Spezialaufgabe mindestens ein Ziel auswählen.')); end if;
    for a in select value from jsonb_array_elements(g->'cellIds') loop
      if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type'<>'defeatEnemies' or r->>'type' in ('monster','miniboss','boss'))) then
        errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Spezialaufgabe: Ziel #%s existiert nicht oder ist kein Gegner.',a::text)));
      end if;
    end loop;
  end if;
  if d->'printLayout'->'title'->'image' is null or d->'printLayout'->'title'->'image'='null'::jsonb then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Noch kein Titelbild im Drucklayout.')); end if;
  if g->>'type'<>'none' and (d->'printLayout'->'rule'->'image' is null or d->'printLayout'->'rule'->'image'='null'::jsonb) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Für die Spezialaufgabe fehlt noch das Regelbild im Drucklayout.')); end if;
  select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b) order by cell_a,cell_b),'[]') into graph from dungeon_private.map_edges(d);
  with recursive reach(id) as (
    select value->>'id' from jsonb_array_elements(d->'rooms') where (value->>'start')::boolean
    union select case when e.cell_a=reach.id then e.cell_b else e.cell_a end from reach join dungeon_private.map_edges(d) e on reach.id in (e.cell_a,e.cell_b)
  ) select coalesce(array_agg(id),'{}') into reachable from reach;
  for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop
    warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist über offene Durchgänge von keinem Startfeld erreichbar.',r->>'id')));
  end loop;
  return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'enemies',enemies,'starts',starts,'specials',specials,'chests',count_chests,'connections',jsonb_array_length(graph)));
end;
$$;

-- Öffentliche Editor-RPCs prüfen eigene Sitzungen. Nur die Edge Function darf
-- Datei-Metadaten nach einem kontrollierten Upload registrieren.
do $$ declare r record; begin
 for r in select p.oid::regprocedure as signature,p.proname as name from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname=any(array['list_maps','get_map','create_map','copy_map','acquire_map_lock','heartbeat_map_lock','release_map_lock','save_map','check_map','publish_map','delete_map','app_authorize_map_asset','app_finish_map_asset']) loop
  execute format('revoke all on function %s from public, anon, authenticated',r.signature);
  if r.name in ('app_authorize_map_asset','app_finish_map_asset') then
    execute format('grant execute on function %s to service_role',r.signature);
  else execute format('grant execute on function %s to anon, authenticated, service_role',r.signature); end if;
 end loop;
end $$;
revoke all on all functions in schema dungeon_private from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(2) on conflict(version) do nothing;
notify pgrst,'reload schema';

-- Eigene Spielersitzungen bleiben erhalten; keine Supabase-Auth-Konten nötig.

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

-- Bestehende Spieler, Kartenversionen und Spielstände bleiben erhalten.

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

-- Additives Update; keine Spieler, Karten oder laufenden Partien werden gelöscht.

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

-- Zusätzlich zu 010_phase5.sql ausführen; bestehende Spielstände bleiben erhalten.

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

-- No existing published document or active game is rewritten.

do $$ begin
 if to_regprocedure('dungeon_private.map_document_valid_v1(jsonb)') is null then
  alter function dungeon_private.map_document_valid(jsonb) rename to map_document_valid_v1;
  alter function dungeon_private.map_report(jsonb) rename to map_report_v1;
 end if;
end $$;
alter table public.dungeon_map_cells drop constraint if exists dungeon_map_cells_kind_check;
alter table public.dungeon_map_cells add constraint dungeon_map_cells_kind_check check(kind in ('normal','diamond','chest','special','monster','miniboss','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin'));

create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>5 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if r->>'type'<>'normal' and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
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
  r:=r||jsonb_build_object('type',case r->>'type' when 'rune' then 'special' when 'bonus' then 'miniboss' when 'trap' then 'normal' when 'portal' then 'normal' when 'crazy' then 'normal' when 'goldSack' then 'diamond' when 'goldCoin' then 'diamond' else r->>'type' end);
  shadow:=jsonb_set(shadow,'{rooms}',shadow->'rooms'||jsonb_build_array(r));
 end loop;
 if not dungeon_private.map_document_valid_v1(shadow) then return false; end if;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if jsonb_typeof(g) is distinct from 'object' or g->>'type' is null or g->>'type' not in ('none','allType','reachFields','defeatEnemies','firstEnemies','connect','collectDiamonds')
   or jsonb_typeof(g->'cellIds') is distinct from 'array' or jsonb_array_length(g->'cellIds')>3000 or not dungeon_private.json_int(g->'diamonds',1,999)
   or not dungeon_private.json_int(g->'reward'->'first',0,999) or not dungeon_private.json_int(g->'reward'->'later',0,999) then return false; end if;
  if g->>'type'='allType' and (g->>'fieldType' is null or g->>'fieldType' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin')) then return false; end if;
  values_seen:='{}';for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not dungeon_private.json_int(a,1,9007199254740990) or a::text=any(values_seen) then return false; end if;values_seen:=array_append(values_seen,a::text);
  end loop;
 end loop;
 return true;
exception when others then return false;
end;
$$;

-- Sources, targets and portal edges are derived from geometry and requirements.
-- Browser-supplied unlock/pair lists never define gameplay connectivity.
create or replace function dungeon_private.map_compile_v2(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare target jsonb; source jsonb; attack jsonb; list jsonb; cells jsonb:='[]'; links jsonb:='[]'; goals jsonb:='[]'; g jsonb; pairs jsonb;
begin
 if d->>'format'<>'dungeon-layout-v7' then return d; end if;
 for target in select value from jsonb_array_elements(d->'rooms') loop
  if target->>'type' in ('monster','boss') then
   list:=target->'attacks';
   for source in select value from jsonb_array_elements(d->'rooms') s where s->'number' is not null and s->'number'<>'null'::jsonb and
    ((s->>'type'='rune' and target->>'type'='boss') or (s->>'type'='normal' and s->'dimmed'='true'::jsonb and target->>'type'='monster' and exists
     (select 1 from dungeon_private.map_edges(d) e where (e.cell_a=s->>'id' and e.cell_b=target->>'id') or (e.cell_b=s->>'id' and e.cell_a=target->>'id')))) loop
    select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a where a->'number'<>source->'number';
    list:=list||jsonb_build_array(jsonb_build_object('number',source->'number','state','locked'));
    links:=links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','number',source->'number'));
   end loop;
   select coalesce(jsonb_agg(a order by case when a->>'number'='doubles' then 13 else (a->>'number')::int end),'[]') into list from jsonb_array_elements(list) a;
   target:=jsonb_set(target,'{attacks}',list);
  end if;
  cells:=cells||jsonb_build_array(target);
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='allType' then g:=jsonb_set(g,'{cellIds}',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(cells) r where r->>'type'=g->>'fieldType')); end if;
  goals:=goals||jsonb_build_array(g);
 end loop;
 select coalesce(jsonb_agg(jsonb_build_array(a->'id',b->'id') order by (a->>'id')::bigint,(b->>'id')::bigint),'[]') into pairs
  from jsonb_array_elements(cells) a,jsonb_array_elements(cells) b where a->>'type'='portal' and b->>'type'='portal' and a->'number'=b->'number' and a->'number'<>'null'::jsonb and (a->>'id')::bigint<(b->>'id')::bigint;
 return d||jsonb_build_object('rooms',cells,'rules',d->'rules'||jsonb_build_object('unlocks',links,'goals',goals,'portalPairs',pairs));
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 if chests<>2 then warnings:=warnings||jsonb_build_array(jsonb_build_object('message',format('%s Schatzkisten vorhanden; die Originallevel haben zwei.',chests))); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if btrim(r->>'name')='' or r->'image' is null or r->'image'='null'::jsonb then warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s: Name oder Bild fehlt noch.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Wegfeld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->>'type'='normal' and r->'dimmed'='true'::jsonb and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is null or bg='null'::jsonb then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Kein Hintergrundbild: Für eine dekorierte Spielansicht Platz für Anzeigen einplanen.'));
 elsif exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

create or replace function public.create_map(p_session_token text,p_name text,p_document jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; d jsonb:=coalesce(p_document,dungeon_private.empty_map_document());
begin
 if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then return jsonb_build_object('ok',false,'error','MAP_NAME_INVALID'); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 d:=dungeon_private.map_compile_v2(d);
 insert into public.dungeon_maps(name,document,allowed_powerups,created_by,updated_by) values(btrim(p_name),d,d->'allowedPowerups',player,player) returning * into m;
 return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true));
exception when unique_violation then return jsonb_build_object('ok',false,'error','MAP_NAME_TAKEN');
end;
$$;

create or replace function public.save_map(p_session_token text,p_map_id uuid,p_editor_id uuid,p_expected_revision bigint,p_name text,p_document jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; request dungeon_private.map_save_requests%rowtype;
  hash text:=md5(jsonb_build_object('name',btrim(p_name),'document',p_document,'expectedRevision',p_expected_revision)::text); result jsonb;
begin
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 if m.status<>'draft' then return jsonb_build_object('ok',false,'error','MAP_READ_ONLY'); end if;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 if p_request_id is null then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 select * into request from dungeon_private.map_save_requests where map_id=p_map_id and request_id=p_request_id;
 if found then
   if request.editor_id<>p_editor_id or request.payload_hash<>hash then return jsonb_build_object('ok',false,'error','MAP_REQUEST_INVALID'); end if;
   return request.response;
 end if;
 if m.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','MAP_CHANGED','revision',m.revision); end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 80 then return jsonb_build_object('ok',false,'error','MAP_NAME_INVALID'); end if;
 if not dungeon_private.map_document_valid(p_document) then return jsonb_build_object('ok',false,'error','MAP_DOCUMENT_INVALID'); end if;
 p_document:=dungeon_private.map_compile_v2(p_document);
 update public.dungeon_maps set name=btrim(p_name),document=p_document,allowed_powerups=p_document->'allowedPowerups',revision=revision+1,updated_by=player,updated_at=now() where id=p_map_id returning * into m;
 result:=jsonb_build_object('ok',true,'map',dungeon_private.map_json(m));
 insert into dungeon_private.map_save_requests(map_id,request_id,editor_id,payload_hash,response) values(p_map_id,p_request_id,p_editor_id,hash,result);
 delete from dungeon_private.map_save_requests where map_id=p_map_id and created_at<now()-interval '7 days';
 return result;
exception when unique_violation then return jsonb_build_object('ok',false,'error','MAP_NAME_TAKEN');
end;
$$;

create or replace function public.publish_map(p_session_token text,p_map_id uuid,p_editor_id uuid,p_expected_revision bigint,p_accept_warnings boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token); m public.dungeon_maps%rowtype; report jsonb; version_id uuid; frozen_rules jsonb;
begin
 select * into m from public.dungeon_maps where id=p_map_id for update;
 if not found then return jsonb_build_object('ok',false,'error','MAP_NOT_FOUND'); end if;
 if m.status='published' then return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true)); end if;
 if m.status<>'draft' then return jsonb_build_object('ok',false,'error','MAP_READ_ONLY'); end if;
 if not dungeon_private.owns_map_lock(p_session_token,p_map_id,p_editor_id) then return jsonb_build_object('ok',false,'error','MAP_LOCK_LOST'); end if;
 if m.revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','MAP_CHANGED'); end if;
 report:=dungeon_private.map_report(m.document);
 if jsonb_array_length(report->'errors')>0 then return jsonb_build_object('ok',false,'error','MAP_INCOMPLETE','report',report); end if;
 if jsonb_array_length(report->'warnings')>0 and not p_accept_warnings then return jsonb_build_object('ok',false,'error','MAP_WARNINGS','report',report); end if;
 m.document:=dungeon_private.map_compile_v2(m.document);
 frozen_rules:=case when m.document->>'format'='dungeon-layout-v7' then report->'rules' else m.document->'rules'||jsonb_build_object('specialCellIds',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(m.document->'rooms') r where r->>'type'='special')) end;
 insert into public.dungeon_map_versions(map_id,name,document,compiled_graph,rules,allowed_powerups,definition_version,content_hash,published_by)
  values(m.id,m.name,m.document,report->'graph',frozen_rules,m.allowed_powerups,case when m.document->>'format'='dungeon-layout-v7' then 2 else 1 end,dungeon_private.token_hash(m.document::text),player) returning id into version_id;
 insert into public.dungeon_map_cells(version_id,cell_id,kind,x,y,w,h,definition)
  select version_id,r->>'id',r->>'type',(r->>'x')::int,(r->>'y')::int,(r->>'w')::int,(r->>'h')::int,r from jsonb_array_elements(m.document->'rooms') r;
 insert into public.dungeon_map_connections(version_id,cell_a,cell_b) select version_id,e->>0,e->>1 from jsonb_array_elements(report->'graph') e;
 update public.dungeon_maps set document=m.document,status='published',published_at=now(),updated_at=now(),updated_by=player,revision=revision+1 where id=m.id returning * into m;
 delete from dungeon_private.map_edit_locks where map_id=m.id;
 return jsonb_build_object('ok',true,'map',dungeon_private.map_json(m,true),'report',report);
end;
$$;

create or replace function dungeon_private.map_json(m public.dungeon_maps,p_full boolean default false)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',m.id,'name',m.name,'status',m.status,'revision',m.revision,
  'createdAt',m.created_at,'updatedAt',m.updated_at,'publishedAt',m.published_at,'allowedPowerups',m.allowed_powerups,
  'creator',(select display_name from public.dungeon_players where id=m.created_by),
  'updatedBy',(select display_name from public.dungeon_players where id=m.updated_by),
  'versionId',(select id from public.dungeon_map_versions where map_id=m.id),
  'previewImage',m.document->'previewImage','definitionVersion',case when m.document->>'format'='dungeon-layout-v7' then 2 else 1 end,
  'fields',jsonb_array_length(m.document->'rooms'),
  'enemies',(select count(*) from jsonb_array_elements(m.document->'rooms') r where r->>'type' in ('monster','miniboss','boss')),
  'bonusFields',(select count(*) from jsonb_array_elements(m.document->'rooms') r where r->>'type'='bonus'),
  'bosses',(select count(*) from jsonb_array_elements(m.document->'rooms') r where r->>'type' in ('boss','miniboss')),
  'preview',(select coalesce(jsonb_agg(jsonb_build_object('id',r->'id','type',r->'type','x',r->'x','y',r->'y','w',r->'w','h',r->'h','start',r->'start')),'[]') from jsonb_array_elements(m.document->'rooms') r),
  'lock',(select jsonb_build_object('holder',p.display_name,'until',l.lease_until) from dungeon_private.map_edit_locks l
    join public.dungeon_players p on p.id=l.player_id join dungeon_private.player_sessions s on s.id=l.session_id
    where l.map_id=m.id and l.lease_until>now() and s.revoked_at is null and s.expires_at>now()))
  || case when p_full then jsonb_build_object('document',m.document) else '{}'::jsonb end;
$$;

create or replace function dungeon_private.game_map_json(v public.dungeon_map_versions)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('previewImage',v.document->'previewImage','id',v.map_id,'versionId',v.id,'name',v.name,
  'fields',jsonb_array_length(v.document->'rooms'),
  'enemies',(select count(*) from jsonb_array_elements(v.document->'rooms') r where r->>'type' in ('monster','miniboss','boss')),
  'preview',(select coalesce(jsonb_agg(jsonb_build_object('id',r->'id','type',r->'type','x',r->'x','y',r->'y','w',r->'w','h',r->'h','start',r->'start')),'[]') from jsonb_array_elements(v.document->'rooms') r));
$$;

create or replace function public.list_game_maps(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.require_player(p_session_token);
 return jsonb_build_object('ok',true,'maps',(select coalesce(jsonb_agg(dungeon_private.game_map_json(v) order by v.name),'[]')
  from public.dungeon_map_versions v join public.dungeon_maps m on m.id=v.map_id where m.status='published' and v.definition_version=1));
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
 if not found or v.definition_version<>1 then return jsonb_build_object('ok',false,'error','GAME_MAP_UNAVAILABLE'); end if;
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
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;

revoke all on function dungeon_private.map_document_valid(jsonb),dungeon_private.map_report(jsonb),dungeon_private.map_document_valid_v1(jsonb),dungeon_private.map_report_v1(jsonb),dungeon_private.map_compile_v2(jsonb) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(7) on conflict do nothing;
notify pgrst,'reload schema';

-- Zusätzlich zu 014_editor_upgrade.sql ausführen. Bestehende Partien bleiben v5.

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

-- Shop-Guthaben ist getrennt von Spielpunkten und persönlichen Spielzuständen.

do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=8) then
  raise exception 'Bitte zuerst 016_game_rules.sql installieren.';
 end if;
end$$;

create table if not exists dungeon_private.marking_catalog (
 style text primary key,
 label text not null,
 price integer not null check(price>=0),
 position integer not null unique
);
insert into dungeon_private.marking_catalog(style,label,price,position) values
 ('cross','Großes X',0,0),('pencil','Bleistift',5,1),('waves','Wellenlinien',10,2),
 ('solid','Ausgemalt',15,3),('stars','Sternensiegel',20,4),
 ('runes','Runenkreis',25,5),('claws','Krallenspuren',30,6)
 on conflict(style) do nothing;
create table if not exists dungeon_private.marking_credits (
 player_id uuid not null references public.dungeon_players(id),
 game_id uuid not null references public.dungeon_games(id),
 amount integer not null check(amount>=0),
 credited_at timestamptz not null default now(),
 primary key(player_id,game_id)
);
create table if not exists dungeon_private.marking_purchases (
 player_id uuid not null references public.dungeon_players(id),
 style text not null references dungeon_private.marking_catalog(style),
 price integer not null check(price>=0),
 source text not null check(source in ('purchase','legacy')),
 purchased_at timestamptz not null default now(),
 primary key(player_id,style)
);
create table if not exists dungeon_private.marking_requests (
 player_id uuid not null references public.dungeon_players(id),
 request_id uuid not null,
 style text not null references dungeon_private.marking_catalog(style),
 charged integer not null check(charged>=0),
 already_owned boolean not null,
 created_at timestamptz not null default now(),
 primary key(player_id,request_id)
);
alter table dungeon_private.marking_catalog enable row level security;
alter table dungeon_private.marking_credits enable row level security;
alter table dungeon_private.marking_purchases enable row level security;
alter table dungeon_private.marking_requests enable row level security;
revoke all on dungeon_private.marking_catalog,dungeon_private.marking_credits,
 dungeon_private.marking_purchases,dungeon_private.marking_requests from public,anon,authenticated;

create or replace function dungeon_private.cosmetics_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',1,'balance',earned-spent,'earned',earned,'spent',spent,
  'unlocked',(select jsonb_agg(c.style order by c.position) from dungeon_private.marking_catalog c
   where c.style='cross' or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)))
 from (select coalesce((select sum(amount) from dungeon_private.marking_credits where player_id=p_player_id),0) earned,
  coalesce((select sum(price) from dungeon_private.marking_purchases where player_id=p_player_id),0) spent) amounts;
$$;

create or replace function dungeon_private.profile_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',p.id,'username',p.username,'displayName',p.display_name,
  'avatarPath',p.avatar_path,'preferences',p.preferences,'revision',p.revision,'createdAt',p.created_at,
  'cosmetics',dungeon_private.cosmetics_json(p.id),
  'stats',jsonb_build_object(
   'gamesPlayed',(select count(*) from public.dungeon_game_results r where r.player_id=p.id),
   'totalPoints',(select coalesce(sum(r.total_points),0) from public.dungeon_game_results r where r.player_id=p.id),
   'averagePoints',(select coalesce(round(avg(r.total_points),1),0) from public.dungeon_game_results r where r.player_id=p.id),
   'wins',(select count(*) from public.dungeon_game_results r where r.player_id=p.id and r.won),
   'monstersDefeated',(select coalesce(sum(r.monsters_defeated),0) from public.dungeon_game_results r where r.player_id=p.id)))
 from public.dungeon_players p where p.id=p_player_id;
$$;

create or replace function dungeon_private.marking_shop_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(p_player_id),
  'items',(select jsonb_agg(jsonb_build_object('style',c.style,'label',c.label,'price',c.price,
   'owned',c.style='cross' or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)) order by c.position)
   from dungeon_private.marking_catalog c));
$$;

create or replace function public.get_marking_shop(p_session_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 return dungeon_private.marking_shop_json(dungeon_private.require_player(p_session_token));
end;
$$;

create or replace function public.buy_marking(p_session_token text,p_style text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;item dungeon_private.marking_catalog%rowtype;
 previous dungeon_private.marking_requests%rowtype;owned boolean;balance bigint;charged integer;
begin
 player:=dungeon_private.require_player(p_session_token);
 if p_request_id is null then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
 -- Alle Käufe dieses Spielers werden serialisiert, auch von zwei Geräten.
 perform 1 from public.dungeon_players where id=player for update;
 select * into previous from dungeon_private.marking_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.style is distinct from p_style then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
  return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',previous.charged,'alreadyOwned',previous.already_owned,'replayed',true);
 end if;
 select * into item from dungeon_private.marking_catalog where style=p_style;
 if not found then return jsonb_build_object('ok',false,'error','SHOP_STYLE_INVALID');end if;
 owned:=p_style='cross' or exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_style);
 charged:=case when owned then 0 else item.price end;
 balance:=(dungeon_private.cosmetics_json(player)->>'balance')::bigint;
 if balance<charged then return jsonb_build_object('ok',false,'error','SHOP_INSUFFICIENT_DIAMONDS','balance',balance,'price',charged);end if;
 if not owned then
  insert into dungeon_private.marking_purchases(player_id,style,price,source) values(player,p_style,charged,'purchase');
  update public.dungeon_players set revision=revision+1,updated_at=now() where id=player;
 end if;
 insert into dungeon_private.marking_requests(player_id,request_id,style,charged,already_owned) values(player,p_request_id,p_style,charged,owned);
 return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',charged,'alreadyOwned',owned,'replayed',false);
end;
$$;

create or replace function public.update_player_preferences(p_session_token text,p_preferences jsonb,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;prefs jsonb;current_revision bigint;
begin
 player:=dungeon_private.require_player(p_session_token);
 if p_preferences is null or jsonb_typeof(p_preferences)<>'object'
  or not exists(select 1 from dungeon_private.marking_catalog where style=p_preferences->>'markStyle')
  or jsonb_typeof(p_preferences->'sound') is distinct from 'boolean'
  or jsonb_typeof(p_preferences->'music') is distinct from 'boolean'
  or jsonb_typeof(p_preferences->'reduceMotion') is distinct from 'boolean' then
  return jsonb_build_object('ok',false,'error','PREFERENCES_INVALID');
 end if;
 select revision into current_revision from public.dungeon_players where id=player for update;
 if current_revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED');end if;
 if p_preferences->>'markStyle'<>'cross' and not exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_preferences->>'markStyle') then
  return jsonb_build_object('ok',false,'error','SHOP_STYLE_LOCKED');
 end if;
 prefs:=jsonb_build_object('markStyle',p_preferences->'markStyle','sound',p_preferences->'sound','music',p_preferences->'music','reduceMotion',p_preferences->'reduceMotion');
 update public.dungeon_players set preferences=prefs,revision=revision+1,updated_at=now() where id=player;
 return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player));
end;
$$;

create or replace function dungeon_private.credit_game_diamonds(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare result record;
begin
 if not exists(select 1 from public.dungeon_games where id=p_game_id and status='finished') then return;end if;
 -- Eindeutige Spiel-/Spieler-Schlüssel verhindern doppelte Gutschriften.
 -- Dieselbe Lock-Reihenfolge vermeidet Konflikte beim Abschluss mehrerer Spiele.
 for result in select player_id,greatest(0,diamonds) amount from public.dungeon_game_results where game_id=p_game_id order by player_id loop
  perform 1 from public.dungeon_players where id=result.player_id for update;
  insert into dungeon_private.marking_credits(player_id,game_id,amount) values(result.player_id,p_game_id,result.amount) on conflict do nothing;
 end loop;
end;
$$;
create or replace function dungeon_private.credit_finished_game()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform dungeon_private.credit_game_diamonds(new.id);return new;
end;
$$;
drop trigger if exists dungeon_marking_game_credit on public.dungeon_games;
create trigger dungeon_marking_game_credit after update of status on public.dungeon_games
 for each row when(new.status='finished' and old.status is distinct from new.status)
 execute function dungeon_private.credit_finished_game();

-- Nur bei der Erstinstallation: bisher gewählte Stile ohne Zahlung behalten.
-- Ein späteres Wiederholen der Migration verschenkt keine zusätzlichen Stile.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=9) then
  insert into dungeon_private.marking_purchases(player_id,style,price,source)
   select id,preferences->>'markStyle',0,'legacy' from public.dungeon_players
   where preferences->>'markStyle' in ('pencil','waves','solid') on conflict do nothing;
 end if;
end$$;
alter table public.dungeon_players alter column preferences set default '{"markStyle":"cross","sound":true,"music":false,"reduceMotion":false}';
do $$declare game_id uuid;begin
 for game_id in select id from public.dungeon_games where status='finished' order by id loop
  perform dungeon_private.credit_game_diamonds(game_id);
 end loop;
end$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
revoke all on all functions in schema dungeon_private from public,anon,authenticated;
revoke all on function public.get_marking_shop(text),public.buy_marking(text,text,uuid) from public;
grant execute on function public.get_marking_shop(text),public.buy_marking(text,text,uuid) to anon,authenticated,service_role;
insert into dungeon_private.schema_migrations(version) values(9) on conflict do nothing;
notify pgrst,'reload schema';

-- Ein einziges Update; wiederholbar, keine bestehenden Spielstände umschreiben.

do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Dies ist nicht die eingerichtete Würfeldungeon-Datenbank. Bitte das Projekt mit Version 0.9.0 öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=9) then
  raise exception 'Dieses Update benötigt den funktionierenden Stand 0.9.0 (018_marking_shop.sql).';
 end if;
end$$;
-- Nur beim ersten Einspielen Preise verdoppeln, bestehende Käufe bewahren.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=10) then
  update dungeon_private.marking_catalog set price=price*2;
 end if;
end$$;
insert into dungeon_private.marking_catalog(style,label,price,position) values
 ('spiral','Spirale',70,7),('weave','Schraffur',80,8),('seal','Abenteurersiegel',90,9)
 on conflict(style) do nothing;


create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>6 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if r->>'type'<>'normal' and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
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
  r:=r||jsonb_build_object('type',case r->>'type' when 'rune' then 'special' when 'bonus' then 'miniboss' when 'trap' then 'normal' when 'portal' then 'normal' when 'crazy' then 'normal' when 'goldSack' then 'diamond' when 'goldCoin' then 'diamond' else r->>'type' end);
  shadow:=jsonb_set(shadow,'{rooms}',shadow->'rooms'||jsonb_build_array(r));
 end loop;
 if not dungeon_private.map_document_valid_v1(shadow) then return false; end if;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if jsonb_typeof(g) is distinct from 'object' or g->>'type' is null or g->>'type' not in ('none','allType','reachFields','defeatEnemies','firstEnemies','connect','collectDiamonds')
   or jsonb_typeof(g->'cellIds') is distinct from 'array' or jsonb_array_length(g->'cellIds')>3000 or not dungeon_private.json_int(g->'diamonds',1,999)
   or not dungeon_private.json_int(g->'reward'->'first',0,999) or not dungeon_private.json_int(g->'reward'->'later',0,999) then return false; end if;
  if g->>'type'='allType' and (g->>'fieldType' is null or g->>'fieldType' not in ('normal','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin')) then return false; end if;
  values_seen:='{}';for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not dungeon_private.json_int(a,1,9007199254740990) or a::text=any(values_seen) then return false; end if;values_seen:=array_append(values_seen,a::text);
  end loop;
 end loop;
 return true;
exception when others then return false;
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Wegfeld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->>'type'='normal' and r->'dimmed'='true'::jsonb and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is not null and bg<>'null'::jsonb and exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

create or replace function dungeon_private.game_available_powerups(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements(dungeon_private.available_powerups(g.map_version_id,s)) value
  where value not in ('"binocular"'::jsonb,'"horn"'::jsonb) or (g.rules_version>=7 and g.settings->'fog'='true'::jsonb);
$$;

create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind='normal' and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where (dungeon_private.has_reached(s,v.cell_id) or not exists(select 1 from public.dungeon_map_cells blocker where blocker.version_id=g.map_version_id and blocker.cell_id=v.cell_id and blocker.kind in ('monster','boss','miniboss')))
  and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
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

create or replace function public.update_player_preferences(p_session_token text,p_preferences jsonb,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;prefs jsonb;current_revision bigint;
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
 select revision into current_revision from public.dungeon_players where id=player for update;
 if current_revision is distinct from p_expected_revision then return jsonb_build_object('ok',false,'error','PROFILE_CHANGED');end if;
 if p_preferences->>'markStyle'<>'cross' and not exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_preferences->>'markStyle') then
  return jsonb_build_object('ok',false,'error','SHOP_STYLE_LOCKED');
 end if;
 prefs:=jsonb_build_object('markStyle',p_preferences->'markStyle','sound',p_preferences->'sound','music',p_preferences->'music','reduceMotion',p_preferences->'reduceMotion');
 -- Optional keys keep old clients and their four-key preferences compatible.
 if p_preferences ? 'diceStyle' then prefs:=prefs||jsonb_build_object('diceStyle',p_preferences->'diceStyle');end if;
 if p_preferences ? 'cupStyle' then prefs:=prefs||jsonb_build_object('cupStyle',p_preferences->'cupStyle');end if;
 if p_preferences ? 'campStyle' then prefs:=prefs||jsonb_build_object('campStyle',p_preferences->'campStyle');end if;
 if p_preferences ? 'diceAnimation' then prefs:=prefs||jsonb_build_object('diceAnimation',p_preferences->'diceAnimation');end if;
 update public.dungeon_players set preferences=prefs,revision=revision+1,updated_at=now() where id=player;
 return jsonb_build_object('ok',true,'profile',dungeon_private.profile_json(player));
end;
$$;


-- Artefakt ist eine bestätigte, einmalige Ressourcenaktion, kein regulärer Zug.
create or replace function public.use_game_horn(p_session_token text,p_game_id uuid,p_state_revision bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid:=dungeon_private.require_player(p_session_token);g public.dungeon_games%rowtype;ps public.dungeon_game_player_states%rowtype;replay jsonb;payload jsonb:=jsonb_build_object('stateRevision',p_state_revision);
begin
 select * into g from public.dungeon_games where id=p_game_id for update;
 if not found then return jsonb_build_object('ok',false,'error','GAME_NOT_FOUND');end if;
 replay:=dungeon_private.game_command_replay(g.id,player,p_request_id,'horn',payload);if replay is not null then return replay;end if;
 if not exists(select 1 from public.dungeon_game_players where game_id=g.id and player_id=player and active and not eliminated) then return jsonb_build_object('ok',false,'error','GAME_NOT_MEMBER');end if;
 if g.status='paused' then return jsonb_build_object('ok',false,'error','GAME_PAUSED');end if;
 if g.status<>'playing' then return jsonb_build_object('ok',false,'error','GAME_CLOSED');end if;
 select * into ps from public.dungeon_game_player_states where game_id=g.id and player_id=player;
 if ps.revision is distinct from p_state_revision then return jsonb_build_object('ok',false,'error','GAME_STATE_CHANGED');end if;
 if g.settings->'fog' is distinct from 'true'::jsonb or coalesce((ps.state->>'hornUses')::int,0)<1 or not coalesce(ps.state->'powerups','[]') ? 'horn' then return jsonb_build_object('ok',false,'error','GAME_POWERUP_UNAVAILABLE');end if;
 update public.dungeon_game_player_states set state=state||jsonb_build_object('hornUses',0,'hornUntil',now()+interval '10 seconds'),revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
 update public.dungeon_games set revision=revision+1 where id=g.id returning * into g;
 return dungeon_private.record_game_command(g.id,player,p_request_id,'horn',payload,g.revision);
end;
$$;

-- Die alten Ereignisse enthalten nicht jeden Zwischenraum / Treffer. Deshalb
-- ab diesem Update ausschließlich bestätigte Zustände als Replay festhalten.
create table if not exists dungeon_private.replay_frames(
 id bigint generated always as identity primary key,
 game_id uuid not null references public.dungeon_games(id) on delete cascade,
 player_id uuid not null references public.dungeon_players(id),
 state_revision bigint not null,
 round_index integer not null,
 state jsonb not null,
 dice jsonb,
 round_requirements jsonb not null default '{}',
 initial_frame boolean not null default false,
 recorded_at timestamptz not null default now(),
 unique(game_id,player_id,state_revision)
);
create index if not exists dungeon_replay_game_player on dungeon_private.replay_frames(game_id,player_id,id);
revoke all on dungeon_private.replay_frames from public,anon,authenticated;
create or replace function dungeon_private.capture_replay_frame()
returns trigger language plpgsql security definer set search_path='' as $$
declare g public.dungeon_games%rowtype;
begin
 if tg_op='UPDATE' then
  if new.state is not distinct from old.state and new.last_completed_round is not distinct from old.last_completed_round then return new;end if;
 end if;
 select * into g from public.dungeon_games where id=new.game_id;
 if g.status in ('playing','paused') then
  insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
  values(new.game_id,new.player_id,new.revision,greatest(1,g.round_index),new.state,g.dice,coalesce(g.round_requirements,'{}'),tg_op='INSERT') on conflict do nothing;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_capture_replay on public.dungeon_game_player_states;
create trigger dungeon_capture_replay after insert or update on public.dungeon_game_player_states for each row execute function dungeon_private.capture_replay_frame();
-- Startet nach der Runden-Vorbereitung, damit auch die ersten Zufallszahlen
-- exakt den gestarteten Zustand wiedergeben.
create or replace function dungeon_private.capture_replay_start()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='lobby' and new.status='playing' then
  insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
   select s.game_id,s.player_id,s.revision,new.round_index,s.state,new.dice,coalesce(new.round_requirements,'{}'),true from public.dungeon_game_player_states s where s.game_id=new.id on conflict do nothing;
 end if;
 return new;
end;
$$;
drop trigger if exists dungeon_capture_replay_start on public.dungeon_games;
create trigger dungeon_capture_replay_start after update of status on public.dungeon_games for each row execute function dungeon_private.capture_replay_start();
-- Schon laufende Spiele erhalten einen ehrlichen Einstiegspunkt, keine
-- erfundene Vorgeschichte. Wiederholtes SQL ergänzt keine Duplikate.
insert into dungeon_private.replay_frames(game_id,player_id,state_revision,round_index,state,dice,round_requirements,initial_frame)
 select s.game_id,s.player_id,s.revision,g.round_index,s.state,g.dice,coalesce(g.round_requirements,'{}'),false
 from public.dungeon_game_player_states s join public.dungeon_games g on g.id=s.game_id where g.status in ('playing','paused') on conflict do nothing;

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
  'definition',(select jsonb_build_object('document',v.document,'rules',v.rules,'allowedPowerups',v.allowed_powerups,'graph',v.compiled_graph) from public.dungeon_map_versions v where v.id=g.map_version_id),
  'players',players);
end;
$$;
revoke all on function public.use_game_horn(text,uuid,bigint,uuid),public.get_game_replay(text,uuid) from public;
grant execute on function public.use_game_horn(text,uuid,bigint,uuid),public.get_game_replay(text,uuid) to anon,authenticated,service_role;


create or replace function dungeon_private.game_result_json(g public.dungeon_games,p_viewer uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select dungeon_private.game_summary(g,p_viewer)||jsonb_build_object('round',g.round_index,'startedAt',g.started_at,'results',(select coalesce(jsonb_agg(jsonb_build_object(
  'playerId',p.id,'displayName',p.display_name,'avatarPath',p.avatar_path,'points',r.total_points,'diamonds',r.diamonds,
  'lifePenalty',r.life_penalty,'monstersDefeated',r.monsters_defeated,'won',r.won,'breakdown',r.breakdown,'eliminated',gp.eliminated,'removed',not gp.active) order by r.total_points desc,gp.seat),'[]')
  from public.dungeon_game_results r join public.dungeon_players p on p.id=r.player_id join public.dungeon_game_players gp on gp.game_id=r.game_id and gp.player_id=r.player_id where r.game_id=g.id));
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'roundTwoVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;

revoke all on all functions in schema dungeon_private from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(10) on conflict do nothing;
notify pgrst,'reload schema';

-- Bestehende Karten, Partien, Guthaben und Käufe bleiben erhalten.

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

-- Wiederholbar; bestehende Karten, Spielstände und Käufe bleiben erhalten.

do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte die eingerichtete Würfeldungeon-Datenbank öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=11) then
  raise exception 'Dieses Update benötigt Version 0.10.1 (022_print_and_cosmetics.sql).';
 end if;
end$$;
alter table public.dungeon_map_cells drop constraint if exists dungeon_map_cells_kind_check;
alter table public.dungeon_map_cells add constraint dungeon_map_cells_kind_check check(kind in
 ('normal','doubleSum','diamond','chest','special','monster','miniboss','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin'));
create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>6 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','doubleSum','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if r->>'type'<>'normal' and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
  if r->>'type'='doubleSum' and r->'number' is not null and r->'number'<>'null'::jsonb and (not dungeon_private.json_int(r->'number',2,12) or (r->>'number')::int%2<>0) then return false; end if;
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
  r:=r||jsonb_build_object('type',case r->>'type' when 'doubleSum' then 'normal' when 'rune' then 'special' when 'bonus' then 'miniboss' when 'trap' then 'normal' when 'portal' then 'normal' when 'crazy' then 'normal' when 'goldSack' then 'diamond' when 'goldCoin' then 'diamond' else r->>'type' end);
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

create or replace function dungeon_private.map_compile_v2(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare target jsonb; source jsonb; attack jsonb; list jsonb; cells jsonb:='[]'; links jsonb:='[]'; goals jsonb:='[]'; g jsonb; pairs jsonb;
begin
 if d->>'format'<>'dungeon-layout-v7' then return d; end if;
 for target in select value from jsonb_array_elements(d->'rooms') loop
  if target->>'type' in ('monster','boss') then
   list:=target->'attacks';
   for source in select value from jsonb_array_elements(d->'rooms') s where s->'number' is not null and s->'number'<>'null'::jsonb and
    ((s->>'type'='rune' and target->>'type'='boss') or (s->>'type'='normal' and s->'dimmed'='true'::jsonb and target->>'type' in ('monster','boss') and exists
     (select 1 from dungeon_private.map_edges(d) e where (e.cell_a=s->>'id' and e.cell_b=target->>'id') or (e.cell_b=s->>'id' and e.cell_a=target->>'id')))) loop
    select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a where a->'number'<>source->'number';
    list:=list||jsonb_build_array(jsonb_build_object('number',source->'number','state','locked'));
    links:=links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','number',source->'number'));
   end loop;
   select coalesce(jsonb_agg(a order by case when a->>'number'='doubles' then 13 else (a->>'number')::int end),'[]') into list from jsonb_array_elements(list) a;
   target:=jsonb_set(target,'{attacks}',list);
  end if;
  cells:=cells||jsonb_build_array(target);
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='allType' then g:=jsonb_set(g,'{cellIds}',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(cells) r where r->>'type'=g->>'fieldType')); end if;
  goals:=goals||jsonb_build_array(g);
 end loop;
 select coalesce(jsonb_agg(jsonb_build_array(a->'id',b->'id') order by (a->>'id')::bigint,(b->>'id')::bigint),'[]') into pairs
  from jsonb_array_elements(cells) a,jsonb_array_elements(cells) b where a->>'type'='portal' and b->>'type'='portal' and a->'number'=b->'number' and a->'number'<>'null'::jsonb and (a->>'id')::bigint<(b->>'id')::bigint;
 return d||jsonb_build_object('rooms',cells,'rules',d->'rules'||jsonb_build_object('unlocks',links,'goals',goals,'portalPairs',pairs));
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Wegfeld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->>'type'='normal' and r->'dimmed'='true'::jsonb and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster oder einen Boss angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  if g->'requiredCount' is not null and g->'requiredCount'<>'null'::jsonb and (g->>'requiredCount')::int>jsonb_array_length(g->'cellIds') then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: %s benötigte Felder, aber nur %s Zielfelder vorhanden.',g->>'requiredCount',jsonb_array_length(g->'cellIds')))); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is not null and bg<>'null'::jsonb and exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

create or replace function dungeon_private.dice_options_exact(d jsonb,p_red boolean)
returns text[] language plpgsql immutable set search_path='' as $$
declare result text[]:='{}';i integer;j integer;a integer;b integer;last_die integer;
begin
 if d is null or jsonb_typeof(d)<>'array' or jsonb_array_length(d)<>4 then return result; end if;
 for i in 0..3 loop if not dungeon_private.json_int(d->i,1,6) then return result; end if; end loop;
 last_die:=case when p_red then 3 else 2 end;
 for i in 0..last_die-1 loop
  for j in i+1..last_die loop
   a:=(d->>i)::int;b:=(d->>j)::int;result:=array_append(result,(a+b)::text);
   if a=b then result:=array_append(result,'doubles');result:=array_append(result,'doubles:'||(a+b)::text); end if;
  end loop;
 end loop;
 return array(select distinct v from unnest(result) v order by v);
end;
$$;

create or replace function dungeon_private.game_dice_options(g public.dungeon_games,p_red boolean)
returns text[] language sql stable set search_path='' as $$
 select case when g.rules_version>=7 and exists(select 1 from public.dungeon_map_cells where version_id=g.map_version_id and kind='doubleSum')
  then dungeon_private.dice_options_exact(g.dice,p_red) else dungeon_private.dice_options(g.dice,p_red) end;
$$;

create or replace function dungeon_private.game_cell_requirements(g public.dungeon_games,c public.dungeon_map_cells,rules jsonb,s jsonb)
returns text[] language sql stable set search_path='' as $$
 select case when c.kind='doubleSum' then array['doubles:'||(c.definition->>'number')]
 when c.kind='crazy' then case when g.round_requirements->>c.cell_id is null then '{}'::text[] else array[g.round_requirements->>c.cell_id] end
 when c.kind='bonus' then array(select a->>'number' from jsonb_array_elements(c.definition->'attacks') a where a->>'state'='active'
   or exists(select 1 from jsonb_array_elements(coalesce(rules->'unlocks','[]')) u where u->>'targetCellId'=c.cell_id and u->'number'=a->'number' and dungeon_private.has_reached(s,u->>'sourceCellId')))
 else dungeon_private.cell_requirements(c,rules,s) end;
$$;

create or replace function dungeon_private.game_actions(g public.dungeon_games,p_player uuid,s jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.dungeon_map_cells%rowtype;rules jsonb;normal text[];red text[];requirements text[];matches text[];red_matches text[];result jsonb:='[]';
begin
 if g.rules_version<7 then return dungeon_private.game_actions_v5(g,p_player,s); end if;
 if g.dice is null then return result; end if;
 normal:=dungeon_private.game_dice_options(g,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
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
 normal:=dungeon_private.game_dice_options(g,g.roller_id=p_player);
 red:=case when g.roller_id<>p_player and coalesce((s->>'redUses')::int,0)>0 then dungeon_private.game_dice_options(g,true) else '{}'::text[] end;
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

create or replace function dungeon_private.task_progress(g public.dungeon_games,s jsonb,p_key text)
returns jsonb language plpgsql stable set search_path='' as $$
declare goal jsonb;ids jsonb;total integer;progress integer;connected boolean:=false;blocked boolean:=false;completed_ids jsonb;
begin
 if g.rules_version<7 then return dungeon_private.task_progress_v5(g,s,p_key); end if;
 goal:=dungeon_private.game_goal(g,p_key);
 if goal is null or goal->>'type'='none' then return jsonb_build_object('enabled',false,'progress',0,'total',0,'completed',false); end if;
 ids:=coalesce(goal->'cellIds','[]');total:=case when goal->>'type' in ('allType','reachFields','defeatEnemies','firstEnemies') then coalesce((goal->>'requiredCount')::int,jsonb_array_length(ids)) else jsonb_array_length(ids) end;
 select coalesce(jsonb_agg(id order by id),'[]') into completed_ids from jsonb_array_elements_text(ids) id where dungeon_private.has_reached(s,id)
  and (goal->>'type'<>'firstEnemies' or coalesce(s->'firstKills','[]') ? id);
 progress:=jsonb_array_length(completed_ids);
 if goal->>'type'='collectDiamonds' then total:=(goal->>'diamonds')::int;progress:=greatest(0,coalesce((s->>'diamonds')::int,0));
 elsif goal->>'type'='firstEnemies' then
  blocked:=(select count(*) from jsonb_array_elements_text(ids) id where coalesce(s->'firstKills','[]') ? id or not exists
   (select 1 from public.dungeon_game_monster_claims cl where cl.game_id=g.id and cl.monster_cell_id=id and cl.claimed_in_round<g.round_index))<total;
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
  'progress',case when goal->>'type' in ('allType','reachFields','defeatEnemies','firstEnemies') then least(progress,total) else progress end,'total',total,'targetCount',jsonb_array_length(ids),'blocked',blocked,'rewardFirst',goal->'reward'->'first','rewardLater',goal->'reward'->'later',
  'completed',not blocked and total>0 and case when goal->>'type'='connect' then connected else progress>=total end);
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
   'options',to_jsonb(dungeon_private.game_dice_options(g,g.roller_id=p_player)),
   'redOptions',to_jsonb(case when g.roller_id<>p_player and coalesce((ps.state->>'redUses')::int,0)>0 then
    array(select n from unnest(dungeon_private.game_dice_options(g,true)) n where not n=any(dungeon_private.game_dice_options(g,false))) else '{}'::text[] end)) else '{}'::jsonb end;
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and registration_code_hash is not null) from dungeon_private.app_config where singleton;
$$;
revoke all on function dungeon_private.dice_options_exact(jsonb,boolean) from public,anon,authenticated;
revoke all on function dungeon_private.game_dice_options(public.dungeon_games,boolean) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(12) on conflict do nothing;

-- Erhält alle Spieler, Karten, Spiele, Guthaben und bisherigen Käufe.
-- Wiederholbar. Die separate Reset-Datei ist NICHT Bestandteil dieses Updates.

do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte die eingerichtete Würfeldungeon-Datenbank öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=12) then
  raise exception 'Dieses Upgrade benötigt die vollständig installierte Version 0.10.2.';
 end if;
end$$;
alter table dungeon_private.app_config add column if not exists registration_code_required boolean not null default false;
-- Nur die erstmalige Installation schaltet die Codepflicht ab. Ein später
-- bewusst reaktivierter Code wird bei erneutem Ausführen nicht ausgeschaltet.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=13) then
  update dungeon_private.app_config set registration_code_required=false,updated_at=now() where singleton;
  update dungeon_private.marking_catalog set position=position+100;
  update dungeon_private.marking_catalog set
   price=case style when 'cross' then 0 when 'pencil' then 5 when 'weave' then 8 when 'waves' then 10 when 'spiral' then 10 when 'solid' then 15 when 'seal' then 18 when 'stars' then 20 when 'runes' then 25 when 'claws' then 30 else price end,
   position=case style when 'cross' then 0 when 'pencil' then 1 when 'weave' then 2 when 'waves' then 3 when 'spiral' then 4 when 'solid' then 5 when 'seal' then 6 when 'stars' then 7 when 'runes' then 8 when 'claws' then 9 else position end;
  update dungeon_private.cosmetic_catalog set price=price/2;
 end if;
end$$;
create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>6 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (a#>>'{}')=any(powers) then return false; end if;
  powers:=array_append(powers,a#>>'{}');
 end loop;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' is null or r->>'type' not in ('normal','doubleSum','diamond','chest','monster','boss','rune','bonus','trap','portal','crazy','goldSack','goldCoin') then return false; end if;
  if not dungeon_private.map_image_valid(r->'image') or not dungeon_private.map_image_valid(r->'defeatedImage') then return false; end if;
  if jsonb_typeof(r->'start') is distinct from 'boolean' or jsonb_typeof(r->'dimmed') is distinct from 'boolean' then return false; end if;
  if r->>'type' in ('monster','boss') and (r->'start'='true'::jsonb or r->'dimmed'='true'::jsonb) then return false; end if;
  if r->>'type'='doubleSum' and r->'number' is not null and r->'number'<>'null'::jsonb and (not dungeon_private.json_int(r->'number',2,12) or (r->>'number')::int%2<>0) then return false; end if;
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

create or replace function dungeon_private.map_compile_v2(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare target jsonb; source jsonb; number_value jsonb; list jsonb; cells jsonb:='[]'; links jsonb:='[]'; goals jsonb:='[]'; g jsonb; pairs jsonb;
begin
 if d->>'format'<>'dungeon-layout-v7' then return d; end if;
 for target in select value from jsonb_array_elements(d->'rooms') loop
  if target->>'type' in ('monster','boss') then
   list:=target->'attacks';
   for source in select value from jsonb_array_elements(d->'rooms') s where s->>'type' not in ('monster','boss') and
    ((s->>'type'='rune' and target->>'type'='boss') or (s->'dimmed'='true'::jsonb and exists
     (select 1 from dungeon_private.map_edges(d) e where (e.cell_a=s->>'id' and e.cell_b=target->>'id') or (e.cell_b=s->>'id' and e.cell_a=target->>'id')))) loop
    for number_value in select distinct value from jsonb_array_elements(case source->>'type'
     when 'crazy' then coalesce(source->'requirements','[]')
     when 'bonus' then (select coalesce(jsonb_agg(a->'number'),'[]') from jsonb_array_elements(source->'attacks') a)
     else jsonb_build_array(source->'number') end) n where value is not null and value<>'null'::jsonb loop
     select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a where a->'number'<>number_value;
     list:=list||jsonb_build_array(jsonb_build_object('number',number_value,'state','locked'));
     links:=links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','number',number_value));
    end loop;
   end loop;
   select coalesce(jsonb_agg(a order by case when a->>'number'='doubles' then 13 else (a->>'number')::int end),'[]') into list from jsonb_array_elements(list) a;
   target:=jsonb_set(target,'{attacks}',list);
  end if;
  cells:=cells||jsonb_build_array(target);
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='allType' then g:=jsonb_set(g,'{cellIds}',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(cells) r where r->>'type'=g->>'fieldType')); end if;
  goals:=goals||jsonb_build_array(g);
 end loop;
 select coalesce(jsonb_agg(jsonb_build_array(a->'id',b->'id') order by (a->>'id')::bigint,(b->>'id')::bigint),'[]') into pairs
  from jsonb_array_elements(cells) a,jsonb_array_elements(cells) b where a->>'type'='portal' and b->>'type'='portal' and a->'number'=b->'number' and a->'number'<>'null'::jsonb and (a->>'id')::bigint<(b->>'id')::bigint;
 return d||jsonb_build_object('rooms',cells,'rules',d->'rules'||jsonb_build_object('unlocks',links,'goals',goals,'portalPairs',pairs));
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Feld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->'dimmed'='true'::jsonb and (not exists(select 1 from dungeon_private.map_edges(d) e join jsonb_array_elements(d->'rooms') target on target->>'id'=case when e.cell_a=r->>'id' then e.cell_b else e.cell_a end where r->>'id' in (e.cell_a,e.cell_b) and target->>'type' in ('monster','boss')) or not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id')) then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster oder einen Boss angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  if g->'requiredCount' is not null and g->'requiredCount'<>'null'::jsonb and (g->>'requiredCount')::int>jsonb_array_length(g->'cellIds') then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: %s benötigte Felder, aber nur %s Zielfelder vorhanden.',g->>'requiredCount',jsonb_array_length(g->'cellIds')))); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is not null and bg<>'null'::jsonb and exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

create or replace function dungeon_private.cell_reachable(p_version uuid,p_cell text,s jsonb)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.dungeon_map_cells c where c.version_id=p_version and c.cell_id=p_cell
  and not dungeon_private.has_reached(s,p_cell) and (
   (c.kind not in ('monster','boss','miniboss') and c.definition->'start'='true'::jsonb)
   or exists(select 1 from public.dungeon_map_connections e where e.version_id=p_version and
    ((e.cell_a=p_cell and dungeon_private.has_reached(s,e.cell_b)) or (e.cell_b=p_cell and dungeon_private.has_reached(s,e.cell_a))))));
$$;

create or replace function dungeon_private.game_visible_cells(g public.dungeon_games,s jsonb)
returns jsonb language sql stable set search_path='' as $$
 with recursive visible(cell_id,depth) as (
  select c.cell_id,0 from public.dungeon_map_cells c where c.version_id=g.map_version_id
   and (dungeon_private.has_reached(s,c.cell_id) or (c.kind not in ('monster','boss','miniboss') and c.definition->'start'='true'::jsonb))
  union
  select case when e.cell_a=v.cell_id then e.cell_b else e.cell_a end,v.depth+1
  from visible v join public.dungeon_map_connections e on e.version_id=g.map_version_id and (e.cell_a=v.cell_id or e.cell_b=v.cell_id)
  where (dungeon_private.has_reached(s,v.cell_id) or not exists(select 1 from public.dungeon_map_cells blocker where blocker.version_id=g.map_version_id and blocker.cell_id=v.cell_id and blocker.kind in ('monster','boss','miniboss')))
  and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
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
  if not config.registration_enabled or (config.registration_code_required and config.registration_code_hash is null) then
    return jsonb_build_object('ok',false,'error','REGISTRATION_CLOSED');
  end if;
  if config.registration_code_required and (p_access_code is null or octet_length(p_access_code) > 72
    or not dungeon_private.password_matches(p_access_code, config.registration_code_hash)) then
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

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'releaseVersion','1.0.0','releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;
insert into dungeon_private.schema_migrations(version) values(13) on conflict do nothing;


do $$begin
 if to_regclass('dungeon_private.schema_migrations') is null then
  raise exception 'Bitte die eingerichtete Würfeldungeon-Datenbank öffnen.';
 end if;
 if not exists(select 1 from dungeon_private.schema_migrations where version=13) then
  raise exception 'Dieses Update benötigt die vollständig installierte Version 1.0.0.';
 end if;
end$$;
update dungeon_private.marking_catalog set price=0 where style in ('cross','pencil','weave');
update dungeon_private.cosmetic_catalog set price=0 where category='campStyle' and value in ('forest','dawn');


create or replace function dungeon_private.cosmetics_json(p_player_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',1,'cosmeticVersion',1,'balance',earned-spent,'earned',earned,'spent',spent,
  'unlocked',(select jsonb_agg(c.style order by c.position) from dungeon_private.marking_catalog c
   where c.price=0 or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)),
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
   'owned',c.price=0 or exists(select 1 from dungeon_private.marking_purchases p where p.player_id=p_player_id and p.style=c.style)) order by c.position)
   from dungeon_private.marking_catalog c),
  'cosmeticItems',(select jsonb_agg(jsonb_build_object('category',c.category,'value',c.value,'label',c.label,'price',c.price,
   'owned',c.price=0 or exists(select 1 from dungeon_private.cosmetic_purchases p where p.player_id=p_player_id and p.category=c.category and p.value=c.value)) order by c.category,c.position)
   from dungeon_private.cosmetic_catalog c));
$$;

create or replace function public.buy_marking(p_session_token text,p_style text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare player uuid;item dungeon_private.marking_catalog%rowtype;
 previous dungeon_private.marking_requests%rowtype;owned boolean;balance bigint;charged integer;
begin
 player:=dungeon_private.require_player(p_session_token);
 if p_request_id is null then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
 -- Alle Käufe dieses Spielers werden serialisiert, auch von zwei Geräten.
 perform 1 from public.dungeon_players where id=player for update;
 select * into previous from dungeon_private.marking_requests where player_id=player and request_id=p_request_id;
 if found then
  if previous.style is distinct from p_style then return jsonb_build_object('ok',false,'error','SHOP_REQUEST_INVALID');end if;
  return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',previous.charged,'alreadyOwned',previous.already_owned,'replayed',true);
 end if;
 select * into item from dungeon_private.marking_catalog where style=p_style;
 if not found then return jsonb_build_object('ok',false,'error','SHOP_STYLE_INVALID');end if;
 owned:=item.price=0 or exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_style);
 charged:=case when owned then 0 else item.price end;
 balance:=(dungeon_private.cosmetics_json(player)->>'balance')::bigint;
 if balance<charged then return jsonb_build_object('ok',false,'error','SHOP_INSUFFICIENT_DIAMONDS','balance',balance,'price',charged);end if;
 if not owned then
  insert into dungeon_private.marking_purchases(player_id,style,price,source) values(player,p_style,charged,'purchase');
  update public.dungeon_players set revision=revision+1,updated_at=now() where id=player;
 end if;
 insert into dungeon_private.marking_requests(player_id,request_id,style,charged,already_owned) values(player,p_request_id,p_style,charged,owned);
 return dungeon_private.marking_shop_json(player)||jsonb_build_object('charged',charged,'alreadyOwned',owned,'replayed',false);
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
 if exists(select 1 from dungeon_private.marking_catalog where style=p_preferences->>'markStyle' and price>0) and not exists(select 1 from dungeon_private.marking_purchases where player_id=player and style=p_preferences->>'markStyle') then
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

create or replace function dungeon_private.map_document_valid(d jsonb)
returns boolean language plpgsql stable set search_path='' as $$
declare shadow jsonb; r jsonb; a jsonb; g jsonb; values_seen text[]; powers text[]:='{}'; enemy jsonb;
begin
 if jsonb_typeof(d) is distinct from 'object' or octet_length(d::text)>2500000 then return false; end if;
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_document_valid_v1(d); end if;
 if d->>'format' is distinct from 'dungeon-layout-v7' or jsonb_typeof(d->'rooms') is distinct from 'array' or jsonb_typeof(d->'rules'->'goals') is distinct from 'array'
  or jsonb_array_length(d->'rules'->'goals')<>2 or d->'rules'->'version' is distinct from '2'::jsonb or not dungeon_private.map_image_valid(d->'previewImage') then return false; end if;
 shadow:=d||jsonb_build_object('format','dungeon-layout-v6','rooms','[]'::jsonb,'rules','{"version":1,"unlocks":[],"customGoal":{"type":"none","cellIds":[],"diamonds":3},"specialReward":{"first":3,"later":1}}'::jsonb,'allowedPowerups','[]'::jsonb);
 if jsonb_typeof(d->'allowedPowerups') is distinct from 'array' or jsonb_array_length(d->'allowedPowerups')>6 then return false; end if;
 for a in select value from jsonb_array_elements(d->'allowedPowerups') loop
  if jsonb_typeof(a) is distinct from 'string' or a#>>'{}' not in ('extraLife','redDice','torch','axe','binocular','horn') or (a#>>'{}')=any(powers) then return false; end if;
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

create or replace function dungeon_private.map_compile_v2(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
declare target jsonb; source jsonb; number_value jsonb; list jsonb; cells jsonb:='[]'; links jsonb:='[]'; goals jsonb:='[]'; g jsonb; pairs jsonb; damage_links jsonb:='[]'; prior_links jsonb:=coalesce(d->'rules'->'unlocks','[]');
begin
 if d->>'format'<>'dungeon-layout-v7' then return d; end if;
 for target in select value from jsonb_array_elements(d->'rooms') loop
  if target->>'type' in ('monster','boss') then
   list:=target->'attacks';
   for source in select value from jsonb_array_elements(d->'rooms') s where s->>'type' not in ('monster','boss') and
    ((s->>'type'='rune' and coalesce(s->>'runeEffect','unlock')='unlock' and target->>'type'='boss') or (s->'dimmed'='true'::jsonb and exists
     (select 1 from dungeon_private.map_edges(d) e where (e.cell_a=s->>'id' and e.cell_b=target->>'id') or (e.cell_b=s->>'id' and e.cell_a=target->>'id')))) loop
    for number_value in select distinct value from jsonb_array_elements(case source->>'type'
     when 'crazy' then coalesce(source->'requirements','[]')
     when 'bonus' then (select coalesce(jsonb_agg(a->'number'),'[]') from jsonb_array_elements(source->'attacks') a)
     else jsonb_build_array(source->'number') end) n where value is not null and value<>'null'::jsonb loop
     select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a where a->'number'<>number_value;
     list:=list||jsonb_build_array(jsonb_build_object('number',number_value,'state','locked'));
     links:=links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','number',number_value));
    end loop;
   end loop;
   -- Remove an automatic lock left behind by a rune switched to hits.
   select coalesce(jsonb_agg(a),'[]') into list from jsonb_array_elements(list) a
    where a->>'state'<>'locked' or not exists(select 1 from jsonb_array_elements(prior_links) u join jsonb_array_elements(d->'rooms') r on r->'id'=u->'sourceCellId'
     where u->'targetCellId'=target->'id' and u->'number'=a->'number' and r->>'type'='rune' and r->>'runeEffect'='hits')
    or exists(select 1 from jsonb_array_elements(links) u where u->'targetCellId'=target->'id' and u->'number'=a->'number');
   select coalesce(jsonb_agg(a order by case when a->>'number'='doubles' then 13 else (a->>'number')::int end),'[]') into list from jsonb_array_elements(list) a;
   target:=jsonb_set(target,'{attacks}',list);
  end if;
  if target->>'type'='boss' then
   for source in select value from jsonb_array_elements(d->'rooms') s where s->>'type'='rune' and s->>'runeEffect'='hits' loop
    damage_links:=damage_links||jsonb_build_array(jsonb_build_object('sourceCellId',source->'id','targetCellId',target->'id','hits',coalesce(source->'runeHits','3')));
   end loop;
  end if;
  cells:=cells||jsonb_build_array(target);
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='allType' then g:=jsonb_set(g,'{cellIds}',(select coalesce(jsonb_agg(r->'id'),'[]') from jsonb_array_elements(cells) r where r->>'type'=g->>'fieldType')); end if;
  goals:=goals||jsonb_build_array(g);
 end loop;
 select coalesce(jsonb_agg(jsonb_build_array(a->'id',b->'id') order by (a->>'id')::bigint,(b->>'id')::bigint),'[]') into pairs
  from jsonb_array_elements(cells) a,jsonb_array_elements(cells) b where a->>'type'='portal' and b->>'type'='portal' and a->'number'=b->'number' and a->'number'<>'null'::jsonb and (a->>'id')::bigint<(b->>'id')::bigint;
 select coalesce(jsonb_agg(u order by (u->>'sourceCellId')::bigint,(u->>'targetCellId')::bigint),'[]') into damage_links from jsonb_array_elements(damage_links) u;
 return d||jsonb_build_object('rooms',cells,'rules',d->'rules'||jsonb_build_object('unlocks',links,'bossHits',damage_links,'goals',goals,'portalPairs',pairs));
end;
$$;

create or replace function dungeon_private.map_report(d jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
#variable_conflict use_column
declare errors jsonb:='[]'; warnings jsonb:='[]'; r jsonb; a jsonb; g jsonb; graph jsonb; reachable text[]; starts int; enemies int; chests int; bg jsonb;
begin
 if d->>'format'='dungeon-layout-v6' then return dungeon_private.map_report_v1(d); end if;
 if not dungeon_private.map_document_valid(d) then return jsonb_build_object('errors','[{"message":"Ungültige Kartendaten: Geometrie, Regeln oder Bildreferenzen prüfen."}]'::jsonb,'warnings',warnings,'stats','{}'::jsonb); end if;
 d:=dungeon_private.map_compile_v2(d);
 select count(*) filter(where value->'start'='true'::jsonb),count(*) filter(where value->>'type' in ('monster','boss')),count(*) filter(where value->>'type'='chest') into starts,enemies,chests from jsonb_array_elements(d->'rooms');
 if starts=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein grünes Startfeld ist erforderlich.')); end if;
 if enemies=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Mindestens ein Monster oder Boss ist für das Spielende erforderlich. Bonusaufgaben zählen nicht dazu.')); end if;
 if chests>0 and jsonb_array_length(d->'allowedPowerups')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Für Schatzkisten mindestens ein Powerup freigeben.')); end if;
 for r in select value from jsonb_array_elements(d->'rooms') loop
  if r->>'type' in ('monster','boss','bonus') then
   if jsonb_array_length(r->'attacks')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Angriffszahl.',r->>'id'))); end if;
   if r->>'type'='boss' and r->'rewardLater'<>'0'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Boss #%s: Belohnung 2 muss 0 sein.',r->>'id'))); end if;
   for a in select value from jsonb_array_elements(r->'attacks') where value->>'state'='locked' loop
    if not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'targetCellId'=r->'id' and u->'number'=a->'number') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Gesperrte Zahl %s bei #%s hat kein passendes graues Feld / Runenfeld.',a->>'number',r->>'id'))); end if;
   end loop;
  elsif r->>'type'='crazy' then
   if jsonb_array_length(r->'requirements')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Verrücktes Feld #%s braucht mindestens eine mögliche Zahl.',r->>'id'))); end if;
  elsif r->'number' is null or r->'number'='null'::jsonb then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s hat keine Zahl oder Pasch.',r->>'id')));
  end if;
  if r->'dimmed'='true'::jsonb and (not exists(select 1 from dungeon_private.map_edges(d) e join jsonb_array_elements(d->'rooms') target on target->>'id'=case when e.cell_a=r->>'id' then e.cell_b else e.cell_a end where r->>'id' in (e.cell_a,e.cell_b) and target->>'type' in ('monster','boss')) or not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id')) then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Graues Feld #%s muss über einen offenen Durchgang an ein Monster oder einen Boss angrenzen.',r->>'id'))); end if;
  if r->>'type'='rune' and coalesce(r->>'runeEffect','unlock')='unlock' and not exists(select 1 from jsonb_array_elements(d->'rules'->'unlocks') u where u->'sourceCellId'=r->'id') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Runenfeld #%s braucht einen Boss mit passender Zahl.',r->>'id'))); end if;
  if r->>'type'='rune' and r->>'runeEffect'='hits' and not exists(select 1 from jsonb_array_elements(d->'rooms') b where b->>'type'='boss') then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Trefferrune #%s braucht mindestens einen Boss.',r->>'id'))); end if;
  if r->>'type'='portal' and (select count(*) from jsonb_array_elements(d->'rooms') p where p->>'type'='portal' and p->'number'=r->'number')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Portal #%s: genau zwei Portale pro Zahl / Pasch sind erforderlich.',r->>'id'))); end if;
 end loop;
 for g in select value from jsonb_array_elements(d->'rules'->'goals') loop
  if g->>'type'='none' then continue; end if;
  if g->>'type'<>'collectDiamonds' and jsonb_array_length(g->'cellIds')=0 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Bonusaufgabe: keine Zielfelder ausgewählt / vorhanden.')); end if;
  if g->>'type'='connect' and jsonb_array_length(g->'cellIds')<>2 then errors:=errors||jsonb_build_array(jsonb_build_object('message','Verbindungsaufgabe: genau zwei Endpunkte auswählen.')); end if;
  if g->'requiredCount' is not null and g->'requiredCount'<>'null'::jsonb and (g->>'requiredCount')::int>jsonb_array_length(g->'cellIds') then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: %s benötigte Felder, aber nur %s Zielfelder vorhanden.',g->>'requiredCount',jsonb_array_length(g->'cellIds')))); end if;
  for a in select value from jsonb_array_elements(g->'cellIds') loop
   if not exists(select 1 from jsonb_array_elements(d->'rooms') r where r->'id'=a and (g->>'type' not in ('defeatEnemies','firstEnemies') or r->>'type' in ('monster','boss'))) then errors:=errors||jsonb_build_array(jsonb_build_object('message',format('Bonusaufgabe: ungültiges Zielfeld #%s.',a::text))); end if;
  end loop;
 end loop;
 -- Physical passages and portal links share a frozen navigation graph.
 select coalesce(jsonb_agg(jsonb_build_array(cell_a,cell_b)),'[]') into graph from (select * from dungeon_private.map_edges(d) union select least(p->>0,p->>1),greatest(p->>0,p->>1) from jsonb_array_elements(d->'rules'->'portalPairs') p) e;
 with recursive reach(id) as (select value->>'id' from jsonb_array_elements(d->'rooms') where value->'start'='true'::jsonb union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
 for r in select value from jsonb_array_elements(d->'rooms') where not (value->>'id')=any(reachable) loop warnings:=warnings||jsonb_build_array(jsonb_build_object('cellId',r->>'id','message',format('Feld #%s ist von keinem Startfeld erreichbar.',r->>'id'))); end loop;
 -- Check that both marked endpoints can be connected at all, including portals.
 for g in select value from jsonb_array_elements(d->'rules'->'goals') where value->>'type'='connect' and jsonb_array_length(value->'cellIds')=2 loop
  with recursive reach(id) as (select g->'cellIds'->>0 union select case when e->>0=reach.id then e->>1 else e->>0 end from reach join jsonb_array_elements(graph) e on reach.id in(e->>0,e->>1)) select coalesce(array_agg(id),'{}') into reachable from reach;
  if not (g->'cellIds'->>1)=any(reachable) then errors:=errors||jsonb_build_array(jsonb_build_object('message','Die Endpunkte der Verbindungsaufgabe haben keinen durchgängigen Weg, auch nicht über Portale.')); end if;
 end loop;
 bg:=d->'background';
 if bg is not null and bg<>'null'::jsonb and exists(select 1 from jsonb_array_elements(d->'rooms') r where (bg->>'x')::int>(r->>'x')::int-4 or (bg->>'y')::int>(r->>'y')::int-4 or (bg->>'x')::int+(bg->>'w')::int<(r->>'x')::int+(r->>'w')::int+4 or (bg->>'y')::int+(bg->>'h')::int<(r->>'y')::int+(r->>'h')::int+4) then warnings:=warnings||jsonb_build_array(jsonb_build_object('message','Hintergrund zu klein: rund um alle Felder mindestens 4 Rastereinheiten für Anzeigen und überstehende Bilder vorsehen.')); end if;
 return jsonb_build_object('errors',errors,'warnings',warnings,'graph',graph,'rules',d->'rules','stats',jsonb_build_object('fields',jsonb_array_length(d->'rooms'),'starts',starts,'enemies',enemies,'chests',chests,'connections',jsonb_array_length(graph)));
end;
$$;

-- Gemeinsame Trefferlogik: reguläre Angriffe und Runen verwenden dieselben
-- Trefferobergrenzen, Gleichrunden-Belohnungen und Abschlussereignisse.
create or replace function dungeon_private.damage_game_enemy(g public.dungeon_games,p_player uuid,s jsonb,c public.dungeon_map_cells,p_hits integer,p_source_cell_id text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare previous_hits integer;hits integer;claim_round integer;reward integer;
begin
 if not dungeon_private.game_enemy(c) or dungeon_private.has_reached(s,c.cell_id) or p_hits<1 then return s; end if;
 previous_hits:=coalesce((s->'monsterHits'->>c.cell_id)::int,0);
 hits:=least((c.definition->>'hits')::int,previous_hits+p_hits);
 s:=s||jsonb_build_object('monsterHits',coalesce(s->'monsterHits','{}')||jsonb_build_object(c.cell_id,hits));
 if p_source_cell_id is not null and hits>previous_hits then
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision+1,'rune_triggered',jsonb_build_object('playerId',p_player,'sourceCellId',p_source_cell_id,'cellId',c.cell_id,'round',g.round_index,'hits',hits-previous_hits));
 end if;
 if hits=(c.definition->>'hits')::int then
  insert into public.dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values(g.id,g.map_version_id,c.cell_id,p_player,g.round_index) on conflict do nothing;
  select claimed_in_round into claim_round from public.dungeon_game_monster_claims where game_id=g.id and monster_cell_id=c.cell_id;
  reward:=(c.definition->>case when claim_round=g.round_index then 'rewardFirst' else 'rewardLater' end)::int;
  s:=dungeon_private.preview_reach(g,s,c.cell_id)||jsonb_build_object('diamonds',coalesce((s->>'diamonds')::int,0)+reward,
   'enemyCompletionRounds',coalesce(s->'enemyCompletionRounds','{}')||jsonb_build_object(c.cell_id,g.round_index));
  if claim_round=g.round_index then s:=s||jsonb_build_object('firstKills',coalesce(s->'firstKills','[]')||jsonb_build_array(c.cell_id)); end if;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision+1,case when c.kind='bonus' then 'bonus_completed' else 'enemy_defeated' end,jsonb_build_object('playerId',p_player,'cellId',c.cell_id,'round',g.round_index,'name',coalesce(nullif(c.definition->>'name',''),'Gegner #'||c.cell_id))||case when p_source_cell_id is not null then jsonb_build_object('cause','rune','sourceCellId',p_source_cell_id) else '{}'::jsonb end);
 end if;
 return s;
end;
$$;

create or replace function dungeon_private.reach_game_cell(g public.dungeon_games,p_player uuid,s jsonb,c public.dungeon_map_cells)
returns jsonb language plpgsql security definer set search_path='' as $$
declare arm_round integer;cost integer;effect_rules jsonb;effect jsonb;boss public.dungeon_map_cells%rowtype;
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
 elsif c.kind='rune' and g.rules_version>=7 then
  select rules into effect_rules from public.dungeon_map_versions where id=g.map_version_id;
  for effect in select value from jsonb_array_elements(coalesce(effect_rules->'bossHits','[]')) u where u->>'sourceCellId'=c.cell_id loop
   select * into boss from public.dungeon_map_cells where version_id=g.map_version_id and cell_id=effect->>'targetCellId' and kind='boss';
   if found then s:=dungeon_private.damage_game_enemy(g,p_player,s,boss,(effect->>'hits')::int,c.cell_id); end if;
  end loop;
 end if;return s;
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
   s:=dungeon_private.damage_game_enemy(g,player,s,c,case when p_use_axe then 2 else 1 end);
  else s:=dungeon_private.reach_game_cell(g,player,s,c);end if;
  reward:=coalesce((s->>'diamonds')::int,0)-coalesce((ps.state->>'diamonds')::int,0);
  s:=dungeon_private.award_game_tasks(g,player,s);
  if jsonb_array_length(dungeon_private.game_available_powerups(g,s))=0 then s:=s||jsonb_build_object('pendingChests','[]'::jsonb); end if;
  update public.dungeon_game_players set eliminated=coalesce((s->>'lostLives')::int,0)>=11+coalesce((s->>'extraLives')::int,0) where game_id=g.id and player_id=player;
  update public.dungeon_game_player_states set state=s,last_completed_round=g.round_index,revision=revision+1,updated_at=now() where game_id=g.id and player_id=player;
  update public.dungeon_games set revision=revision+1,final_round=case when not exists(select 1 from public.dungeon_map_cells e where e.version_id=g.map_version_id and e.kind in ('monster','miniboss','boss') and not dungeon_private.has_reached(s,e.cell_id)) then g.round_index else final_round end where id=g.id returning * into g;
  insert into public.dungeon_game_events(game_id,game_revision,kind,payload) values(g.id,g.revision,'turn_played',jsonb_build_object('playerId',player,'cellId',c.cell_id,'middleCellId',p_middle_cell_id,'axeUsed',p_use_axe,'round',g.round_index,'redUsed',chosen->'redOnly','reward',reward));
 end if;
 perform dungeon_private.settle_game_round(g.id);
 return dungeon_private.record_game_command(g.id,player,p_request_id,'turn',payload,(select revision from public.dungeon_games where id=g.id));
end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'releaseVersion','1.0.1','runeHitsVersion',1,'starterCosmeticsVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;

revoke all on function dungeon_private.damage_game_enemy(public.dungeon_games,uuid,jsonb,public.dungeon_map_cells,integer,text) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(14) on conflict do nothing;

-- Preisänderung nur einmal anwenden; frühere Käufe behalten ihren Preis.
do $$begin
 if not exists(select 1 from dungeon_private.schema_migrations where version=15) then
  update dungeon_private.marking_catalog set price=round(price*1.5)::integer where price>0;
  update dungeon_private.cosmetic_catalog set price=round(price*1.5)::integer where price>0;
 end if;
end$$;

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
   and v.depth<case when coalesce(s->'powerups','[]') ? 'binocular' then 3 else 2 end
 ) select case when g.settings->'fog'='true'::jsonb and g.status<>'finished' then
  (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from (select distinct cell_id from visible) x)
  else (select coalesce(jsonb_agg(cell_id order by cell_id),'[]') from public.dungeon_map_cells where version_id=g.map_version_id) end;
$$;

create or replace function public.app_status()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('ok',true,'schemaVersion',1,'editorSchemaVersion',2,'gameSchemaVersion',3,'playSchemaVersion',4,'rulesSchemaVersion',5,'stabilitySchemaVersion',1,'editorFeaturesVersion',1,'gameFeaturesVersion',1,'shopSchemaVersion',1,'cosmeticShopVersion',1,'lobbyPowerupsVersion',1,'roundTwoVersion',1,'originalMapRulesVersion',1,'releaseVersion','1.0.2','runeHitsVersion',1,'starterCosmeticsVersion',1,'portalFogVersion',1,'releaseSchemaVersion',1,
  'realtimeAvailable',to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null,
  'registrationOpen',registration_enabled and (not registration_code_required or registration_code_hash is not null),
  'registrationCodeRequired',registration_code_required) from dungeon_private.app_config where singleton;
$$;

revoke all on function dungeon_private.game_visible_cells(public.dungeon_games,jsonb) from public,anon,authenticated;
insert into dungeon_private.schema_migrations(version) values(15) on conflict do nothing;

commit;


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
