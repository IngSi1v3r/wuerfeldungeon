import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {chooseAiAction,choosePowerup,requirementProbability} from '../web/js/games/ai.js';
import {C3,C4,redDiceFactor,adventureRating,mapBenchmarks} from '../web/js/games/adventure-rating.js';
import {diceCombinations} from '../web/js/games/rules.js';
import {callRpc} from './helpers/database.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,seedState,newPlayGame} from './helpers/turns.mjs';
import {createSoloDatabase,soloFixture} from './helpers/solo-ai.mjs';

const definition=()=>({document:soloFixture(),rules:soloFixture().rules,allowedPowerups:soloFixture().allowedPowerups,graph:[['1','2'],['2','3'],['3','4'],['4','5']]});
const context=(patch={})=>({playerId:'bot',round:1,canAct:true,canLoseLife:false,state:{reached:['1'],monsterHits:{},redUses:3,axeUses:0,torchUses:0,powerups:[]},definition:definition(),actions:[{cellId:'2',redOnly:false}],...patch});
test('Abenteuerwertung: Würfel-Erwartungswerte, gewichtete Verhältnisse und Präzision',()=>{
 for(const [red,want] of [[false,C3],[true,C4]]){
  let combinations=0,total=0;
  for(let a=1;a<=6;a++)for(let b=1;b<=6;b++)for(let c=1;c<=6;c++)for(let d=1;d<=(red?6:1);d++){total++;combinations+=diceCombinations([a,b,c,d],red).length;}
  assert.ok(Math.abs(combinations/total-want)<1e-12);
 }
 assert.equal(adventureRating({points:100,expectedPoints:100,effort:100,rounds:100}),100);
 assert.ok(Math.abs(redDiceFactor(4)-521/371)<1e-12);
 const before=adventureRating({points:50,expectedPoints:80,effort:80,rounds:100,redEvery:4});
 assert.ok(adventureRating({points:51,expectedPoints:80,effort:80,rounds:100,redEvery:4})>before);
 assert.equal(adventureRating({points:0,expectedPoints:0,effort:1,rounds:1}),null);
 assert.ok(requirementProbability(['7'])>requirementProbability(['12']));
});
test('KI: wählt aus legalen Aktionen, greift an, verwendet Axt und löst Schatzkisten',()=>{
 const c=context({state:{reached:['1','2','3'],monsterHits:{4:1},axeUses:2},actions:[{cellId:'4',redOnly:false}]});
 const move=chooseAiAction(c);assert.equal(move.cellId,'4');assert.equal(move.useAxe,false,'Kein Doppelhit für den letzten Treffer');
 c.state.monsterHits={};assert.equal(chooseAiAction(c).useAxe,true);
 const power=context({pendingChest:'2',availablePowerups:['torch','redDice','extraLife']});assert.equal(chooseAiAction(power).kind,'powerup');assert.equal(choosePowerup(power),'torch');
 assert.equal(chooseAiAction(context({actions:[],canLoseLife:true})).kind,'lose_life');
 assert.equal(chooseAiAction(context({canAct:false})),null);
 assert.equal(chooseAiAction(context({actions:[{cellId:'999'}],canLoseLife:true})).kind,'lose_life','Unbekannte Nebelräume werden nicht bewertet');
});
test('Einzelspiel & KI: autorisierte Züge, Runden, Ressourcen, Statistiken und Bestenlisten',async t=>{
 const db=await createSoloDatabase();
 try{
  const a=await register(db,'SoloFlo'),b=await register(db,'SoloGast'),map=await publishFixture(db,a,'KI Testmine',soloFixture());
  const rpc=(name,params={})=>userRpc(db,a,name,params),settings={cards:'open',hints:true,fog:false};
  const create=(bots=0,q=1,testOnly=false,req=randomUUID())=>rpc('create_solo_game',{p_map_version_id:map.versionId,p_name:'Einzelmine',p_settings:settings,p_bot_count:bots,p_red_every:q,p_ai_only:testOnly,p_request_id:req});
  const get=async id=>(await rpc('get_game',{p_game_id:id})).game;
  await installTestDice(db);
  await t.test('Keine Lobby, sofortiger Spielstart, wiederholte Anfragen legen nur ein Spiel an',async()=>{
   const req=randomUUID(),r=await create(0,3,false,req);assert.equal(r.ok,true);const g=await get(r.gameId);
   assert.equal(g.status,'playing');assert.equal(g.playerCount,1);assert.equal(g.mode,'solo');assert.equal(g.turn.canRoll,true);
   assert.equal((await create(0,3,false,req)).gameId,g.id);
   assert.equal((await create(1,3,false,req)).error,'GAME_REQUEST_INVALID');
   assert.equal((await create(1,1,true)).ok,true,'Auch eine einzelne KI kann autonom zu Vergleichszwecken spielen');
   assert.ok(!(await rpc('list_games')).lobbies.some(x=>x.id===g.id));
   assert.equal((await userRpc(db,b,'join_game',{p_game_id:g.id,p_password:'',p_request_id:randomUUID()})).ok,false);
   for(const [round,want] of [[1,true],[2,false],[3,false],[4,true]]){
    await db.query('update dungeon_games set round_index=$2 where id=$1',[g.id,round]);
    const actual=await get(g.id);assert.equal(actual.turn.freeRed,want);assert.equal(actual.turn.canRoll,true,'Rotwürfel-Takt ändert nicht wer würfelt');
   }
  });
  await t.test('Roter Würfel ist in Sperrrunden optional und wird genau einmal verbraucht',async()=>{
   const r=await create(0,3),id=r.gameId;await db.query('update dungeon_games set round_index=2 where id=$1',[id]);
   await forceDice(db,[1,1,1,4]);assert.equal((await rpc('roll_game_dice',{p_game_id:id,p_round:2,p_request_id:randomUUID()})).ok,true);
   let g=await get(id);assert.equal(g.turn.actions.find(x=>x.cellId==='1').redOnly,true);
   const req=randomUUID(),args={p_game_id:id,p_round:2,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'1',p_use_red:true,p_request_id:req};
   assert.equal((await rpc('play_game_action',args)).ok,true);assert.equal((await rpc('play_game_action',args)).ok,true);
   g=await get(id);assert.equal(g.ownState.redUses,2);assert.equal(g.round,3);
  });
  let testGame;
  await t.test('KI gegen KI läuft vollständig ohne menschliche Teilnahme; gleiche Runde teilt Erstbelohnung',async()=>{
   const id=(await create(2,0,true)).gameId;testGame=id;let g=await get(id);assert.equal(g.spectator,true);assert.equal(g.playerCount,2);assert.ok(g.participants.every(p=>p.isBot));
   assert.equal((await userRpc(db,b,'get_ai_context',{p_game_id:id})).error,'GAME_HOST_ONLY');
   assert.equal((await userRpc(db,b,'get_game',{p_game_id:id})).error,'GAME_NOT_MEMBER');
   const botArg=(c,action,req=randomUUID())=>({p_game_id:id,p_bot_id:c.playerId,p_round:c.round,p_state_revision:c.revision,p_kind:action.kind,p_cell_id:action.kind==='powerup'?String(c.pendingChest):action.cellId||null,p_middle_cell_id:action.middleCellId||null,p_use_red:Boolean(action.useRed),p_use_axe:Boolean(action.useAxe),p_powerup:action.powerup||null,p_request_id:req});
   for(let step=0;step<120;step++){
    const contexts=await rpc('get_ai_context',{p_game_id:id});if(contexts.status==='finished')break;
    assert.ok(contexts.bots.length>0,`KI bleibt nicht stehen: Runde ${contexts.round}`);
    await forceDice(db,[2,3,4,5]);
    for(const c of contexts.bots){const action=c.canRoll?{kind:'roll'}:chooseAiAction(c);assert.ok(action);const res=await rpc('perform_ai_action',botArg(c,action));assert.equal(res.ok,true,JSON.stringify(res));if(action.kind==='roll')break;}
   }
   g=await get(id);assert.equal(g.status,'finished');assert.equal(g.results.length,2);assert.ok(g.results.every(r=>r.adventureRating!=null));
   assert.equal((await db.query("select count(*)::int n from dungeon_private.player_sessions s join dungeon_players p on p.id=s.player_id where p.is_bot")).rows[0].n,0,'Keine dauerhaften KI-Sitzungen');
   assert.equal((await db.query('select count(*)::int n from dungeon_private.marking_credits where game_id=$1',[id])).rows[0].n,0);
   assert.ok(!(await rpc('list_game_history')).games.some(x=>x.id===id));
   assert.ok((await rpc('list_ai_experiments')).games.some(x=>x.id===id));
   const replay=await rpc('get_game_replay',{p_game_id:id});assert.ok(replay.players.every(p=>p.frames.length>2&&p.isBot&&p.markStyle));
   assert.equal((await userRpc(db,b,'get_game_replay',{p_game_id:id})).error,'GAME_NOT_MEMBER');
  });
  await t.test('Ein menschlicher Spieler plus KI wird normal gewertet; SQL & JS stimmen überein',async()=>{
   const id=(await create(1,2)).gameId;
   for(const p of (await get(id)).participants)await seedState(db,id,{profile:{id:p.id}},{reached:['1','2','3','4','5'],monsterHits:{4:2,5:3},diamonds:10,firstKills:['4','5']});
   await db.query("update dungeon_games set final_round=10,round_index=10 where id=$1",[id]);await db.query('select dungeon_private.finalize_game($1)',[id]);
   const g=await get(id),human=g.results.find(r=>!r.isBot),benchmark=mapBenchmarks(definition(),2);
   assert.ok(Math.abs(human.ratingDetails.expectedPoints-benchmark.expectedPoints)<1e-8);assert.equal(human.ratingDetails.effort,benchmark.effort);
   assert.ok(Math.abs(human.adventureRating-adventureRating({points:human.points,rounds:g.round,effort:benchmark.effort,expectedPoints:benchmark.expectedPoints,redEvery:2}))<1e-8);
   const list=await rpc('list_highscores',{p_map_version_id:map.versionId,p_game_id:id});assert.equal(list.total,1);assert.equal(list.personal.rank,1);assert.equal(list.entries[0].opponents,1);
   assert.equal((await rpc('list_highscores',{p_map_version_id:map.versionId,p_opponents:0})).total,0);
   assert.equal((await db.query('select count(*)::int n from dungeon_private.marking_credits where game_id=$1',[id])).rows[0].n,1);
   assert.ok((await rpc('get_player_profile')).profile.stats.gamesPlayed>0);
  });
  await t.test('Mehrspieler erhält ebenfalls Abenteuerwertung; gleiche echte Werte teilen den Rang',async()=>{
   const id=await newPlayGame(db,[a,b],{},map);
   for(const p of [a,b])await seedState(db,id,p,{diamonds:12,firstKills:['4','5']});
   await db.query('select dungeon_private.finalize_game($1)',[id]);
   const list=await rpc('list_highscores',{p_map_version_id:map.versionId});assert.equal(list.total,3);
   const same=list.entries.filter(e=>e.gameId===id);assert.equal(same.length,2);assert.equal(same[0].rank,same[1].rank);
   assert.ok((await rpc('list_highscore_maps')).maps.some(m=>m.versionId===map.versionId&&m.entries===3));
  });
  await t.test('Migration ist wiederholbar und erhält Ergebnisse und gespeicherte Formelwerte',async()=>{
   const before=(await db.query('select * from dungeon_private.adventure_scores order by game_id,player_id')).rows;
   await db.exec(await readFile(new URL('../supabase/migrations/032_solo_ai_highscores.sql',import.meta.url),'utf8'));
   assert.deepEqual((await db.query('select * from dungeon_private.adventure_scores order by game_id,player_id')).rows,before);
   assert.equal((await callRpc(db,'app_status')).highscoreVersion,1);assert.equal((await callRpc(db,'app_status')).soloAIVersion,1);
   const checks=(await db.exec(await readFile(new URL('../supabase/migrations/033_check_solo_ai_highscores.sql',import.meta.url),'utf8')))[0].rows;
   assert.equal(checks.length,7);assert.ok(checks.every(c=>c.ergebnis==='OK'));
  });
  await t.test('Nebelkontext und illegale KI-Züge bleiben begrenzt; Pause hält die KI an',async()=>{
   const id=(await create(1,2)).gameId,bot=(await get(id)).participants.find(p=>p.isBot);
   await db.query("update dungeon_games set settings=settings||'{\"fog\":true,\"hints\":false,\"fieldHints\":false}'::jsonb where id=$1",[id]);
   await forceDice(db,[2,3,4,5]);await rpc('roll_game_dice',{p_game_id:id,p_round:1,p_request_id:randomUUID()});
   const c=(await rpc('get_ai_context',{p_game_id:id})).bots.find(c=>c.playerId===bot.id);assert.ok(c.canAct);assert.ok(c.actions.length);
   assert.ok(!c.definition.document.rooms.some(r=>String(r.id)==='5'),'Verdeckter Boss gelangt nicht in die KI-Heuristik');
   assert.ok(!c.definition.graph.some(edge=>edge.includes('5')));
   const args={p_game_id:id,p_bot_id:bot.id,p_round:1,p_state_revision:c.revision,p_kind:'cell',p_cell_id:'5',p_middle_cell_id:null,p_use_red:false,p_use_axe:false,p_powerup:null,p_request_id:randomUUID()};
   assert.equal((await rpc('perform_ai_action',args)).error,'GAME_CELL_UNREACHABLE');
   assert.equal((await userRpc(db,b,'perform_ai_action',args)).error,'GAME_HOST_ONLY');
   const g=await get(id);assert.equal((await rpc('manage_game',{p_game_id:id,p_action:'pause',p_expected_revision:g.revision,p_request_id:randomUUID()})).ok,true);
   assert.equal((await rpc('get_ai_context',{p_game_id:id})).bots.length,0);
   assert.equal((await rpc('perform_ai_action',{...args,p_cell_id:'1',p_request_id:randomUUID()})).error,'GAME_PAUSED');
   assert.equal((await db.query('select count(*)::int n from dungeon_private.player_sessions s join dungeon_players p on p.id=s.player_id where p.is_bot')).rows[0].n,0);
  });
 }finally{await db.close();}
});
