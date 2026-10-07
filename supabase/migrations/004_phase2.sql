-- PHASE 2: zusätzlich auf die bereits eingerichtete Phase 1 anwenden.
-- Spieler, Sitzungsschlüssel und privater Registrierungscode bleiben erhalten.
begin;

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
commit;
