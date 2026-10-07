-- Würfeldungeon 0.10.2 · nach dem funktionierenden Update 0.10.1 ausführen.
-- Wiederholbar; bestehende Karten, Spielstände und Käufe bleiben erhalten.
begin;
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
commit;
