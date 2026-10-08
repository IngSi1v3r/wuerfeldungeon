import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {analyzeAiTurn,actionKey} from '../web/js/games/ai.js';
import {ADVENTURERS} from '../web/js/games/adventurers.js';
import {createModel,cloneState,applyAction,legalActions,applyPowerup,simulatedPoints} from '../web/js/games/ai-simulation.js';
import {connections} from '../web/js/maps/model.js';
import {compileDocument,goalDefault} from '../web/js/maps/features.js';
import {soloFixture} from './helpers/solo-ai.mjs';
import {createAdventurerDatabase} from './helpers/adventurers.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,seedState} from './helpers/turns.mjs';
import {callRpc} from './helpers/database.mjs';
const doc=soloFixture(),definition={document:doc,rules:doc.rules,graph:connections(doc),allowedPowerups:doc.allowedPowerups};
function context(patch={}){return {gameId:'test',playerId:'bot',character:'warden',seat:0,redEvery:3,round:1,dice:[2,3,4,5],freeRed:true,canAct:true,canLoseLife:false,state:{reached:['1'],monsterHits:{},redUses:3,torchUses:0,axeUses:0,powerups:[],diamonds:0,lostLives:0},definition,actions:[{cellId:'2',redOnly:false}],torchActions:[],...patch};}
test('Zwei Folgerunden: legale Varianten, gemeinsame Würfelstichproben, reproduzierbare Bewertungen',()=>{
 const c=context({state:{reached:['1','2','3'],monsterHits:{},redUses:3,axeUses:2,powerups:[]},actions:[{cellId:'4',redOnly:false}]});
 const a=analyzeAiTurn(c),b=analyzeAiTurn(c);assert.deepEqual(a,b);assert.equal(a.depth,2);assert.ok(a.evaluated>0);assert.equal(a.candidates.length,2);assert.equal(a.selected,actionKey(a.action));assert.equal(a.action.useAxe,true);
 assert.equal(analyzeAiTurn(c,{depth:0}).depth,0);assert.ok(a.candidates.every(v=>Number.isFinite(v.score)&&Number.isFinite(v.forecast)));
 assert.equal(analyzeAiTurn(context({canAct:false})).action,null);
});
test('Charaktere gewichten Folgen unterschiedlich; nur Glücksritter hat Zufall; Lebensaufgabe bleibt optional',()=>{
 const values=ADVENTURERS.map(ch=>analyzeAiTurn(context({character:ch.id})));assert.equal(new Set(values.map(a=>a.candidates[0].score)).size,5);assert.ok(values.filter(a=>a.character!=='lucky').every(a=>a.candidates.every(c=>c.noise===0)));assert.ok(values.find(a=>a.character==='lucky').candidates.some(c=>c.noise!==0));
 const a=analyzeAiTurn(context({freeRed:false,round:2,canLoseLife:true,actions:[{cellId:'2',redOnly:true}]}));assert.ok(a.candidates.some(c=>c.kind==='lose_life'));assert.ok(a.candidates.some(c=>c.useRed));
 assert.ok(!analyzeAiTurn(context({canLoseLife:true})).candidates.some(c=>c.kind==='lose_life'));
});
test('Simulationsregeln: Pasch, Portal, Runenschaden, Fallen, Gruppen und Powerups',()=>{
 const d=soloFixture();d.rooms.push({id:6,type:'portal',x:0,y:8,w:4,h:4,number:6,start:true},{id:7,type:'portal',x:40,y:8,w:4,h:4,number:6},{id:8,type:'rune',x:0,y:12,w:4,h:4,number:7,runeEffect:'hits',runeHits:3},{id:9,type:'trap',x:4,y:12,w:4,h:4,number:8,trapKind:'diamonds',trapCost:2},{id:10,type:'doubleSum',x:8,y:12,w:4,h:4,number:6,start:true});
 d.rules.goals=[{...goalDefault(),type:'reachFields',cellIds:[6,7],reward:{first:3,later:1}},goalDefault()];const compiled=compileDocument(d),m=createModel(context({definition:{document:compiled,rules:compiled.rules,graph:connections(compiled)},traps:[{cellId:'9',activatedInRound:1,armed:true}]}));let s=cloneState({reached:[],monsterHits:{},redUses:3});
 assert.ok(!legalActions(m,s,[1,2,4,5],1).some(a=>a.cellId==='10'));assert.ok(legalActions(m,s,[3,3,1,4],1).some(a=>a.cellId==='10'));
 s=applyAction(m,s,{kind:'cell',cellId:'6'},1);assert.deepEqual(s.reached,['6','7']);assert.equal(s.diamonds,3);assert.equal(s.taskRewards.special,3);
 s=applyAction(m,s,{kind:'cell',cellId:'8'},2);assert.equal(s.monsterHits['5'],3);assert.ok(s.reached.includes('5'));assert.equal(s.diamonds,9);assert.ok(s.firstKills.includes('5'));assert.equal(simulatedPoints(m,s),27,'Erstbesieger erhält keine zusätzlichen Bossgruppen');
 s=applyAction(m,s,{kind:'cell',cellId:'9'},2);assert.equal(s.diamonds,7);
 const power=applyPowerup({...s,pendingChests:['2']},'extraLife');assert.equal(power.extraLives,3);assert.equal(power.diamonds,8);assert.equal(power.pendingChests.length,0);
});
test('Abenteurer-Server: Charaktere, Informationsgrenzen, angenommene Zugprotokolle und Ressourcen',async t=>{
 const db=await createAdventurerDatabase();try{
  const host=await register(db,'AdventurerFlo'),guest=await register(db,'AdventurerGast'),map=await publishFixture(db,host,'Abenteuermine',soloFixture());await installTestDice(db);await forceDice(db,[2,3,4,5]);
  const rpc=(name,args={})=>userRpc(db,host,name,args),create=async(settings={},count=2,aiOnly=true)=>(await rpc('create_solo_game',{p_map_version_id:map.versionId,p_name:'Probe',p_settings:{cards:'open',hints:true,fog:false,adventurers:['berserker','rival'],...settings},p_bot_count:count,p_red_every:3,p_ai_only:aiOnly,p_request_id:randomUUID()})).gameId;
  const args=(id,c,a,analysis={},request=randomUUID())=>({p_game_id:id,p_bot_id:c.playerId,p_round:c.round,p_state_revision:c.revision,p_kind:a.kind,p_cell_id:a.kind==='powerup'?String(c.pendingChest):a.cellId||null,p_middle_cell_id:a.middleCellId||null,p_use_red:Boolean(a.useRed),p_use_axe:Boolean(a.useAxe),p_powerup:a.powerup||null,p_request_id:request,p_analysis:analysis});
  await t.test('Charakterauswahl bleibt gespeichert, keine KI-Titel, alle Plätze verschieden markiert',async()=>{
   const id=await create(),g=(await rpc('get_game',{p_game_id:id})).game;assert.deepEqual(g.participants.map(p=>p.character),['berserker','rival']);assert.ok(g.participants.every(p=>!p.displayName.includes('KI')));assert.equal(new Set(g.participants.map(p=>p.markStyle)).size,2);assert.ok(g.participants.every(p=>p.color));
   const ctx=await rpc('get_ai_context',{p_game_id:id});assert.equal(ctx.bots[0].character,'berserker');assert.equal(ctx.bots[0].redEvery,3);assert.equal(ctx.bots[0].gameId,id);
   assert.equal((await userRpc(db,guest,'get_adventurer_journal',{p_game_id:id})).error,'GAME_HOST_ONLY');
  });
  let probe;
  await t.test('Zwei-Runden-Planung spielt komplette Partien; Logs sind idempotent, illegaler Vorschlag erzeugt keines',async()=>{
   const id=await create();probe=id;let replayArgs;
   for(let i=0;i<120;i++){
    const contexts=await rpc('get_ai_context',{p_game_id:id});if(contexts.status==='finished')break;assert.ok(contexts.bots.length>0);
    for(const c of contexts.bots){const analysis=c.canRoll?{action:{kind:'roll'}}:analyzeAiTurn(c),params=args(id,c,analysis.action,c.canRoll?{}:analysis);assert.ok(analysis.action);const before=cloneState(c.state);
     const answer=await rpc('perform_adventurer_action',params);assert.equal(answer.ok,true,JSON.stringify(answer));
     if(analysis.action.kind==='cell'){
      replayArgs=params;const projected=applyAction(createModel(c),before,analysis.action,c.round),actual=(await db.query('select state from dungeon_game_player_states where game_id=$1 and player_id=$2',[id,c.playerId])).rows[0].state;
      for(const k of ['reached','monsterHits','diamonds','redUses','torchUses','axeUses','taskRewards'])assert.deepEqual(actual[k]??(k==='monsterHits'||k==='taskRewards'?{}:0),projected[k]??(k==='monsterHits'||k==='taskRewards'?{}:0),`Regelparität ${k}`);
     }
     if(analysis.action.kind==='roll')break;
    }
   }
   const g=(await rpc('get_game',{p_game_id:id})).game;assert.equal(g.status,'finished');
   const logs=(await rpc('get_adventurer_journal',{p_game_id:id}));assert.ok(logs.decisions.length>10);assert.ok(logs.frames.length>10);assert.ok(logs.rolls.length>0);assert.ok(logs.decisions.filter(d=>d.kind==='cell').every(d=>d.analysis.depth===2));
   assert.equal((await rpc('perform_adventurer_action',replayArgs)).ok,true);assert.equal((await rpc('get_adventurer_journal',{p_game_id:id})).decisions.length,logs.decisions.length);
   const tail=await rpc('get_adventurer_journal',{p_game_id:id,p_after_frame:logs.frames.at(-1).id,p_after_decision:logs.decisions.at(-1).id,p_after_roll:logs.rolls.at(-1).id});assert.equal(tail.frames.length+tail.decisions.length+tail.rolls.length,0);
   assert.equal((await db.query("select count(*)::int n from dungeon_private.player_sessions s join dungeon_players p on p.id=s.player_id where p.is_bot")).rows[0].n,0);
  });
  await t.test('Nebel und verdeckte Karten geben keine fremden Fortschritte preis',async()=>{
   const id=await create({cards:'hidden',fog:true});let c=(await rpc('get_ai_context',{p_game_id:id})).bots[0];await rpc('perform_adventurer_action',args(id,c,{kind:'roll'}));const ctx=await rpc('get_ai_context',{p_game_id:id});c=ctx.bots[0];assert.equal(c.opponents.length,0);assert.ok(!c.definition.document.rooms.some(r=>String(r.id)==='5'));
   assert.equal((await rpc('perform_adventurer_action',args(id,c,{kind:'cell',cellId:'5'}))).ok,false);assert.equal((await rpc('get_adventurer_journal',{p_game_id:id})).decisions.length,0);
   await db.query("update dungeon_games set settings=settings||'{\"cards\":\"open\"}'::jsonb where id=$1",[id]);assert.equal((await rpc('get_ai_context',{p_game_id:id})).bots[0].opponents.length,1);
  });
  await t.test('Freiwilliges Leben bei nur Rot oder Fackel: Ressourcen unverändert, Zug beendet, Wiederholung genau einmal',async()=>{
   const id=await create({adventurers:[]},0,false);await db.query('update dungeon_games set round_index=2 where id=$1',[id]);await forceDice(db,[1,1,1,4]);await rpc('roll_game_dice',{p_game_id:id,p_round:2,p_request_id:randomUUID()});let g=(await rpc('get_game',{p_game_id:id})).game;assert.equal(g.turn.standardPossible,false);assert.equal(g.turn.redPossible,true);
   const req=randomUUID(),params={p_game_id:id,p_round:2,p_state_revision:g.turn.ownRevision,p_action:'lose_life',p_cell_id:null,p_use_red:false,p_request_id:req};assert.equal((await rpc('play_game_action',params)).ok,true);assert.equal((await rpc('play_game_action',params)).ok,true);g=(await rpc('get_game',{p_game_id:id})).game;assert.equal(g.ownState.lostLives,1);assert.equal(g.ownState.redUses,3);assert.equal(g.round,3);
   await forceDice(db,[2,3,4,5]);await rpc('roll_game_dice',{p_game_id:id,p_round:3,p_request_id:randomUUID()});g=(await rpc('get_game',{p_game_id:id})).game;assert.equal((await rpc('play_game_action',{...params,p_round:3,p_state_revision:g.turn.ownRevision,p_request_id:randomUUID()})).error,'GAME_MOVE_AVAILABLE');
   const torchId=await create({adventurers:[]},0,false);await seedState(db,torchId,host,{reached:['1'],redUses:0,torchUses:2,powerups:['torch']});await forceDice(db,[3,4,4,6]);await rpc('roll_game_dice',{p_game_id:torchId,p_round:1,p_request_id:randomUUID()});g=(await rpc('get_game',{p_game_id:torchId})).game;assert.equal(g.turn.standardPossible,false);assert.equal(g.turn.torchPossible,true);assert.equal(g.turn.canLoseLife,true);
   assert.equal((await rpc('play_game_action',{...params,p_game_id:torchId,p_round:1,p_state_revision:g.turn.ownRevision,p_request_id:randomUUID()})).ok,true);g=(await rpc('get_game',{p_game_id:torchId})).game;assert.equal(g.ownState.torchUses,2);assert.equal(g.ownState.lostLives,1);
  });
  await t.test('Update lässt Daten und Analyse unverändert und ist wiederholbar',async()=>{
   const count=(await db.query('select count(*)::int n from dungeon_private.adventurer_decisions')).rows[0].n;await db.exec(await readFile(new URL('../supabase/migrations/034_adventurers.sql',import.meta.url),'utf8'));assert.equal((await db.query('select count(*)::int n from dungeon_private.adventurer_decisions')).rows[0].n,count);assert.equal((await callRpc(db,'app_status')).adventurerVersion,2);assert.equal((await callRpc(db,'app_status')).releaseVersion,'1.2.0');assert.equal((await rpc('get_game',{p_game_id:probe})).game.status,'finished');const checks=(await db.exec(await readFile(new URL('../supabase/migrations/035_check_adventurers.sql',import.meta.url),'utf8')))[0].rows;assert.equal(checks.length,7);assert.ok(checks.every(c=>c.ergebnis==='OK'));
  });
 }finally{await db.close();}
});
