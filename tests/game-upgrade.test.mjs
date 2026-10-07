import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readFile} from 'node:fs/promises';
import {createUpgradedDatabase,modernFixture} from './helpers/game-upgrade.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';import {newPlayGame,forceDice,installTestDice,seedState} from './helpers/turns.mjs';
import {goalDefault} from '../web/js/maps/features.js';import {callRpc} from './helpers/database.mjs';
import {createStabilityDatabase} from './helpers/stability.mjs';import {classicFixture} from './helpers/classic-game.mjs';

test('Neue Spielregeln auf PostgreSQL',{timeout:120000},async t=>{
 const db=await createUpgradedDatabase(),a=await register(db,'Flo'),b=await register(db,'Joni'),c=await register(db,'Mira'),users=[a,b,c];
 const rpc=(u,name,args={})=>userRpc(db,u,name,args),get=async(id,u=a)=>(await rpc(u,'get_game',{p_game_id:id})).game;
 const map=await publishFixture(db,a,'Neue Mine',modernFixture());await installTestDice(db);
 const create=(us=[a,b],settings={},m=map)=>newPlayGame(db,us,settings,m);
 async function roll(id,dice){const g=await get(id);await forceDice(db,dice);return rpc(users.find(u=>u.profile.id===g.rollerId),'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});}
 async function move(id,u,cell,extra={}){const g=await get(id,u);return rpc(u,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:cell==null?'lose_life':'cell',p_cell_id:cell==null?null:String(cell),p_use_red:false,p_request_id:randomUUID(),p_middle_cell_id:null,p_use_axe:false,...extra});}
 async function skip(id,u){await db.query("update dungeon_games set choice_started_at=now()-interval '61 seconds' where id=$1",[id]);const g=await get(id);return rpc(a,'resolve_game_wait',{p_game_id:id,p_round:g.round,p_target_player_id:u.profile.id,p_action:'skip',p_request_id:randomUUID()});}
 try{
 await t.test('Wiederholbare Migration, neue Karten sichtbar, alte Requests und Login erhalten',async()=>{
  await db.exec(await readFile(new URL('../supabase/migrations/016_game_rules.sql',import.meta.url),'utf8'));assert.equal((await callRpc(db,'app_status')).gameFeaturesVersion,1);assert.ok((await rpc(a,'list_game_maps')).maps.some(m=>m.versionId===map.versionId));
  const id=await create();assert.equal((await get(id)).rulesVersion,7);assert.equal((await rpc(a,'get_player_profile')).profile.id,a.profile.id);
 });
 await t.test('Graues Nachbarfeld und entfernte Rune aktivieren die richtige Angriffszahl',async()=>{
  const id=await create();for(const u of [a,b])await seedState(db,id,u,{reached:['1']});await roll(id,[3,4,1,1]);
  assert.equal((await move(id,a,2)).ok,true);let g=await get(id);assert.ok(g.ownState.reached.includes('2'));assert.equal((await move(id,b,2)).ok,true);
  await roll(id,[3,4,1,1]);assert.equal((await move(id,a,3)).ok,true);assert.equal((await get(id)).ownState.monsterHits['3'],1);
  const id2=await create();await seedState(db,id2,a,{reached:['5'],torchUses:2});await roll(id2,[4,5,1,1]);assert.equal((await move(id2,a,11)).ok,true);g=await get(id2);assert.ok(g.ownState.reached.includes('11'));
  await seedState(db,id2,b,{reached:['2']});assert.equal((await move(id2,b,3)).error,'GAME_NUMBER_MISMATCH');
  const req=(await db.query("select dungeon_private.game_cell_requirements(g,c,v.rules,s.state) r from dungeon_games g join dungeon_map_versions v on v.id=g.map_version_id join dungeon_map_cells c on c.version_id=v.id and c.cell_id='12' join dungeon_game_player_states s on s.game_id=g.id and s.player_id=$2 where g.id=$1",[id2,a.profile.id])).rows[0].r;assert.ok(req.includes('9'));
 });
 await t.test('Gleiche Runde gibt beiden Erstbelohnung; folgende Runde die kleine Belohnung',async()=>{
  const id=await create(users);for(const u of users)await seedState(db,id,u,{reached:['2'],monsterHits:{3:1}});await roll(id,[4,4,1,2]);
  assert.equal((await move(id,b,3)).ok,true);assert.equal((await move(id,a,3)).ok,true);assert.equal((await get(id)).ownState.diamonds,3);assert.equal((await get(id,b)).ownState.diamonds,3);
  let g=await get(id,c);assert.equal(g.claims[0].firstAvailable,true);assert.equal(g.claims[0].playerId,undefined);await skip(id,c);await roll(id,[4,4,1,2]);assert.equal((await move(id,c,3)).ok,true);g=await get(id,c);assert.equal(g.ownState.diamonds,1);assert.ok(!g.ownState.firstKills?.includes('3'));
 });
 await t.test('Falle ist in der Aktivierungsrunde sicher; später negative Diamanten; Retry zahlt nur einmal',async()=>{
  const id=await create(users);for(const u of users)await seedState(db,id,u,{reached:['6']});await roll(id,[2,3,1,1]);await move(id,a,7);await move(id,b,7);let g=await get(id,c);assert.equal(g.traps[0].armed,false);assert.equal((await get(id)).ownState.diamonds,0);assert.equal((await get(id,b)).ownState.diamonds,0);
  await skip(id,c);g=await get(id,c);assert.equal(g.traps[0].armed,true);await roll(id,[2,3,1,1]);await db.query("update dungeon_games set final_round=round_index where id=$1",[id]);g=await get(id,c);const args={p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'7',p_use_red:false,p_request_id:randomUUID(),p_middle_cell_id:null,p_use_axe:false};const answer=await rpc(c,'play_game_action',args);assert.equal(answer.ok,true);assert.deepEqual(await rpc(c,'play_game_action',args),answer);g=await get(id,c);assert.equal(g.ownState.diamonds,-2);assert.equal(g.status,'finished');assert.equal(g.results.find(r=>r.playerId===c.profile.id).diamonds,-2);assert.equal(g.results.find(r=>r.playerId===c.profile.id).points,-6);
 });
 await t.test('Lebensfalle verliert mehrere Kästchen, meldet Ursache und scheidet bei 11 aus',async()=>{
  const id=await create();for(const u of [a,b])await seedState(db,id,u,{reached:['14']});await roll(id,[4,5,1,1]);await move(id,a,15);await skip(id,b);await seedState(db,id,b,{lostLives:9});await roll(id,[4,5,1,1]);assert.equal((await move(id,b,15)).ok,true);const g=await get(id,b);assert.equal(g.ownState.lostLives,11);assert.equal(g.participants.find(p=>p.id===b.profile.id).eliminated,true);assert.ok(g.events.some(e=>e.kind==='life_lost'&&e.payload.cause==='trap'&&e.payload.amount===2));
 });
 await t.test('Portal aktiviert beide Räume und schafft zwei Frontiers, ohne zweiten Zug',async()=>{
  const id=await create();await seedState(db,id,a,{reached:['1']});await roll(id,[4,5,1,1]);assert.equal((await move(id,a,4)).ok,true);let g=await get(id);assert.ok(g.ownState.reached.includes('4')&&g.ownState.reached.includes('5'));assert.equal(g.turn.done,true);assert.equal((await move(id,a,11)).error,'GAME_TURN_DONE');await skip(id,b);await roll(id,[4,5,1,1]);assert.equal((await move(id,a,11)).ok,true);
 });
 await t.test('Fackel über Portal darf dessen Ausgang nutzen; Auswahl und Abbruch kosten nichts',async()=>{
  const id=await create();await seedState(db,id,a,{reached:['1'],torchUses:2});await roll(id,[4,5,1,1]);let g=await get(id);const opts=await rpc(a,'get_torch_options',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision});assert.ok(opts.actions.some(o=>o.middleCellId==='4'&&o.cellId==='11'));
  assert.equal((await move(id,a,11,{p_middle_cell_id:'4'})).ok,true);g=await get(id);assert.ok(['4','5','11'].every(v=>g.ownState.reached.includes(v)));assert.equal(g.ownState.torchUses,1);
 });
 await t.test('Verrückte Felder wählen nur aus dem eigenen Pool; pro Runde für alle gleich und stabil',async()=>{
  const id=await create();let g=await get(id),value=g.roundRequirements['6'];assert.ok([3,8,'doubles'].includes(value));for(let i=0;i<4;i++)assert.equal((await get(id,b)).roundRequirements['6'],value);
  for(const u of [a,b])await seedState(db,id,u,{reached:['5']});const dice=value===3?[1,2,1,1]:value===8?[4,4,1,1]:[1,1,1,1];await roll(id,dice);assert.equal((await move(id,a,6)).ok,true);assert.equal((await get(id,b)).roundRequirements['6'],value);assert.equal((await move(id,b,6)).ok,true);g=await get(id);assert.equal(g.round,2);assert.ok([3,8,'doubles'].includes(g.roundRequirements['6']));
  for(let i=0;i<30;i++){await db.query('update dungeon_games set round_index=round_index+1 where id=$1',[id]);assert.ok([3,8,'doubles'].includes((await get(id)).roundRequirements['6']));}
 });
 await t.test('Goldsack und Münze geben 2/1 Punkte; Bonusfeld bleibt optional und ohne Bossgruppen',async()=>{
  const id=await create();await seedState(db,id,a,{reached:['8']});await roll(id,[3,4,1,1]);await move(id,a,9);let g=await get(id);assert.equal(g.ownState.goldPoints,2);assert.equal(g.participants.find(p=>p.id===a.profile.id).points,2);await skip(id,b);await roll(id,[3,4,1,1]);await move(id,a,10);assert.equal((await get(id)).ownState.goldPoints,3);
  const id2=await create();await seedState(db,id2,a,{reached:['1','2','3','13'],monsterHits:{3:2,12:11}});await seedState(db,id2,b,{reached:['7'],monsterHits:{8:1}});await roll(id2,[4,4,2,2]);await move(id2,a,12);assert.equal((await get(id2)).finalRound,1);await move(id2,b,8);g=await get(id2,b);assert.equal(g.status,'finished');assert.ok(!g.ownState.reached.includes('12'));assert.equal(g.results.find(r=>r.playerId===b.profile.id).breakdown.bossBonusDiamonds,0);assert.equal(g.results.find(r=>r.playerId===b.profile.id).monstersDefeated,0);
 });
 await t.test('Zwei Boss-Erstbesieger erhalten je 6, keine zusätzlichen Gruppen; später nur Dreiergruppen',async()=>{
  const id=await create(users);for(const u of users)await seedState(db,id,u,{reached:['1','2','3'],monsterHits:{3:2,12:u===c?10:11}});await roll(id,[4,4,1,2]);await move(id,a,12);await move(id,b,12);await move(id,c,12);const g=await get(id);assert.equal(g.status,'finished');for(const u of [a,b]){const r=g.results.find(r=>r.playerId===u.profile.id);assert.equal(r.diamonds,6);assert.equal(r.breakdown.bossBonusDiamonds,0);assert.equal(r.won,true);}assert.equal(g.results.find(r=>r.playerId===c.profile.id).diamonds,3);
 });
 await t.test('Flexible Aufgaben: alle Arten, individuelle Erst-/Spätbelohnung und Erstbesieger-Aufgabe',async()=>{
  const d=modernFixture();d.rules.goals=[{...goalDefault(),type:'allType',fieldType:'goldCoin',reward:{first:5,later:2}},{...goalDefault(),type:'firstEnemies',cellIds:[3],reward:{first:4,later:1}}];const m=await publishFixture(db,a,'Aufgaben',d),id=await create(users,{},m);
  for(const u of users)await seedState(db,id,u,{reached:['9'],diamonds:0});await roll(id,[3,4,1,1]);await move(id,a,10);await move(id,b,10);assert.equal((await get(id)).ownState.taskRewards.special,5);assert.equal((await get(id,b)).ownState.taskRewards.special,5);await skip(id,c);await roll(id,[3,4,1,1]);await move(id,c,10);assert.equal((await get(id,c)).ownState.taskRewards.special,2);await skip(id,a);await skip(id,b);
  for(const u of users)await seedState(db,id,u,{reached:['2'],monsterHits:{3:1}});await roll(id,[4,4,1,1]);await move(id,b,3);await move(id,a,3);assert.equal((await get(id)).ownState.taskRewards.custom,4);assert.equal((await get(id,b)).ownState.taskRewards.custom,4);await skip(id,c);let g=await get(id,c);assert.equal(g.tasks.custom.blocked,true);await roll(id,[4,4,1,1]);await move(id,c,3);assert.equal((await get(id,c)).ownState.taskRewards.custom,undefined);
 });
 await t.test('Durchgehender Weg zählt nur persönlich erreichte Räume, Portal zählt mit',async()=>{
  const d=modernFixture();d.rules.goals=[{...goalDefault(),type:'connect',cellIds:[1,11],reward:{first:4,later:0}},goalDefault()];const m=await publishFixture(db,a,'Portalweg',d),id=await create([a],{},m);await seedState(db,id,a,{reached:['1','11']});let g=await get(id);assert.equal(g.tasks.special.completed,false);assert.equal(g.tasks.special.progress,2);
  await roll(id,[4,5,1,1]);await move(id,a,4);g=await get(id);assert.equal(g.ownState.taskRewards.special,4);assert.equal(g.tasks.special.completed,true);
 });
 await t.test('Fog: Starts +2, markierte Frontier +2, Fernglas dauerhaft +3 und Reload stabil',async()=>{
  const id=await create([a],{fog:true});let g=await get(id);assert.ok(g.visibleCells.includes('1')&&g.visibleCells.includes('3')&&g.visibleCells.includes('5'));assert.ok(!g.visibleCells.includes('6'));
  await seedState(db,id,a,{reached:['5'],pendingChests:['13']});g=await get(id);assert.ok(g.visibleCells.includes('7'));assert.ok(!g.visibleCells.includes('8'));const result=await rpc(a,'choose_game_powerup',{p_game_id:id,p_chest_cell_id:'13',p_state_revision:g.turn.ownRevision,p_powerup:'binocular',p_request_id:randomUUID()});assert.equal(result.ok,true);g=await get(id);assert.ok(g.visibleCells.includes('8'));assert.equal(g.ownState.visionRadius,3);assert.deepEqual((await get(id)).visibleCells,g.visibleCells);assert.ok(!g.turn.availablePowerups.includes('binocular'));
 });
 await t.test('Würfelsummen und Feldtipps sind getrennt; der Server prüft weiterhin auch ohne Tipps',async()=>{
  const id=await create([a],{diceHints:true,fieldHints:false,fog:true});await roll(id,[2,4,1,1]);const g=await get(id);assert.ok(g.turn.options.includes('6'));assert.equal(g.turn.actions,undefined);assert.equal((await move(id,a,3)).error,'GAME_CELL_UNREACHABLE');assert.equal((await move(id,a,1)).ok,true);
  const id2=await create([a],{diceHints:false,fieldHints:true});await roll(id2,[2,4,1,1]);const g2=await get(id2);assert.ok(g2.turn.actions.some(v=>v.cellId==='1'));assert.equal(g2.turn.options,undefined);
 });
 await t.test('Unzulässige Fackel und roter Abbruch verändern weder Falle noch Spielstand',async()=>{
  const id=await create();await seedState(db,id,b,{reached:['14'],torchUses:2,redUses:3});await roll(id,[1,1,1,5]);const before=(await get(id,b)).ownState;assert.equal((await move(id,b,16,{p_middle_cell_id:'15'})).error,'GAME_RED_CONFIRMATION');assert.deepEqual((await get(id,b)).ownState,before);assert.equal((await get(id,b)).traps.length,0);assert.equal((await move(id,b,16,{p_middle_cell_id:'15',p_use_red:true})).ok,true);let g=await get(id,b);assert.equal(g.ownState.torchUses,1);assert.equal(g.ownState.redUses,2);assert.equal(g.traps.length,1);
 });
 await t.test('Fackel sammelt Gold im Zwischenraum; Fallen sind nicht kostenlos überspringbar',async()=>{
  const id=await create();await seedState(db,id,a,{reached:['8'],torchUses:2});await roll(id,[3,4,1,1]);assert.equal((await move(id,a,10,{p_middle_cell_id:'9'})).ok,true);let g=await get(id);assert.equal(g.ownState.goldPoints,3);assert.equal(g.ownState.torchUses,1);
  const id2=await create();await seedState(db,id2,a,{reached:['14']});await seedState(db,id2,b,{reached:['14'],torchUses:2});await roll(id2,[4,5,1,1]);await move(id2,a,15);await skip(id2,b);await roll(id2,[2,4,1,1]);assert.equal((await move(id2,b,16,{p_middle_cell_id:'15'})).ok,true);g=await get(id2,b);assert.equal(g.ownState.lostLives,2);assert.ok(g.ownState.reached.includes('15')&&g.ownState.reached.includes('16'));
 });
 await t.test('Zielfeld, Diamantenziel und Nullbelohnung werden nur einmal vergeben',async()=>{
  const d=modernFixture();d.rules.goals=[{...goalDefault(),type:'reachFields',cellIds:[14],reward:{first:0,later:0}},{...goalDefault(),type:'collectDiamonds',diamonds:1,reward:{first:4,later:2}}];const m=await publishFixture(db,a,'Sammelziel',d),id=await create([a],{},m);await seedState(db,id,a,{reached:['11']});await roll(id,[4,5,1,1]);assert.equal((await move(id,a,14)).ok,true);let g=await get(id);assert.deepEqual(g.ownState.taskRewards,{special:0,custom:4});assert.equal(g.ownState.diamonds,5);await get(id);assert.equal((await get(id)).ownState.diamonds,5);
 });
 await t.test('Fernglas wird ohne Nebel nicht angeboten; alle Startfelder bleiben im Nebel sichtbar',async()=>{
  const id=await create([a]);await seedState(db,id,a,{pendingChests:['13']});let g=await get(id);assert.ok(!g.turn.availablePowerups.includes('binocular'));assert.equal((await rpc(a,'choose_game_powerup',{p_game_id:id,p_chest_cell_id:'13',p_state_revision:g.turn.ownRevision,p_powerup:'binocular',p_request_id:randomUUID()})).error,'GAME_POWERUP_UNAVAILABLE');
  const d=modernFixture();d.rooms.push({...d.rooms[0],id:18,x:100,y:100});d.nextId=19;const m=await publishFixture(db,a,'Zwei Starts',d),id2=await create([a],{fog:true},m);await seedState(db,id2,a,{reached:['5']});g=await get(id2);assert.ok(g.visibleCells.includes('18'));await roll(id2,[2,4,1,1]);assert.equal((await move(id2,a,18)).ok,true);
 });
 await t.test('Installationstest zeigt vollständig OK und neue Schlusswertung zählt Gold in Profilstatistik',async()=>{
  const checks=(await db.exec(await readFile(new URL('../supabase/migrations/017_check_game_rules.sql',import.meta.url),'utf8')))[0].rows;assert.equal(checks.length,6);assert.ok(checks.every(row=>row.ergebnis==='OK'));
  const id=await create([a]);await seedState(db,id,a,{reached:['3'],monsterHits:{3:2,12:11},goldPoints:3});await roll(id,[4,4,1,1]);await move(id,a,12);const g=await get(id),r=g.results[0];assert.equal(r.points,21);assert.equal(r.breakdown.goldPoints,3);const stats=(await rpc(a,'get_player_profile')).profile.stats;assert.ok(stats.gamesPlayed>0);
 });
 await t.test('Öffentliche Rollen können weder Zustände noch neue private Helfer direkt aufrufen',async()=>{
  assert.equal((await db.query("select has_table_privilege('anon','public.dungeon_game_trap_claims','select') permitted")).rows[0].permitted,false);assert.equal((await db.query("select has_function_privilege('anon','dungeon_private.reach_game_cell(public.dungeon_games,uuid,jsonb,public.dungeon_map_cells)','execute') permitted")).rows[0].permitted,false);
 });
 }finally{await db.close();}
});

test('Laufende v5-Partie und alte Befehle behalten nach dem Upgrade ihre Bedeutung',{timeout:120000},async()=>{
 const db=await createStabilityDatabase();try{
  const a=await register(db,'Altflo'),b=await register(db,'Altjoni'),map=await publishFixture(db,a,'Historische Mine',classicFixture());await installTestDice(db);
  const args={p_map_version_id:map.versionId,p_name:'Laufende Mine',p_settings:{maxPlayers:8,cards:'open',hints:true},p_password:'',p_request_id:randomUUID()},created=await userRpc(db,a,'create_game',args),id=created.gameId;
  await userRpc(db,b,'join_game',{p_game_id:id,p_password:'',p_request_id:randomUUID()});let g=(await userRpc(db,a,'get_game',{p_game_id:id})).game;await userRpc(db,a,'start_game',{p_game_id:id,p_expected_revision:g.revision,p_request_id:randomUUID()});for(const u of [a,b])await seedState(db,id,u,{reached:['3','4'],monsterHits:{5:1}});
  await forceDice(db,[4,4,1,2]);const rollArgs={p_game_id:id,p_round:1,p_request_id:randomUUID()},rolled=await userRpc(db,a,'roll_game_dice',rollArgs);const before=(await userRpc(db,a,'get_game',{p_game_id:id})).game;
  for(const name of ['014_editor_upgrade.sql','016_game_rules.sql'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}`,import.meta.url),'utf8'));
  assert.deepEqual(await userRpc(db,a,'create_game',args),created);assert.deepEqual(await userRpc(db,a,'roll_game_dice',rollArgs),rolled);g=(await userRpc(db,a,'get_game',{p_game_id:id})).game;assert.equal(g.rulesVersion,5);assert.deepEqual(g.ownState,before.ownState);assert.deepEqual(g.dice,before.dice);
  for(const u of [a,b]){g=(await userRpc(db,u,'get_game',{p_game_id:id})).game;assert.equal((await userRpc(db,u,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'5',p_use_red:false,p_request_id:randomUUID()})).ok,true);}
  const one=(await userRpc(db,a,'get_game',{p_game_id:id})).game,two=(await userRpc(db,b,'get_game',{p_game_id:id})).game;assert.equal(one.ownState.diamonds,9);assert.equal(two.ownState.diamonds,2);assert.equal(one.round,2);
  assert.equal((await newPlayGame(db,[a],{},map))!=null,true);
 }finally{await db.close();}
});
