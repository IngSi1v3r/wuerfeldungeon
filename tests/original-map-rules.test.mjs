import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {compileDocument,goalDefault,goalText,upgradeDocument} from '../web/js/maps/features.js';
import {emptyDocument,connections} from '../web/js/maps/model.js';
import {diceCombinations,requirementLabel} from '../web/js/games/rules.js';
import {TestGame} from '../web/js/games/test-engine.js';
import {createShopDatabase} from './helpers/shop.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {modernFixture} from './helpers/game-upgrade.mjs';

const field=(id,type,x,y,number,extra={})=>({id,type,x,y,w:4,h:4,number,start:false,dimmed:false,...extra});
function fixture(){
 const d=upgradeDocument(emptyDocument());
 d.rooms=[field(1,'normal',0,0,5,{start:true}),field(2,'normal',4,0,7,{dimmed:true}),
  field(3,'boss',8,0,null,{w:16,h:8,name:'Bär',hits:12,attacks:[{number:8,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}),
  field(4,'doubleSum',0,4,6),field(5,'rune',0,8,9),field(6,'normal',4,4,5),field(7,'normal',4,8,6)];
 d.rules.goals=[goalDefault(),goalDefault()];d.nextId=8;
 return d;
}
test('Bestimmter Pasch unterscheidet Summe, fremden Pasch und passenden Pasch',()=>{
 assert.ok(!diceCombinations([2,4,5,6],true,true).includes('doubles:6'));
 assert.ok(!diceCombinations([2,2,4,5],true,true).includes('doubles:6'));
 assert.ok(diceCombinations([3,3,1,5],false,true).includes('doubles:6'));
 assert.ok(!diceCombinations([3,1,2,3],false,true).includes('doubles:6'));
 assert.ok(diceCombinations([3,1,2,3],true,true).includes('doubles:6'));
 assert.deepEqual(diceCombinations([2,4,4,5]),['6','8','doubles']);
 assert.equal(requirementLabel('doubles:6'),'3 + 3 (Pasch)');
 const d=compileDocument(fixture()),g=new TestGame({document:d,rules:d.rules,graph:connections(d)});
 g.state.reached=['1'];g.phase='choosing';g.dice=[2,2,4,5];assert.ok(!g.actions().some(a=>a.cellId==='4'));
 assert.throws(()=>g.play(4));g.dice=[3,3,1,5];g.play(4);assert.ok(g.reached(4));
});
test('Bossgrau benötigt einen offenen Kontakt, Runen funktionieren aus der Ferne',()=>{
 const d=fixture(),c=compileDocument(d);assert.ok(c.rules.unlocks.some(u=>u.sourceCellId===2&&u.targetCellId===3&&u.number===7));
 assert.ok(c.rules.unlocks.some(u=>u.sourceCellId===5&&u.targetCellId===3&&u.number===9));
 d.closedDoors['2:3']=true;const closed=compileDocument(d);assert.ok(!closed.rules.unlocks.some(u=>u.sourceCellId===2));
});
test('Lokaler Testmodus vergibt 5-von-6-Bonus einmalig, alte Aufgaben benötigen weiterhin alle',()=>{
 const d=fixture();d.rooms.push(field(8,'normal',0,12,4));
 d.rules.goals=[{...goalDefault(),type:'reachFields',cellIds:[1,2,4,5,6,7],requiredCount:5},goalDefault()];
 const c=compileDocument(d),g=new TestGame({document:c,rules:c.rules,graph:connections(c)});
 for(const id of [1,2,4,5])g.play(id,{cheat:true});assert.equal(g.state.diamonds,0);
 g.play(6,{cheat:true});assert.equal(g.state.diamonds,3);g.play(7,{cheat:true});assert.equal(g.state.diamonds,3);
 assert.match(goalText(c.rules.goals[0],c.rooms),/5 von 6/);
 delete c.rules.goals[0].requiredCount;const old=new TestGame({document:c,rules:c.rules,graph:connections(c)});
 for(const id of [1,2,4,5,6])old.play(id,{cheat:true});assert.equal(old.state.diamonds,0);
 old.play(7,{cheat:true});assert.equal(old.state.diamonds,3);
});

test('0.10.2 PostgreSQL: Veröffentlichung, Pasch, Bossgrau, Teilziele und gemeinsame Monsterkombination',{timeout:120000},async t=>{
 const db=await createShopDatabase();
 try{
  for(const f of ['020_round_two.sql','022_print_and_cosmetics.sql','024_original_map_rules.sql'])await db.exec(await readFile(new URL(`../supabase/migrations/${f}`,import.meta.url),'utf8'));
  const a=await register(db,'PaschFlo'),b=await register(db,'PaschJoni');
  const migration=await readFile(new URL('../supabase/migrations/024_original_map_rules.sql',import.meta.url),'utf8');await db.exec(migration);
  const rpc=(u,n,p={})=>userRpc(db,u,n,p),report=async d=>(await db.query('select dungeon_private.map_report($1::jsonb) r',[JSON.stringify(d)])).rows[0].r;
  const map=await publishFixture(db,a,'Paschmine',fixture());
  async function game(docMap=map){const r=await rpc(a,'create_game',{p_map_version_id:docMap.versionId,p_name:'Regeltest',p_settings:{maxPlayers:4,cards:'open',hints:true},p_password:'',p_request_id:randomUUID()});assert.equal(r.ok,true);const id=r.gameId;
   assert.equal((await rpc(b,'join_game',{p_game_id:id,p_password:'',p_request_id:randomUUID()})).ok,true);
   const g=(await rpc(a,'get_game',{p_game_id:id})).game;assert.equal((await rpc(a,'start_game',{p_game_id:id,p_expected_revision:g.revision,p_request_id:randomUUID()})).ok,true);return id;}
  const id=await game();
  async function round(dice,patch={}){await db.query("update dungeon_games set phase='choosing',round_index=1,roller_id=$2,dice=$3::jsonb where id=$1",[id,a.profile.id,JSON.stringify(dice)]);
   await db.query("update dungeon_game_player_states set last_completed_round=0,state=state||$2::jsonb where game_id=$1",[id,JSON.stringify({reached:['1'],monsterHits:{},redUses:3,torchUses:2,...patch})]);}
  async function actions(user=b,torch=false){return (await db.query(`select dungeon_private.${torch?'game_torch_actions':'game_actions'}(g,$2,s.state) r from dungeon_games g join dungeon_game_player_states s on s.game_id=g.id and s.player_id=$2 where g.id=$1`,[id,user.profile.id])).rows[0].r;}
  async function move(user,cell,{red=false,middle=null}={}){const s=(await db.query('select revision from dungeon_game_player_states where game_id=$1 and player_id=$2',[id,user.profile.id])).rows[0];return rpc(user,'play_game_action',{p_game_id:id,p_round:1,p_state_revision:s.revision,p_action:'cell',p_cell_id:String(cell),p_middle_cell_id:middle,p_use_red:red,p_use_axe:false,p_request_id:randomUUID()});}
  await t.test('Migration zweimal möglich; keine Spieler oder veröffentlichte Karten verändert',async()=>{
   assert.equal((await rpc(a,'get_player_profile')).profile.id,a.profile.id);
   assert.equal((await db.query('select definition from dungeon_map_cells where version_id=$1 and cell_id=$2',[map.versionId,'4'])).rows[0].definition.type,'doubleSum');
   assert.equal((await report(fixture())).errors.length,0);
   const compiled=(await report(fixture())).rules;assert.ok(compiled.unlocks.some(u=>u.sourceCellId===2&&u.targetCellId===3));
   const d=fixture();d.closedDoors['2:3']=true;assert.ok((await report(d)).errors.some(e=>e.cellId==='2'));
  });
  await t.test('Falsche Summe / falscher Pasch abgelehnt; richtiger Pasch mit Würfelrechten',async()=>{
   for(const dice of [[2,4,5,6],[2,2,4,5]]){await round(dice);assert.ok(!(await actions()).some(x=>x.cellId==='4'));assert.equal((await move(b,4)).error,'GAME_NUMBER_MISMATCH');}
   await round([3,1,2,3]);assert.equal((await actions(b)).find(x=>x.cellId==='4').redOnly,true);assert.equal((await actions(a)).find(x=>x.cellId==='4').redOnly,false);
   assert.equal((await move(b,4)).error,'GAME_RED_CONFIRMATION');assert.equal((await move(b,4,{red:true})).ok,true);
   assert.equal((await db.query('select state from dungeon_game_player_states where game_id=$1 and player_id=$2',[id,b.profile.id])).rows[0].state.redUses,2);
   await round([3,1,2,3],{redUses:0});assert.ok(!(await actions(b)).some(x=>x.cellId==='4'));
  });
  await t.test('Grauer Zwischenraum aktiviert Bossangriff, Fackel verlangt passenden Pasch am Ziel',async()=>{
   await round([3,4,1,6]);assert.ok((await actions(a,true)).some(x=>x.cellId==='3'&&x.middleCellId==='2'));
   await round([2,2,4,5],{reached:['6']});assert.ok(!(await actions(a,true)).some(x=>x.cellId==='4'));
   await round([3,3,1,5],{reached:['6']});assert.ok((await actions(a,true)).some(x=>x.cellId==='4'));
  });
  await t.test('Ungültige Paschsumme und unrealistische Teilzielzahl können nicht gespeichert / veröffentlicht werden',async()=>{
   for(const n of [3,7,'doubles']){const d=fixture();d.rooms[3].number=n;assert.equal((await db.query('select dungeon_private.map_document_valid($1::jsonb) r',[JSON.stringify(d)])).rows[0].r,false);}
   const d=fixture();d.rules.goals[0]={...goalDefault(),type:'reachFields',cellIds:[1,2],requiredCount:3};assert.ok((await report(d)).errors.some(e=>e.message.includes('nur 2')));
   for(const n of [0,1.5,'2']){d.rules.goals[0].requiredCount=n;assert.equal((await db.query('select dungeon_private.map_document_valid($1::jsonb) r',[JSON.stringify(d)])).rows[0].r,false);}
  });
  await t.test('5 von 6: Fortschritt, Belohnung und alle Ziel-IDs bleiben erhalten',async()=>{
   const d=fixture();d.rules.goals[0]={...goalDefault(),type:'reachFields',cellIds:[1,2,4,5,6,7],requiredCount:5};const m=await publishFixture(db,a,'Teilziel',d),gid=await game(m);
   await db.query("update dungeon_games set round_index=1 where id=$1",[gid]);
   const progress=async reached=>(await db.query('select dungeon_private.task_progress(g,$2::jsonb,$3) r from dungeon_games g where id=$1',[gid,JSON.stringify({reached}), 'special'])).rows[0].r;
   let p=await progress(['1','2','4','5']);assert.equal(p.total,5);assert.equal(p.targetCount,6);assert.equal(p.completed,false);
   p=await progress(['1','2','4','5','6']);assert.equal(p.completed,true);assert.equal(p.cellIds.length,6);
   const s=(await db.query('select dungeon_private.award_game_tasks(g,$2,$3::jsonb) r from dungeon_games g where id=$1',[gid,a.profile.id,JSON.stringify({reached:['1','2','4','5','6'],diamonds:0})])).rows[0].r;
   assert.equal(s.taskRewards.special,3);assert.equal(s.diamonds,3);
   assert.equal((await db.query('select dungeon_private.award_game_tasks(g,$2,$3::jsonb) r from dungeon_games g where id=$1',[gid,a.profile.id,JSON.stringify(s)])).rows[0].r.diamonds,3);
  });
  await t.test('Gegnerkombination: Erstbelohnung trotz fremder einzelner Erstbesieger; Gleichrunde und spätere Belohnung',async()=>{
   const d=modernFixture();d.rules.goals[1]={...goalDefault(),type:'defeatEnemies',cellIds:[3,12],reward:{first:5,later:2}};
   const m=await publishFixture(db,a,'Gegnerkombination',d),gid=await game(m);
   await db.query('update dungeon_games set round_index=4 where id=$1',[gid]);
   await db.query('insert into dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values($1,$2,$3,$4,2)',[gid,m.versionId,'3',b.profile.id]);
   const award=async(u,reached,firstKills=[])=>(await db.query('select dungeon_private.award_game_tasks(g,$2,$3::jsonb) r from dungeon_games g where id=$1',[gid,u.profile.id,JSON.stringify({reached,firstKills,diamonds:0})])).rows[0].r;
   assert.equal((await award(a,['3'])).taskRewards,undefined);
   assert.equal((await award(a,['3','12'])).taskRewards.custom,5);
   assert.equal((await award(b,['3','12'],['3'])).taskRewards.custom,5);
   await db.query('update dungeon_games set round_index=5 where id=$1',[gid]);assert.equal((await award(b,['3','12'],['3'])).taskRewards.custom,2);
  });
 }finally{await db.close();}
});
