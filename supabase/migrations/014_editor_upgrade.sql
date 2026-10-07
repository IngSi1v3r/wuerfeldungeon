-- Editor 0.6.0: new immutable map format. Apply after 012_stability.sql.
-- No existing published document or active game is rewritten.
begin;
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
commit;
