import test from 'node:test';import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {randomUUID} from 'node:crypto';
import {createShopDatabase} from './helpers/shop.mjs';import {modernFixture} from './helpers/game-upgrade.mjs';import {register,userRpc,publishFixture,gameFixture} from './helpers/games.mjs';import {installTestDice,forceDice} from './helpers/turns.mjs';
import {callRpc} from './helpers/database.mjs';
const migration=()=>readFile(new URL('../supabase/migrations/022_print_and_cosmetics.sql',import.meta.url),'utf8');
test('0.10.1: Kosmetikshop und individuelle Powerups pro Partie',{timeout:120000},async t=>{
 const db=await createShopDatabase();try{
 await db.exec(await readFile(new URL('../supabase/migrations/020_round_two.sql',import.meta.url),'utf8'));
 const a=await register(db,'PolishFlo'),b=await register(db,'PolishJoni'),rpc=(u,n,p={})=>userRpc(db,u,n,p);
 const before=(await rpc(a,'get_player_profile')).profile;
 await rpc(a,'update_player_preferences',{p_preferences:{...before.preferences,cupStyle:'runic',campStyle:'moon'},p_expected_revision:before.revision});
 await db.exec(await migration());
 const d=modernFixture();d.allowedPowerups=['extraLife','redDice','torch'];const map=await publishFixture(db,a,'Neue saubere Mine',d);
 const create=async(u,powers)=>{const r=await rpc(u,'create_game',{p_map_version_id:map.versionId,p_name:'Powerup Test',p_settings:{maxPlayers:8,cards:'open',hints:true,fog:true,...(powers===undefined?{}:{allowedPowerups:powers})},p_password:'',p_request_id:randomUUID()});assert.equal(r.ok,true);return r.gameId;};
 const gId=await create(a,['horn','torch']),get=async()=>(await rpc(a,'get_game',{p_game_id:gId,p_include_definition:true})).game;
 await t.test('Neue Kategorien, kostenlose Grundausstattung, vorhandene aktive Varianten bleiben',async()=>{
  const shop=await rpc(a,'get_marking_shop');assert.equal(shop.cosmeticItems.length,11);assert.equal(shop.items.length,10);
  assert.deepEqual(shop.profile.cosmetics.cosmeticUnlocked.cupStyle,['leather','runic']);assert.deepEqual(shop.profile.cosmetics.cosmeticUnlocked.campStyle,['forest','moon']);assert.equal(shop.profile.cosmetics.spent,0);
  const fresh=(await rpc(b,'get_marking_shop')).profile;assert.deepEqual(fresh.cosmetics.cosmeticUnlocked.diceStyle,['ivory']);
  assert.equal((await rpc(b,'update_player_preferences',{p_preferences:{...fresh.preferences,campStyle:'moon'},p_expected_revision:fresh.revision})).error,'SHOP_STYLE_LOCKED');
 });
 await t.test('Kauf, Retry, Markierungskauf und Kosmetik nutzen dasselbe Guthaben',async()=>{
  await db.query('insert into dungeon_private.marking_credits(player_id,game_id,amount) values($1,$2,100)',[b.profile.id,gId]);
  const args={p_category:'diceStyle',p_value:'forest',p_request_id:randomUUID()},one=await rpc(b,'buy_cosmetic',args),two=await rpc(b,'buy_cosmetic',args);
  assert.equal(one.charged,30);assert.equal(two.replayed,true);assert.equal(two.profile.cosmetics.balance,70);
  assert.equal((await rpc(b,'buy_cosmetic',{...args,p_value:'amber'})).error,'SHOP_REQUEST_INVALID');
  const mark=await rpc(b,'buy_marking',{p_style:'pencil',p_request_id:randomUUID()});assert.equal(mark.profile.cosmetics.balance,60);assert.equal(mark.profile.cosmetics.spent,40);
  assert.equal((await rpc(b,'buy_cosmetic',{p_category:'cupStyle',p_value:'runic',p_request_id:randomUUID()})).profile.cosmetics.balance,0);
  assert.equal((await rpc(b,'buy_cosmetic',{p_category:'campStyle',p_value:'moon',p_request_id:randomUUID()})).error,'SHOP_INSUFFICIENT_DIAMONDS');
  const p=(await rpc(b,'get_player_profile')).profile;assert.equal((await rpc(b,'update_player_preferences',{p_preferences:{...p.preferences,diceStyle:'forest',cupStyle:'runic',diceAnimation:'short'},p_expected_revision:p.revision})).ok,true);
 });
 await t.test('Kosmetik und Animation bleiben bei alten vierteiligen Einstellungsanfragen erhalten',async()=>{
  const p=(await rpc(b,'get_player_profile')).profile;const r=await rpc(b,'update_player_preferences',{p_preferences:{markStyle:'cross',sound:false,music:true,reduceMotion:false},p_expected_revision:p.revision});
  assert.equal(r.profile.preferences.diceStyle,'forest');assert.equal(r.profile.preferences.diceAnimation,'short');
 });
 await t.test('Neue Partie erhält eigene Powerups; veröffentlichte Karte bleibt unverändert',async()=>{
  const g=await get();assert.deepEqual(g.powerupPool,['horn','torch']);assert.deepEqual(g.definition.allowedPowerups,['horn','torch']);
  const maps=await rpc(a,'list_game_maps');assert.deepEqual(maps.maps.find(m=>m.versionId===map.versionId).allowedPowerups,d.allowedPowerups);
  const legacy=await create(a);assert.deepEqual((await rpc(a,'get_game',{p_game_id:legacy})).game.powerupPool,d.allowedPowerups);
 });
 await t.test('Host kann Powerups im Warteraum ändern, keine Fremdzugriffe oder veralteten Schreibvorgänge',async()=>{
  let g=await get();assert.equal((await rpc(b,'update_lobby_powerups',{p_game_id:gId,p_powerups:[],p_expected_revision:g.revision,p_request_id:randomUUID()})).error,'GAME_HOST_ONLY');
  assert.equal((await rpc(a,'update_lobby_powerups',{p_game_id:gId,p_powerups:[],p_expected_revision:g.revision-1,p_request_id:randomUUID()})).error,'GAME_CHANGED');
  const args={p_game_id:gId,p_powerups:['horn','axe'],p_expected_revision:g.revision,p_request_id:randomUUID()},one=await rpc(a,'update_lobby_powerups',args),two=await rpc(a,'update_lobby_powerups',args);
  assert.equal(one.ok,true);assert.deepEqual(two,one);g=await get();assert.deepEqual(g.powerupPool,['horn','axe']);
  assert.equal((await rpc(a,'start_game',{p_game_id:gId,p_expected_revision:g.revision,p_request_id:randomUUID()})).ok,true);
  g=await get();assert.equal((await rpc(a,'update_lobby_powerups',{p_game_id:gId,p_powerups:[],p_expected_revision:g.revision,p_request_id:randomUUID()})).error,'GAME_ALREADY_STARTED');
 });
 await t.test('Truhen verwenden Partieauswahl statt Kartenliste; ausgeschlossene Typen sind serverseitig gesperrt',async()=>{
  await db.query("update dungeon_game_player_states set state=state||'{\"pendingChests\":[\"13\"]}'::jsonb,revision=revision+1 where game_id=$1 and player_id=$2",[gId,a.profile.id]);
  let g=await get();assert.deepEqual(g.turn.availablePowerups,['horn','axe']);
  assert.equal((await rpc(a,'choose_game_powerup',{p_game_id:gId,p_chest_cell_id:'13',p_state_revision:g.turn.ownRevision,p_powerup:'extraLife',p_request_id:randomUUID()})).error,'GAME_POWERUP_UNAVAILABLE');
  assert.equal((await rpc(a,'choose_game_powerup',{p_game_id:gId,p_chest_cell_id:'13',p_state_revision:g.turn.ownRevision,p_powerup:'horn',p_request_id:randomUUID()})).ok,true);
  g=await get();assert.equal(g.ownState.hornUses,1);assert.ok(g.ownState.powerups.includes('horn'));
  await db.query('select dungeon_private.finalize_game($1)',[gId]);assert.deepEqual((await rpc(a,'get_game_replay',{p_game_id:gId})).definition.allowedPowerups,['horn','axe']);
 });
 await t.test('Ungültige Powerupdaten und Dopplungen werden abgewiesen; keine Powerups ist erlaubt',async()=>{
  for(const powers of [null,{},['torch','torch'],['unknown'],[3]])assert.equal((await db.query('select dungeon_private.game_settings_valid($1) ok',[JSON.stringify({maxPlayers:8,cards:'open',hints:true,allowedPowerups:powers})])).rows[0].ok,false);
  const empty=await create(a,[]);assert.deepEqual((await rpc(a,'get_game',{p_game_id:empty})).game.powerupPool,[]);
 });
 await t.test('Wiederholte Installation ändert weder Konten noch Käufe oder Partien',async()=>{
  const p=(await rpc(b,'get_player_profile')).profile,g=await get();await db.exec(await migration());
  assert.deepEqual((await rpc(b,'get_player_profile')).profile,p);assert.deepEqual((await get()).settings,g.settings);
  const status=await callRpc(db,'app_status');assert.equal(status.cosmeticShopVersion,1);assert.equal(status.lobbyPowerupsVersion,1);
 });
 await t.test('Neue private Tabellen sind gesperrt; Aufrufe benötigen Sitzung',async()=>{
  for(const table of ['cosmetic_catalog','cosmetic_purchases','cosmetic_requests'])assert.equal((await db.query(`select has_table_privilege('anon','dungeon_private.${table}','select') ok`)).rows[0].ok,false);
  await assert.rejects(()=>callRpc(db,'buy_cosmetic',{p_session_token:'x'.repeat(64),p_category:'diceStyle',p_value:'forest',p_request_id:randomUUID()}),/SESSION_INVALID/);
 });
 await t.test('Gleichzeitiger Kosmetik- und Markierungskauf kann das gemeinsame Guthaben nicht überziehen',async()=>{
  const credit=await create(a,[]);await db.query('insert into dungeon_private.marking_credits(player_id,game_id,amount) values($1,$2,40)',[a.profile.id,credit]);
  const calls=await Promise.all([
   db.query('select public.buy_cosmetic($1,$2,$3,$4) result',[a.session.token,'diceStyle','forest',randomUUID()]),
   db.query('select public.buy_marking($1,$2,$3) result',[a.session.token,'waves',randomUUID()]),
  ]),results=calls.map(r=>r.rows[0].result);
  assert.equal(results.filter(r=>r.ok).length,1);assert.equal(results.find(r=>!r.ok).error,'SHOP_INSUFFICIENT_DIAMONDS');assert.ok((await rpc(a,'get_player_profile')).profile.cosmetics.balance>=0);
 });
 await t.test('Auch ältere Warteräume ohne Powerups bleiben nach dem Öffnen einer Truhe spielbar',async()=>{
  const old=gameFixture();old.rooms.push({id:7,type:'chest',x:-4,y:0,w:4,h:8,number:5,start:false,dimmed:false});old.nextId=8;
  const older=await publishFixture(db,a,'Ältere Druckmine',old);
  const created=await rpc(a,'create_game',{p_map_version_id:older.versionId,p_name:'Älterer Warteraum',p_settings:{maxPlayers:8,cards:'open',hints:true},p_password:'',p_request_id:randomUUID()});const id=created.gameId;
  await db.query('update dungeon_games set rules_version=5 where id=$1',[id]);let g=(await rpc(a,'get_game',{p_game_id:id})).game;
  assert.equal((await rpc(a,'update_lobby_powerups',{p_game_id:id,p_powerups:[],p_expected_revision:g.revision,p_request_id:randomUUID()})).ok,true);g=(await rpc(a,'get_game',{p_game_id:id})).game;
  await rpc(a,'start_game',{p_game_id:id,p_expected_revision:g.revision,p_request_id:randomUUID()});await db.query("update dungeon_game_player_states set state=state||'{\"reached\":[\"1\"]}'::jsonb where game_id=$1",[id]);
  await installTestDice(db);await forceDice(db,[2,3,1,1]);g=(await rpc(a,'get_game',{p_game_id:id})).game;await rpc(a,'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});g=(await rpc(a,'get_game',{p_game_id:id})).game;
  const played=await rpc(a,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'7',p_use_red:false,p_middle_cell_id:null,p_use_axe:false,p_request_id:randomUUID()});assert.equal(played.ok,true);
  g=(await rpc(a,'get_game',{p_game_id:id})).game;assert.deepEqual(g.ownState.pendingChests,[]);assert.equal(g.turn.pendingPowerup,false);
 });
 await t.test('Die zusätzliche Installationskontrolle meldet sechsmal OK',async()=>{
  const rows=(await db.exec(await readFile(new URL('../supabase/migrations/023_check_print_and_cosmetics.sql',import.meta.url),'utf8')))[0].rows;
  assert.equal(rows.length,6);assert.ok(rows.every(r=>r.ergebnis==='OK'));
 });
 }finally{await db.close();}
});
