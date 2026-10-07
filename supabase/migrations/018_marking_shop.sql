-- Würfeldungeon 0.9.0. Nach 016_game_rules.sql ausführen.
-- Shop-Guthaben ist getrennt von Spielpunkten und persönlichen Spielzuständen.
begin;
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
commit;
