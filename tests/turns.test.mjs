import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {createPlayDatabase,installTestDice,forceDice,newPlayGame,seedState,playFixture} from './helpers/turns.mjs';
import {diceCombinations,sortRequirements} from '../web/js/games/rules.js';

test('Phase 4 auf PostgreSQL: Würfel, Züge, Erstbelohnungen, Privatsphäre und Runden',{timeout:120000},async t=>{
 const db=await createPlayDatabase();let flo,joni,mira,map;
 const rpc=(user,n,p)=>userRpc(db,user,n,p),get=async(id,u=flo)=>(await rpc(u,'get_game',{p_game_id:id})).game;
 const create=(users=[flo,joni],settings={})=>newPlayGame(db,users,settings,map);
 async function roll(id,dice,user=null){await forceDice(db,dice);const g=await get(id);user||=[flo,joni,mira].find(u=>u.profile.id===g.rollerId);return rpc(user,'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});}
 async function move(id,user,cell,extra={}){const g=await get(id,user);return rpc(user,'play_game_turn',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:cell===null?'lose_life':'cell',p_cell_id:cell===null?null:String(cell),p_use_red:false,p_request_id:randomUUID(),...extra});}
 try{
  await t.test('Migration ergänzt die bestehende Datenbank und bleibt wiederholbar',async()=>{
   flo=await register(db,'Flo');joni=await register(db,'Joni');mira=await register(db,'Mira');map=await publishFixture(db,flo,'Regelkern-Test',playFixture());
   await db.exec(await readFile(new URL('../supabase/migrations/008_phase4.sql',import.meta.url),'utf8'));
   const s=await callRpc(db,'app_status');assert.equal(s.schemaVersion,1);assert.equal(s.editorSchemaVersion,2);assert.equal(s.gameSchemaVersion,3);assert.equal(s.playSchemaVersion,4);
   assert.equal((await rpc(flo,'get_player_profile',{})).profile.id,flo.profile.id);
  });
  await t.test('Alle 1296 Würfe liefern im Browser und Server dieselben Kombinationen',async()=>{
   const rows=(await db.query(`select jsonb_build_array(a,b,c,d) dice,dungeon_private.dice_options(jsonb_build_array(a,b,c,d),false) white,dungeon_private.dice_options(jsonb_build_array(a,b,c,d),true) all_dice from generate_series(1,6) a cross join generate_series(1,6) b cross join generate_series(1,6) c cross join generate_series(1,6) d`)).rows;
   assert.equal(rows.length,1296);for(const r of rows){assert.deepEqual(sortRequirements(r.white),diceCombinations(r.dice));assert.deepEqual(sortRequirements(r.all_dice),diceCombinations(r.dice,true));}
   assert.deepEqual((await db.query(`select dungeon_private.dice_options('[1,0,2,3]',true) n`)).rows[0].n,[]);
  });
  await t.test('Produktiver Zufallswürfel erzeugt nur gültige Augen; kein öffentlicher Seed',async()=>{
   const results=(await db.query('select dungeon_private.roll_die() n from generate_series(1,1200)')).rows.map(r=>r.n);assert.ok(results.every(n=>Number.isInteger(n)&&n>=1&&n<=6));assert.equal(new Set(results).size,6);
   const grants=(await db.query(`select has_function_privilege('anon','dungeon_private.roll_die()','execute') dice,has_table_privilege('anon','dungeon_game_player_states','update') states`)).rows[0];assert.equal(grants.dice,false);assert.equal(grants.states,false);await installTestDice(db);
  });
  await t.test('Nur aktueller Roller würfelt; verlorene Antworten und Doppelklick würfeln nicht erneut',async()=>{
   const id=await create();assert.equal((await rpc(joni,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()})).error,'GAME_ROLLER_ONLY');
   assert.equal((await rpc(mira,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()})).error,'GAME_NOT_MEMBER');
   await forceDice(db,[2,3,4,5]);const args={p_game_id:id,p_round:1,p_request_id:randomUUID()},first=await rpc(flo,'roll_game_dice',args);assert.equal(first.ok,true);assert.deepEqual(await rpc(flo,'roll_game_dice',args),first);
   assert.deepEqual((await get(id)).dice,[2,3,4,5]);assert.equal((await rpc(flo,'roll_game_dice',{...args,p_request_id:randomUUID()})).error,'GAME_ALREADY_ROLLED');
   assert.equal((await rpc(flo,'roll_game_dice',{...args,p_round:2})).error,'GAME_REQUEST_INVALID');
  });
  await t.test('Alle ziehen pro Wurf, mit eigener Revision; nächster Roller erst nach letztem Zug',async()=>{
   const id=await create();await roll(id,[2,3,4,5]);const before=await get(id),args={p_game_id:id,p_round:1,p_state_revision:before.turn.ownRevision,p_action:'cell',p_cell_id:'1',p_use_red:false,p_request_id:randomUUID()};
   const first=await rpc(flo,'play_game_turn',args);assert.equal(first.ok,true);assert.equal((await get(id)).round,1);assert.deepEqual(await rpc(flo,'play_game_turn',args),first);
   assert.equal((await move(id,flo,2)).error,'GAME_TURN_DONE');assert.equal((await move(id,joni,1,{p_state_revision:before.turn.ownRevision})).ok,true);
   const after=await get(id);assert.equal(after.round,2);assert.equal(after.rollerId,joni.profile.id);assert.equal(after.phase,'waiting_roll');assert.equal(after.dice,null);assert.deepEqual(after.ownState.reached,['1']);
   assert.equal((await rpc(flo,'play_game_turn',{...args,p_request_id:randomUUID()})).error,'GAME_ROUND_CHANGED');
  });
  await t.test('Startfelder bleiben unabhängig von Entfernung erreichbar; Server ignoriert fremde Geometrie',async()=>{
   const id=await create([flo]);await roll(id,[6,6,6,6]);const g=await get(id);assert.deepEqual(g.turn.actions.map(a=>a.cellId),['10']);assert.equal((await move(id,flo,10)).ok,true);assert.deepEqual((await get(id)).ownState.reached,['10']);
  });
  await t.test('Offene Frontier, geschlossene Durchgänge, alte Felder, fremde IDs und Zahlen werden geprüft',async()=>{
   const id=await create([flo]);await seedState(db,id,flo,{reached:['1']});await roll(id,[2,4,3,4]);
   assert.equal((await move(id,flo,1)).error,'GAME_CELL_REACHED');assert.equal((await move(id,flo,7)).error,'GAME_CELL_UNREACHABLE');assert.equal((await move(id,flo,3)).error,'GAME_CELL_UNREACHABLE');assert.equal((await move(id,flo,99999)).error,'GAME_CELL_INVALID');
   assert.equal((await move(id,flo,2,{p_state_revision:999})).error,'GAME_STATE_CHANGED');assert.equal((await move(id,flo,2)).ok,true);
   await roll(id,[3,5,1,2]);assert.equal((await move(id,flo,3)).ok,true);assert.equal((await get(id)).ownState.diamonds,1);
   await roll(id,[4,4,1,2]);assert.equal((await move(id,flo,6)).error,'GAME_CELL_UNREACHABLE');assert.equal((await move(id,flo,5)).ok,true);const hit=await get(id);assert.equal(hit.ownState.monsterHits['5'],1);assert.ok(!hit.ownState.reached.includes('5'));
  });
  await t.test('Pasch-Felder und optisch graue Wegfelder behalten ihre normalen Regeln',async()=>{
   const id=await create([flo]);await seedState(db,id,flo,{reached:['1','2','4']});await roll(id,[2,4,3,4]);assert.equal((await move(id,flo,7)).ok,true);
   await roll(id,[3,3,2,5]);assert.equal((await move(id,flo,8)).ok,true);assert.ok((await get(id)).ownState.reached.includes('8'));
  });
  await t.test('X-Feld aktiviert nur die zugeordnete graue Angriffszahl',async()=>{
   const id=await create([flo]);await seedState(db,id,flo,{reached:['3']});await roll(id,[4,5,1,6]);assert.equal((await move(id,flo,5)).error,'GAME_NUMBER_MISMATCH');assert.equal((await move(id,flo,4)).ok,true);
   await roll(id,[4,5,1,6]);assert.equal((await move(id,flo,5)).ok,true);assert.equal((await get(id)).ownState.monsterHits['5'],1);
  });
  await t.test('Rot braucht bei anderen Spielern Bestätigung; gültige weiße Möglichkeit verbraucht nichts',async()=>{
   const id=await create();await roll(id,[1,1,1,4]);assert.equal((await move(id,joni,1)).error,'GAME_RED_CONFIRMATION');assert.equal((await get(id,joni)).ownState.redUses,3);
   assert.equal((await move(id,joni,1,{p_use_red:true})).ok,true);assert.equal((await get(id,joni)).ownState.redUses,2);assert.equal((await move(id,flo,1)).ok,true);assert.equal((await get(id)).ownState.redUses,3);
   await roll(id,[2,3,4,5]);assert.equal((await move(id,flo,2,{p_use_red:true})).ok,true);assert.equal((await get(id)).ownState.redUses,3);
  });
  await t.test('Optionale rote Möglichkeit darf abgelehnt werden; normaler legaler Zug nicht',async()=>{
   const id=await create();await roll(id,[1,1,1,4]);assert.equal((await move(id,flo,null)).error,'GAME_MOVE_AVAILABLE');assert.equal((await get(id,joni)).turn.canLoseLife,true);assert.equal((await move(id,joni,null)).ok,true);assert.equal((await get(id,joni)).ownState.lostLives,1);assert.equal((await get(id,joni)).ownState.redUses,3);
  });
  await t.test('Kein legaler Zug: automatischer Lebensabzug, Rundenwechsel und Ausscheiden',async()=>{
   const id=await create();await roll(id,[1,1,1,1]);let g=await get(id);assert.equal(g.round,2);assert.equal(g.ownState.lostLives,1);assert.equal(g.rollerId,joni.profile.id);
   await seedState(db,id,joni,{lostLives:10});await roll(id,[1,1,1,1]);g=await get(id);assert.equal(g.participants.find(p=>p.id===joni.profile.id).eliminated,true);assert.equal(g.rollerId,flo.profile.id);
   await seedState(db,id,flo,{lostLives:10});await roll(id,[1,1,1,1]);g=await get(id);assert.equal(g.phase,'round_complete');assert.ok(g.participants.every(p=>p.eliminated));
  });
  await t.test('Erstbelohnung genau einmal, späterer Sieg kleiner; Wiederholung vergibt keine Diamanten',async()=>{
   const id=await create();for(const u of [flo,joni])await seedState(db,id,u,{reached:['3'],monsterHits:{5:1}});await roll(id,[4,4,1,2]);
   const g=await get(id),args={p_game_id:id,p_round:1,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'5',p_use_red:false,p_request_id:randomUUID()};const first=await rpc(flo,'play_game_turn',args);
   assert.equal(first.ok,true);assert.deepEqual(await rpc(flo,'play_game_turn',args),first);assert.equal((await get(id)).ownState.diamonds,3);assert.equal((await move(id,joni,5)).ok,true);assert.equal((await get(id,joni)).ownState.diamonds,1);
   const claims=(await db.query('select * from dungeon_game_monster_claims where game_id=$1',[id])).rows;assert.equal(claims.length,1);assert.equal(claims[0].first_player_id,flo.profile.id);
  });
  await t.test('Verdeckte Karten übertragen keine fremden Wege, Treffer oder versteckten Siegeridentitäten',async()=>{
   const id=await create();await seedState(db,id,flo,{reached:['3'],monsterHits:{5:1}});await roll(id,[4,4,1,2]);await move(id,flo,5);
   const mine=await get(id),other=await get(id,joni);assert.equal(other.states.length,1);assert.equal(other.states[0].playerId,joni.profile.id);assert.deepEqual(other.ownState.monsterHits,{});
   assert.equal(other.events.find(e=>e.kind==='enemy_defeated').payload.playerId,undefined);assert.equal(other.claims[0].playerId,undefined);assert.equal(mine.events.find(e=>e.kind==='enemy_defeated').payload.playerId,flo.profile.id);assert.ok(!other.events.some(e=>e.kind==='turn_played'));
   assert.equal(other.participants.find(p=>p.id===flo.profile.id).points,9);
   const open=await create([flo,joni],{cards:'open'});await seedState(db,open,joni,{reached:['1'],monsterHits:{5:1}});assert.equal((await get(open)).states.length,2);
  });
  await t.test('Ohne Tipps keine Kombinations-/Feldliste, aber dieselbe verbindliche Zugprüfung',async()=>{
   const id=await create([flo],{hints:false});await roll(id,[2,3,4,5]);const g=await get(id);assert.equal(g.turn.actions,undefined);assert.equal(g.turn.options,undefined);assert.equal(g.turn.standardPossible,true);assert.equal((await move(id,flo,2)).error,'GAME_CELL_UNREACHABLE');assert.equal((await move(id,flo,1)).ok,true);
  });
  await t.test('Truhen bleiben erreichbar; offene Powerup-Auswahl wird für Phase 5 gespeichert',async()=>{
   const id=await create([flo]);await seedState(db,id,flo,{reached:['3']});await roll(id,[4,6,1,2]);assert.equal((await move(id,flo,9)).ok,true);const g=await get(id);assert.deepEqual(g.ownState.pendingChests,['9']);assert.deepEqual(g.ownState.powerups,[]);assert.equal(g.ownState.diamonds,0);
  });
  await t.test('Pause blockiert Züge und Würfe; Wiederaufnahme zieht Pausenzeit vom Wartetimer ab',async()=>{
   const id=await create();await roll(id,[2,3,4,5]);let g=await get(id);await rpc(flo,'manage_game',{p_game_id:id,p_expected_revision:g.revision,p_action:'pause',p_target_player_id:null,p_request_id:randomUUID()});
   assert.equal((await move(id,flo,1)).error,'GAME_PAUSED');assert.equal((await rpc(flo,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()})).error,'GAME_PAUSED');
   await db.query(`update dungeon_games set choice_started_at=now()-interval '3 minutes',paused_at=now()-interval '2 minutes' where id=$1`,[id]);g=await get(id);await rpc(flo,'manage_game',{p_game_id:id,p_expected_revision:g.revision,p_action:'resume',p_target_player_id:null,p_request_id:randomUUID()});g=await get(id);assert.ok(Math.abs((Date.parse(g.serverNow)-Date.parse(g.choiceStartedAt))/1000-60)<2);assert.deepEqual(g.dice,[2,3,4,5]);assert.equal(g.round,1);
  });
  await t.test('Nur Host entscheidet nach einer Minute über offene Züge; fertige Züge bleiben geschützt',async()=>{
   const id=await create([flo,joni,mira]);await roll(id,[2,3,4,5]);const args={p_game_id:id,p_round:1,p_target_player_id:joni.profile.id,p_action:'skip',p_request_id:randomUUID()};
   assert.equal((await rpc(joni,'resolve_game_wait',args)).error,'GAME_HOST_ONLY');assert.equal((await rpc(flo,'resolve_game_wait',args)).error,'GAME_WAIT_TOO_SHORT');await db.query(`update dungeon_games set choice_started_at=now()-interval '61 seconds' where id=$1`,[id]);
   const first=await rpc(flo,'resolve_game_wait',args);assert.equal(first.ok,true);assert.deepEqual(await rpc(flo,'resolve_game_wait',args),first);assert.equal((await get(id,joni)).ownState.lostLives,0);assert.equal((await move(id,joni,1)).error,'GAME_TURN_DONE');
   assert.equal((await rpc(flo,'resolve_game_wait',{...args,p_target_player_id:mira.profile.id,p_action:'remove',p_request_id:randomUUID()})).ok,true);assert.equal((await rpc(mira,'get_game',{p_game_id:id})).error,'GAME_REMOVED');assert.equal((await move(id,flo,1)).ok,true);assert.equal((await get(id)).round,2);
  });
  await t.test('Alle Gegner besiegt: restliche Spieler beenden die Endrunde; kein weiterer Wurf und keine vorläufige Schlusswertung',async()=>{
   const id=await create();await seedState(db,id,flo,{reached:['1','2','3','4','5','7','8','9','10','11'],monsterHits:{5:2,6:2,11:1}});await seedState(db,id,joni,{reached:['1']});await roll(id,[4,4,3,4]);
   assert.equal((await move(id,flo,6)).ok,true);let g=await get(id);assert.equal(g.finalRound,1);assert.equal(g.phase,'choosing');assert.equal(g.ownState.diamonds,6);
   assert.equal((await move(id,joni,2)).ok,true);g=await get(id);assert.equal(g.phase,'round_complete');assert.equal(g.status,'playing');assert.equal((await rpc(flo,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()})).error,'GAME_CLOSED');
   assert.equal((await db.query('select count(*)::int n from dungeon_game_results where game_id=$1',[id])).rows[0].n,0);
  });
  await t.test('Realtime bleibt ein kleines Signal und nochmalige Migration setzt keine laufenden Runden zurück',async()=>{
   const id=await create();await roll(id,[2,3,4,5]);await move(id,flo,1);const before=await get(id);
   await db.exec(await readFile(new URL('../supabase/migrations/008_phase4.sql',import.meta.url),'utf8'));const after=await get(id);assert.deepEqual(after.ownState,before.ownState);assert.deepEqual(after.dice,before.dice);assert.equal(after.round,before.round);
   const signals=(await db.query('select payload from realtime.test_signals')).rows;assert.ok(signals.every(s=>Object.keys(s.payload).every(k=>k==='revision')));
   const check=await db.exec(await readFile(new URL('../supabase/migrations/009_check_phase4.sql',import.meta.url),'utf8'));assert.equal(check[2].rows[0].direct_state_write_allowed,false);assert.equal(check[2].rows[0].direct_die_access_allowed,false);
  });
 }finally{await db.close();}
});
