import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readFile} from 'node:fs/promises';
import {createClassicDatabase,classicFixture} from './helpers/classic-game.mjs';import {createPlayDatabase,installTestDice,forceDice,newPlayGame,seedState} from './helpers/turns.mjs';import {register,userRpc,publishFixture} from './helpers/games.mjs';

test('Vollständiger Klassische Regeln auf echtem PostgreSQL',{timeout:120000},async t=>{
 const db=await createClassicDatabase();const a=await register(db,'Flo'),b=await register(db,'Joni'),c=await register(db,'Mira'),map=await publishFixture(db,a,'Klassische Regeln',classicFixture());await installTestDice(db);
 const rpc=(u,n,p)=>userRpc(db,u,n,p),get=async(id,u=a)=>(await rpc(u,'get_game',{p_game_id:id})).game;
 const create=(users=[a,b],settings={},m=map)=>newPlayGame(db,users,settings,m);
 async function roll(id,dice){const g=await get(id);await forceDice(db,dice);return rpc([a,b,c].find(u=>u.profile.id===g.rollerId),'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});}
 async function move(id,u,cell,more={}){const g=await get(id,u);return rpc(u,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:cell==null?'lose_life':'cell',p_cell_id:cell==null?null:String(cell),p_use_red:false,p_request_id:randomUUID(),p_middle_cell_id:null,p_use_axe:false,...more});}
 async function choose(id,u,type,chest=null,more={}){const g=await get(id,u);return rpc(u,'choose_game_powerup',{p_game_id:id,p_state_revision:g.turn.ownRevision,p_chest_cell_id:chest||g.ownState.pendingChests?.[0],p_powerup:type,p_request_id:randomUUID(),...more});}
 try{
 await t.test('Truhe hält die Runde bis zur Auswahl an; jede Sorte nur einmal; alle vier Effekte',async()=>{
  const id=await create([a]);await seedState(db,id,a,{reached:['1']});await roll(id,[3,4,2,5]);assert.equal((await move(id,a,2)).ok,true);let g=await get(id);assert.equal(g.round,1);assert.equal(g.turn.pendingPowerup,true);assert.equal(g.turn.canRoll,false);
  assert.equal((await choose(id,a,'extraLife')).ok,true);g=await get(id);assert.equal(g.round,2);assert.equal(g.ownState.extraLives,3);assert.equal(g.ownState.diamonds,1);
  await roll(id,[2,4,1,2]);await move(id,a,7);assert.equal((await choose(id,a,'extraLife')).error,'GAME_POWERUP_UNAVAILABLE');assert.equal((await choose(id,a,'torch')).ok,true);assert.equal((await get(id)).ownState.torchUses,2);
  await roll(id,[4,6,1,2]);await move(id,a,8);const g2=await get(id),request={p_game_id:id,p_state_revision:g2.turn.ownRevision,p_chest_cell_id:'8',p_powerup:'redDice',p_request_id:randomUUID()};const first=await rpc(a,'choose_game_powerup',request);assert.equal(first.ok,true);assert.deepEqual(await rpc(a,'choose_game_powerup',request),first);assert.equal((await get(id)).ownState.redUses,6);
  await roll(id,[5,6,1,2]);await move(id,a,9);await choose(id,a,'axe');g=await get(id);assert.equal(g.ownState.axeUses,2);assert.equal(g.ownState.powerups.length,4);assert.deepEqual(g.ownState.pendingChests,[]);
 });
 await t.test('Fackel markiert den Zwischenraum ohne Zahl, erhält Diamant und schaltet X-Angriff sofort frei',async()=>{
  const id=await create([a]);await seedState(db,id,a,{reached:['1','2'],torchUses:2,powerups:['torch']});await roll(id,[4,5,1,1]);
  assert.equal((await move(id,a,4,{p_middle_cell_id:'3'})).ok,true);let g=await get(id);assert.ok(g.ownState.reached.includes('3')&&g.ownState.reached.includes('4'));assert.equal(g.ownState.torchUses,1);assert.equal(g.ownState.diamonds,7);assert.deepEqual(g.ownState.taskRewards,{special:3,custom:3});
  const id2=await create([a]);await seedState(db,id2,a,{reached:['3'],torchUses:2});await roll(id2,[4,5,1,1]);assert.equal((await move(id2,a,5,{p_middle_cell_id:'4'})).ok,true);g=await get(id2);assert.equal(g.ownState.monsterHits['5'],1);assert.ok(!g.ownState.reached.includes('5'));assert.equal(g.ownState.torchUses,1);assert.equal(g.ownState.taskRewards.special,3);
 });
 await t.test('Ungültige Fackelwege und rote Abbrüche kosten nichts; Gegner sind kein Zwischenraum',async()=>{
  const id=await create();await seedState(db,id,b,{reached:['1','2'],torchUses:2});await roll(id,[1,1,1,6]);const before=(await get(id,b)).ownState;
  assert.equal((await move(id,b,4,{p_middle_cell_id:'3'})).error,'GAME_NUMBER_MISMATCH');assert.deepEqual((await get(id,b)).ownState,before);
  assert.equal((await move(id,b,3,{p_middle_cell_id:'7'})).error,'GAME_TORCH_PATH');assert.equal((await move(id,b,6,{p_middle_cell_id:'5'})).error,'GAME_TORCH_PATH');
  // Ziel 7 (Truhe) nur mit Rot; Zwischenraum 8 ist erreichbar von 2? Separater Pfad 1 -> 2 -> 3.
  assert.equal((await move(id,b,3,{p_middle_cell_id:'2'})).error,'GAME_TORCH_PATH');
  const id2=await create();await seedState(db,id2,b,{reached:['1'],torchUses:2});await roll(id2,[1,1,1,6]);const g=await get(id2,b);assert.equal(g.turn.torchPossible,true);assert.equal((await move(id2,b,2)).error,'GAME_RED_CONFIRMATION');assert.equal((await get(id2,b)).ownState.torchUses,2);
  assert.equal((await move(id2,b,8,{p_middle_cell_id:'7'})).error,'GAME_TORCH_PATH');
 });
 await t.test('Rote Fackelaktion ist atomar, Truhen im Zwischenraum behalten ihre Auswahl',async()=>{
  const id=await create();await seedState(db,id,b,{reached:['1'],torchUses:2});await roll(id,[1,1,1,5]);
  assert.equal((await move(id,b,7,{p_middle_cell_id:'2'})).error,'GAME_RED_CONFIRMATION');let g=await get(id,b);assert.equal(g.ownState.redUses,3);assert.equal(g.ownState.torchUses,2);assert.deepEqual(g.ownState.pendingChests||[],[]);
  assert.equal((await move(id,b,7,{p_middle_cell_id:'2',p_use_red:true})).ok,true);g=await get(id,b);assert.equal(g.ownState.redUses,2);assert.equal(g.ownState.torchUses,1);assert.deepEqual(g.ownState.pendingChests,['2','7']);await choose(id,b,'torch');assert.equal((await choose(id,b,'redDice')).ok,true);
 });
 await t.test('Optionaler Fackelzug verhindert automatischen Verlust, darf aber abgelehnt werden',async()=>{
  const id=await create([a]);await seedState(db,id,a,{reached:['1','2'],torchUses:2,redUses:0});await roll(id,[4,5,5,5]);let g=await get(id);assert.equal(g.ownState.lostLives,0);assert.equal(g.turn.canLoseLife,true);assert.equal(g.turn.torchPossible,true);assert.equal((await move(id,a,null)).ok,true);g=await get(id);assert.equal(g.ownState.lostLives,1);assert.equal(g.ownState.torchUses,2);
 });
 await t.test('Doppelhit, Begrenzung auf Restleben, Weiß vor Rot und inkompatible Fackel/Axt',async()=>{
  const id=await create();for(const u of [a,b])await seedState(db,id,u,{reached:['3','4'],axeUses:2,torchUses:2});await roll(id,[4,4,1,2]);
  assert.equal((await move(id,a,5,{p_use_axe:true,p_use_red:true})).ok,true);let g=await get(id);assert.equal(g.ownState.monsterHits['5'],2);assert.equal(g.ownState.axeUses,1);assert.equal(g.ownState.redUses,3);
  assert.equal((await move(id,b,5,{p_middle_cell_id:'9',p_use_axe:true})).error,'GAME_POWERUP_COMBINATION');assert.equal((await move(id,b,5,{p_use_axe:true})).ok,true);assert.equal((await get(id,b)).ownState.diamonds,2); // Späterer Sieg + spätere X-Aufgabe, Sammelziel noch nicht erreicht
  await seedState(db,id,a,{monsterHits:{5:2,6:11}});await roll(id,[4,4,1,2]);await move(id,a,6,{p_use_axe:true});g=await get(id);assert.equal(g.ownState.monsterHits['6'],12);assert.equal(g.ownState.axeUses,0);
 });
 await t.test('Erstbelohnungen für beide Aufgaben und kein Wiederholen durch Requests/Neuladen',async()=>{
  const id=await create();for(const u of [a,b])await seedState(db,id,u,{reached:['3'],diamonds:1});await roll(id,[4,5,1,1]);await move(id,b,4);await move(id,a,4);
  const one=await get(id,b),two=await get(id);assert.deepEqual(one.ownState.taskRewards,{special:3,custom:3});assert.deepEqual(two.ownState.taskRewards,{special:1});assert.equal(one.ownState.diamonds,7);assert.equal(two.ownState.diamonds,2);for(let i=0;i<3;i++)await get(id,b);assert.equal((await get(id,b)).ownState.diamonds,7);
  const claims=(await db.query('select * from dungeon_game_task_claims where game_id=$1',[id])).rows;assert.equal(claims.length,2);assert.ok(claims.every(c=>c.first_player_id===b.profile.id));
 });
 await t.test('Ohne Tipps werden keine Fackelvorschläge und keine fremden Spielstände übertragen',async()=>{
  const id=await create([a,b],{hints:false});await seedState(db,id,a,{reached:['2'],torchUses:2});await roll(id,[4,5,1,1]);const g=await get(id);const options=await rpc(a,'get_torch_options',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision});assert.deepEqual(options.actions,[]);assert.equal(g.states.length,1);assert.equal(g.turn.actions,undefined);assert.equal(g.tasks.special.firstPlayerId,undefined);assert.ok(!g.events.some(e=>e.kind==='turn_played'));
 });
 await t.test('Schlussrunde wartet auf Mitspieler und Truhe; Bossbonus, Gleichstand, Chronik und Profilstatistik',async()=>{
  const id=await create();await seedState(db,id,a,{reached:['1','2','3','4','5'],monsterHits:{5:2,6:11},diamonds:0,taskRewards:{special:3,custom:3}});
  await seedState(db,id,b,{reached:['1','2','3','4','5'],monsterHits:{5:2,6:10},diamonds:3,taskRewards:{special:1,custom:1}});await roll(id,[4,4,2,4]);await move(id,a,6);let g=await get(id);assert.equal(g.finalRound,1);assert.equal(g.status,'playing');await move(id,b,7);g=await get(id);assert.equal(g.status,'playing');assert.equal((await choose(id,b,'torch')).ok,true);g=await get(id);assert.equal(g.status,'finished');assert.equal(g.phase,'finished');assert.equal(g.results.length,2);
  const first=g.results.find(r=>r.playerId===a.profile.id),later=g.results.find(r=>r.playerId===b.profile.id);assert.equal(first.breakdown.bossBonusDiamonds,0);assert.equal(later.breakdown.bossBonusDiamonds,3);assert.equal(first.diamonds,6);assert.equal(later.diamonds,6);assert.ok(g.results.every(r=>r.won));
  const stats=(await rpc(a,'get_player_profile',{})).profile.stats;assert.ok(stats.gamesPlayed>=1&&stats.wins>=1);assert.equal((await rpc(a,'get_game_result',{p_game_id:id})).game.results.length,2);assert.equal((await db.query('select count(*)::int n from dungeon_game_results where game_id=$1',[id])).rows[0].n,2);await get(id);assert.equal((await get(id)).ownState.diamonds,6);
 });
 await t.test('Drei zusätzliche Nullfelder und Tod nach 14 Verlusten; alle tot schließt Spiel ab',async()=>{
  const id=await create();await seedState(db,id,a,{lostLives:10});await seedState(db,id,b,{lostLives:10,extraLives:3});await roll(id,[1,1,1,1]);let g=await get(id,b);assert.equal(g.participants.find(p=>p.id===a.profile.id).eliminated,true);assert.equal(g.participants.find(p=>p.id===b.profile.id).eliminated,false);assert.equal(g.status,'playing');assert.equal(g.rollerId,b.profile.id);for(let i=0;i<3;i++)await roll(id,[1,1,1,1]);g=await get(id,b);assert.equal(g.status,'finished');assert.equal(g.ownState.lostLives,14);assert.equal(g.results.find(r=>r.playerId===b.profile.id).lifePenalty,-20);
 });
 await t.test('Host kann auch eine überfällige Powerup-Auswahl ausdrücklich überspringen',async()=>{
  const id=await create();await seedState(db,id,b,{reached:['1']});await roll(id,[3,4,2,5]);await move(id,b,2);await move(id,a,1);await db.query("update dungeon_games set choice_started_at=now()-interval '61 seconds' where id=$1",[id]);assert.equal((await rpc(a,'resolve_game_wait',{p_game_id:id,p_round:1,p_target_player_id:b.profile.id,p_action:'skip',p_request_id:randomUUID()})).ok,true);assert.equal((await get(id)).round,2);assert.deepEqual((await get(id,b)).ownState.powerups,[]);
 });
 await t.test('Rot + Axt verbraucht beide Ressourcen einmal; Mini-Bossgruppen und Aufgaben-Ziele',async()=>{
  const doc=classicFixture();doc.rooms[5].type='miniboss';doc.rooms[5].w=12;doc.rooms[5].hits=6;doc.rooms[5].attacks=[{number:6,state:'active'}];doc.rules.customGoal={type:'defeatEnemies',cellIds:[5],diamonds:3};const customMap=await publishFixture(db,a,'Mini-Gruppen',doc);
  const id=await create([a,b],{},customMap);for(const u of [a,b])await seedState(db,id,u,{reached:['5'],axeUses:2,taskRewards:{special:3}});await seedState(db,id,b,{monsterHits:{5:2,6:1}});await roll(id,[1,1,1,5]);const before=(await get(id,b)).ownState;
  assert.equal((await move(id,b,6,{p_use_axe:true})).error,'GAME_RED_CONFIRMATION');assert.deepEqual((await get(id,b)).ownState,before);assert.equal((await move(id,b,6,{p_use_axe:true,p_use_red:true})).ok,true);let g=await get(id,b);assert.equal(g.ownState.redUses,2);assert.equal(g.ownState.axeUses,1);assert.equal(g.ownState.monsterHits['6'],3);
  // Seed only the remaining hits to exercise scoring of an explicit mini-boss type.
  await seedState(db,id,a,{monsterHits:{5:2,6:5}});assert.equal((await move(id,a,6)).ok,true);g=await get(id,b);assert.equal(g.status,'finished');assert.equal(g.results.find(r=>r.playerId===b.profile.id).breakdown.bossBonusDiamonds,1);
  const reachDoc=classicFixture();reachDoc.rules.customGoal={type:'reachFields',cellIds:[1,2],diamonds:3};const reachMap=await publishFixture(db,a,'Ziel-Felder',reachDoc),reach=await create([a],{},reachMap);await seedState(db,reach,a,{reached:['1']});await roll(reach,[3,4,1,2]);await move(reach,a,2);assert.equal((await get(reach)).ownState.taskRewards.custom,3);
 });
 await t.test('Migration wiederholbar, private Hilfen geschützt, alte RPC-Signatur weiter gültig',async()=>{
  await db.exec(await readFile(new URL('../supabase/migrations/010_phase5.sql',import.meta.url),'utf8'));const id=await create([a]);await roll(id,[2,3,4,5]);const g=await get(id),args={p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'1',p_use_red:false,p_request_id:randomUUID()};const r=await rpc(a,'play_game_turn',args);assert.equal(r.ok,true);assert.deepEqual(await rpc(a,'play_game_action',{...args,p_middle_cell_id:null,p_use_axe:false}),r);
  const grants=(await db.query("select has_function_privilege('anon','dungeon_private.finalize_game(uuid)','execute') finalize,has_table_privilege('anon','dungeon_game_task_claims','insert') claims")).rows[0];assert.equal(grants.finalize,false);assert.equal(grants.claims,false);
 });
 }finally{await db.close();}
});

test('Phase-4-Upgrade erhält Partien und vergibt nachträgliche Aufgaben in historischer Reihenfolge',{timeout:120000},async()=>{
 const db=await createPlayDatabase();try{
  const a=await register(db,'Alma'),b=await register(db,'Bert'),doc=classicFixture();doc.rules.customGoal={type:'reachFields',cellIds:[4],diamonds:3};const map=await publishFixture(db,a,'Altbestand',doc);await installTestDice(db);
  const rpc=(u,n,p)=>userRpc(db,u,n,p),get=async(id,u=a)=>(await rpc(u,'get_game',{p_game_id:id})).game;
  const id=await newPlayGame(db,[a,b],{},map);for(const u of [a,b])await seedState(db,id,u,{reached:['3']});await forceDice(db,[4,5,1,1]);await rpc(a,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()});
  for(const u of [b,a]){const g=await get(id,u);assert.equal((await rpc(u,'play_game_turn',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'4',p_use_red:false,p_request_id:randomUUID()})).ok,true);}
  const before=await get(id);await db.exec(await readFile(new URL('../supabase/migrations/010_phase5.sql',import.meta.url),'utf8'));let mine=await get(id),other=await get(id,b);
  assert.deepEqual(mine.ownState.reached,before.ownState.reached);assert.equal(mine.round,before.round);assert.equal(mine.ownState.diamonds,2);assert.equal(other.ownState.diamonds,6);assert.deepEqual(other.ownState.taskRewards,{special:3,custom:3});
  for(let i=0;i<3;i++)await get(id);assert.equal((await get(id)).ownState.diamonds,2);
  // Endrunde eines bestehenden Phase-4-Spiels, einschließlich noch offener Truhe.
  const db2=await createPlayDatabase();try{
   const u=await register(db2,'Cora'),v=await register(db2,'Doro'),m=await publishFixture(db2,u,'Alte Endrunde',classicFixture()),gId=await newPlayGame(db2,[u,v],{},m);await installTestDice(db2);
   await seedState(db2,gId,u,{reached:['1','2','3','4','5'],monsterHits:{5:2,6:11}});await seedState(db2,gId,v,{reached:['1','2']});await forceDice(db2,[4,4,2,4]);await userRpc(db2,u,'roll_game_dice',{p_game_id:gId,p_round:1,p_request_id:randomUUID()});
   for(const [player,cell] of [[u,'6'],[v,'7']]){const g=(await userRpc(db2,player,'get_game',{p_game_id:gId})).game;await userRpc(db2,player,'play_game_turn',{p_game_id:gId,p_round:1,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:cell,p_use_red:false,p_request_id:randomUUID()});}
   const old=(await userRpc(db2,u,'get_game',{p_game_id:gId})).game;assert.equal(old.phase,'round_complete');await db2.exec(await readFile(new URL('../supabase/migrations/010_phase5.sql',import.meta.url),'utf8'));
   const g=(await userRpc(db2,v,'get_game',{p_game_id:gId})).game;assert.equal(g.status,'playing');assert.deepEqual(g.ownState.pendingChests,['7']);assert.equal((await userRpc(db2,v,'choose_game_powerup',{p_game_id:gId,p_chest_cell_id:'7',p_state_revision:g.turn.ownRevision,p_powerup:'extraLife',p_request_id:randomUUID()})).ok,true);assert.equal((await userRpc(db2,u,'get_game',{p_game_id:gId})).game.status,'finished');
  }finally{await db2.close();}
 }finally{await db.close();}
});
