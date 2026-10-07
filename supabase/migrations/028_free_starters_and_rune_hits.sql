-- Würfeldungeon 1.0.1 · Upgrade von 1.0.0, erhält sämtliche Daten.
-- Drei kostenlose Markierungen, zwei Hintergründe und Bosstreffer durch Runen.
-- Wiederholbar; verändert keine veröffentlichten Karten oder Kaufhistorie.
begin;
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
commit;
