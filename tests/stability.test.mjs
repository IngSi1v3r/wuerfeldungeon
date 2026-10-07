import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {createStabilityDatabase} from './helpers/stability.mjs';
import {createClassicDatabase,classicFixture} from './helpers/classic-game.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,newPlayGame,seedState} from './helpers/turns.mjs';
import {gameWaitKind,elapsedWaitSeconds} from '../web/js/games/rules.js';

test('Stabilitätsupdate: ausstehende Würfe auf PostgreSQL',{timeout:120000},async t=>{
 const db=await createStabilityDatabase(),a=await register(db,'Flo'),b=await register(db,'Joni'),c=await register(db,'Mira'),map=await publishFixture(db,a,'Stabile Mine',classicFixture());await installTestDice(db);
 const rpc=(u,n,p)=>userRpc(db,u,n,p),get=async(id,u=a)=>(await rpc(u,'get_game',{p_game_id:id})).game,create=(users=[a,b])=>newPlayGame(db,users,{cards:'hidden'},map);
 const age=async(id,field='roll_wait_started_at',seconds=61)=>{assert.ok(['roll_wait_started_at','choice_started_at'].includes(field));await db.query(`update dungeon_games set ${field}=now()-($2*interval '1 second') where id=$1`,[id,seconds]);};
 const waitArgs=(id,round,target,action='skip')=>({p_game_id:id,p_round:round,p_target_player_id:target.profile.id,p_action:action,p_request_id:randomUUID()});
 async function roll(id,u,dice=[2,3,4,5]){const g=await get(id,u);await forceDice(db,dice);return rpc(u,'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});}
 async function move(id,u,cell){const g=await get(id,u);return rpc(u,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:String(cell),p_use_red:false,p_request_id:randomUUID()});}
 try{
  await t.test('Erster Wurf erhält eine Uhr; nur Host und erst nach 60 Sekunden; kein Fremdziel',async()=>{
   const id=await create(),g=await get(id),args=waitArgs(id,1,a);assert.ok(g.rollWaitStartedAt);assert.equal(gameWaitKind(g),'roll');assert.equal((await db.query('select public.app_status() value')).rows[0].value.stabilitySchemaVersion,1);
   const before=g.ownState;assert.equal((await rpc(b,'resolve_game_wait',args)).error,'GAME_HOST_ONLY');assert.equal((await rpc(a,'resolve_game_wait',args)).error,'GAME_WAIT_TOO_SHORT');await age(id);
   assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b))).error,'GAME_TURN_DONE');assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,0,a))).error,'GAME_ROUND_CHANGED');assert.equal((await rpc(a,'resolve_game_wait',{...args,p_action:'invalid'})).error,'GAME_ACTION_INVALID');assert.deepEqual((await get(id)).ownState,before);
  });
  await t.test('Weitergeben ist atomar und wiederholbar, verändert weder Runde noch Spielerfortschritt',async()=>{
   const id=await create([a,b,c]);await age(id);const g=await get(id),before=(await get(id,b)),args=waitArgs(id,1,a),first=await rpc(a,'resolve_game_wait',args);assert.equal(first.ok,true);assert.deepEqual(await rpc(a,'resolve_game_wait',args),first);
   const after=await get(id);assert.equal(after.rollerId,b.profile.id);assert.equal(after.round,1);assert.equal(after.phase,'waiting_roll');assert.equal(after.dice,null);assert.equal(after.revision,g.revision+1);assert.deepEqual(after.ownState,g.ownState);assert.equal(after.turn.ownRevision,g.turn.ownRevision);assert.deepEqual((await get(id,b)).ownState,before.ownState);
   assert.equal(after.participants.find(p=>p.id===a.profile.id).active,true);assert.ok(Date.parse(after.serverNow)-Date.parse(after.rollWaitStartedAt)<2000);assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b))).error,'GAME_WAIT_TOO_SHORT');
   assert.equal((await rpc(a,'roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()})).error,'GAME_ROLLER_ONLY');assert.equal((await roll(id,b)).ok,true);assert.equal((await move(id,a,1)).ok,true);assert.equal((await move(id,b,1)).ok,true);assert.equal((await move(id,c,1)).ok,true);const next=await get(id);assert.equal(next.round,2);assert.equal(next.rollerId,c.profile.id);assert.ok(next.rollWaitStartedAt);
   assert.equal((await db.query("select count(*)::int n from dungeon_game_events where game_id=$1 and kind='turn_skipped' and payload->'skippedRoll'='true'",[id])).rows[0].n,1);
  });
  await t.test('Gemeldeter Fehler: übersprungener Zug, danach fehlender Wurf, Wiedereinstieg',async()=>{
   const id=await create();await roll(id,a);await move(id,a,1);await age(id,'choice_started_at');assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b))).ok,true);let g=await get(id);assert.equal(g.round,2);assert.equal(g.rollerId,b.profile.id);assert.equal((await get(id,b)).ownState.lostLives,0);
   await age(id);assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,2,b))).ok,true);g=await get(id);assert.equal(g.round,2);assert.equal(g.rollerId,a.profile.id);assert.equal((await roll(id,a)).ok,true);assert.equal((await get(id,b)).turn.canAct,true);assert.equal((await move(id,b,1)).ok,true);assert.equal((await move(id,a,2)).ok,true);
   g=await get(id);assert.equal(g.turn.pendingPowerup,true);assert.equal(g.rollWaitStartedAt,null);assert.equal(g.round,2);
  });
  await t.test('Pause friert auch die Würfelwartezeit ein; Fortsetzen rechnet Pausendauer heraus',async()=>{
   const id=await create();await age(id,'roll_wait_started_at',20);let g=await get(id);await rpc(a,'manage_game',{p_game_id:id,p_expected_revision:g.revision,p_action:'pause',p_request_id:randomUUID()});
   assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,a))).error,'GAME_PAUSED');await db.query("update dungeon_games set roll_wait_started_at=now()-interval '140 seconds',paused_at=now()-interval '120 seconds' where id=$1",[id]);g=await get(id);assert.equal(elapsedWaitSeconds(g),20);
   assert.equal((await rpc(a,'manage_game',{p_game_id:id,p_expected_revision:g.revision,p_action:'resume',p_request_id:randomUUID()})).ok,true);g=await get(id);assert.equal(elapsedWaitSeconds(g,Date.parse(g.serverNow)),20);assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,a))).error,'GAME_WAIT_TOO_SHORT');
  });
  await t.test('Entfernen gibt den Wurf weiter; ausgeschiedene Spieler werden ausgelassen',async()=>{
   const id=await create([a,b,c]);await age(id);await rpc(a,'resolve_game_wait',waitArgs(id,1,a));await age(id);await db.query('update dungeon_game_players set eliminated=true where game_id=$1 and player_id=$2',[id,c.profile.id]);
   assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b,'remove'))).ok,true);const g=await get(id);assert.equal(g.rollerId,a.profile.id);assert.equal(g.participants.some(p=>p.id===b.profile.id),false);assert.equal((await rpc(b,'get_game',{p_game_id:id})).error,'GAME_REMOVED');assert.equal((await roll(id,a)).ok,true);
  });
  await t.test('Wurfweitergabe überspringt keinen privaten Truhendialog',async()=>{
   const id=await create();await seedState(db,id,b,{pendingChests:['2']});await db.query('update dungeon_games set choice_started_at=now() where id=$1',[id]);const g=await get(id);assert.equal(g.rollWaitStartedAt,null);assert.equal(gameWaitKind(g),'turn');assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,a))).error,'GAME_WAIT_TOO_SHORT');
   await age(id,'choice_started_at');assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,a))).error,'GAME_TURN_DONE');assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b))).ok,true);assert.ok((await get(id)).rollWaitStartedAt);assert.deepEqual((await get(id,b)).ownState.pendingChests,[]);
  });
  await t.test('Keine andere Würfelperson: kein nutzloser Skip; Entfernen des letzten aktiven Spielers wertet ab',async()=>{
   const single=await create([a]);await age(single);assert.equal((await rpc(a,'resolve_game_wait',waitArgs(single,1,a))).error,'GAME_NO_OTHER_ROLLER');assert.equal((await get(single)).rollerId,a.profile.id);
   const id=await create();await age(id);await rpc(a,'resolve_game_wait',waitArgs(id,1,a));await db.query('update dungeon_game_players set eliminated=true where game_id=$1 and player_id=$2',[id,a.profile.id]);await age(id);assert.equal((await rpc(a,'resolve_game_wait',waitArgs(id,1,b,'remove'))).ok,true);assert.equal((await get(id)).status,'finished');
  });
  await t.test('Migration wiederholbar, laufender Zustand erhalten und private Uhr nicht direkt aufrufbar',async()=>{
   const id=await create();await seedState(db,id,a,{reached:['1'],diamonds:4,torchUses:2});const before=await get(id);await db.exec(await readFile(new URL('../supabase/migrations/012_stability.sql',import.meta.url),'utf8'));const after=await get(id);assert.deepEqual(after.ownState,before.ownState);assert.equal(after.revision,before.revision);assert.equal(after.rollWaitStartedAt,before.rollWaitStartedAt);
   const rows=(await db.exec(await readFile(new URL('../supabase/migrations/013_check_stability.sql',import.meta.url),'utf8')))[1].rows[0];assert.deepEqual(Object.values(rows),[true,true,true,true,false]);
  });
 }finally{await db.close();}
});

test('Bestehende wartende und pausierte Partien erhalten beim Update eine passende Uhr',async()=>{
 const db=await createClassicDatabase();try{
  const a=await register(db,'Altflo'),b=await register(db,'Altjoni'),map=await publishFixture(db,a,'Alte Mine',classicFixture()),id=await newPlayGame(db,[a,b],{},map),paused=await newPlayGame(db,[a,b],{},map);
  await seedState(db,id,a,{reached:['1'],diamonds:5});let g=(await userRpc(db,a,'get_game',{p_game_id:paused})).game;await userRpc(db,a,'manage_game',{p_game_id:paused,p_expected_revision:g.revision,p_action:'pause',p_request_id:randomUUID()});await db.query("update dungeon_games set paused_at=now()-interval '5 minutes' where id=$1",[paused]);
  await db.exec(await readFile(new URL('../supabase/migrations/012_stability.sql',import.meta.url),'utf8'));g=(await userRpc(db,a,'get_game',{p_game_id:id})).game;assert.ok(g.rollWaitStartedAt);assert.equal(g.ownState.diamonds,5);assert.deepEqual(g.ownState.reached,['1']);
  g=(await userRpc(db,a,'get_game',{p_game_id:paused})).game;assert.equal(g.rollWaitStartedAt,g.pausedAt);assert.equal(elapsedWaitSeconds(g),0);
 }finally{await db.close();}
});
