import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {compileDocument,goalDefault} from '../web/js/maps/features.js';
import {connections} from '../web/js/maps/model.js';
import {TestGame} from '../web/js/games/test-engine.js';
import {activeAttacks} from '../web/js/games/rules.js';
import {STARTER_MARKINGS} from '../web/js/markings.js';
import {STARTER_BACKGROUNDS} from '../web/js/cosmetics.js';
import {createShopDatabase} from './helpers/shop.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {newPlayGame,installTestDice,forceDice,seedState} from './helpers/turns.mjs';
import {runeHitsFixture,runeHitsMigration} from './helpers/rune-hits.mjs';

const definition=d=>({document:d,rules:d.rules,graph:connections(d),allowedPowerups:d.allowedPowerups});
test('Trefferrunen ersetzen die automatische Bosszahl, normale Runen und graue Felder bleiben erhalten',()=>{
 const d=runeHitsFixture();assert.deepEqual(d.rules.bossHits,[{sourceCellId:2,targetCellId:5,hits:3},{sourceCellId:3,targetCellId:5,hits:3}]);
 assert.deepEqual(d.rules.unlocks,[{sourceCellId:6,targetCellId:5,number:11}]);
 assert.deepEqual(activeAttacks(d.rooms[4],d.rules,{reached:['2']}),['9']);
 assert.deepEqual(activeAttacks(d.rooms[4],d.rules,{reached:['6']}),['9','11']);
 const old=runeHitsFixture();old.rooms[1].runeEffect='unlock';const before=compileDocument(old);
 assert.ok(before.rooms[4].attacks.some(a=>a.number===6&&a.state==='locked'));
 before.rooms[1].runeEffect='hits';const next=compileDocument(before);
 assert.ok(!next.rooms[4].attacks.some(a=>a.number===6));assert.deepEqual(compileDocument(next),next);
 const shared=runeHitsFixture();shared.rooms[5].number=6;shared.rules.unlocks=[{sourceCellId:2,targetCellId:5,number:6}];shared.rooms[4].attacks.push({number:6,state:'locked'});
 assert.ok(compileDocument(shared).rooms[4].attacks.some(a=>a.number===6&&a.state==='locked'));
});
test('Lokales Testspiel: legaler Wurf, einmalige Runentreffer, Obergrenze und Abschlussbelohnung',()=>{
 const engine=new TestGame(definition(runeHitsFixture()));engine.reach(1);engine.roll([2,3,4,5]);
 engine.play(2);assert.equal(engine.state.monsterHits['5'],3);assert.equal(engine.state.diamonds,0);assert.ok(!engine.reached(5));
 assert.deepEqual(engine.play(2,{cheat:true}),{unchanged:true});assert.equal(engine.state.monsterHits['5'],3);
 engine.room(3).runeHits=10;engine.definition.rules.bossHits.find(e=>e.sourceCellId===3).hits=10;
 engine.roll([2,3,4,5]);assert.equal(engine.play(3).defeated,true);assert.equal(engine.state.monsterHits['5'],6);
 assert.ok(engine.reached(5));assert.equal(engine.state.diamonds,6);assert.deepEqual(engine.state.firstKills,['5']);assert.equal(engine.finished,false);
 engine.play(4,{cheat:true});engine.play(4,{cheat:true});assert.equal(engine.state.diamonds,9);
});
test('Lokales Testspiel: Rune im Fackelweg und Spielende durch eine letzte Rune',()=>{
 const engine=new TestGame(definition(runeHitsFixture()));engine.reach(1);engine.enablePower('torch');engine.roll([2,3,4,5]);
 const result=engine.play(3,{middle:2});assert.equal(result.defeated,true);assert.equal(engine.state.monsterHits['5'],6);assert.equal(engine.state.torchUses,1);assert.ok(engine.reached(2)&&engine.reached(3));
 const final=new TestGame(definition(runeHitsFixture()));final.reach(1);final.hitEnemy(final.room(4),2);final.state.monsterHits['5']=3;final.roll([2,3,4,5]);
 final.play(2);assert.equal(final.finished,true);assert.equal(final.state.diamonds,9);
});
test('Mehrere Bosse: jede Rune wirkt pro Boss einmal und hält die eigene Trefferobergrenze ein',()=>{
 const d=runeHitsFixture();d.rooms.push({...structuredClone(d.rooms[4]),id:7,x:40,hits:2,attacks:[{number:9,state:'active'}]});d.nextId=8;
 const compiled=compileDocument(d),engine=new TestGame(definition(compiled));engine.reach(2);
 assert.equal(engine.state.monsterHits['5'],3);assert.equal(engine.state.monsterHits['7'],2);assert.ok(!engine.reached(5)&&engine.reached(7));
 engine.reach(2);assert.equal(engine.state.diamonds,6);assert.equal(engine.state.monsterHits['5'],3);
 engine.reach(3);assert.equal(engine.state.monsterHits['5'],6);assert.equal(engine.state.diamonds,12);
});

test('Update 1.0.1: Gratis-Auswahl, Kartenprüfung und servergeprüfte Runenzüge',async t=>{
 const db=await createShopDatabase();let seq=0;
 try{
  for(const name of ['020_round_two.sql','022_print_and_cosmetics.sql','024_original_map_rules.sql','026_release_1_0_0.sql'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}`,import.meta.url),'utf8'));
  const a=await register(db,'RunenFlo'),b=await register(db,'RunenJoni');
  await db.query("insert into dungeon_private.marking_purchases(player_id,style,price,source) values($1,'pencil',5,'legacy')",[a.profile.id]);
  const migration=await readFile(new URL(`../supabase/migrations/${runeHitsMigration}`,import.meta.url),'utf8');await db.exec(migration);
  await installTestDice(db);
  const report=async d=>(await db.query('select dungeon_private.map_report($1::jsonb) r',[JSON.stringify(d)])).rows[0].r;
  const valid=async d=>(await db.query('select dungeon_private.map_document_valid($1::jsonb) r',[JSON.stringify(d)])).rows[0].r;
  const make=async(doc=runeHitsFixture(),users=[a,b])=>{const map=await publishFixture(db,a,'Runentest '+(++seq),doc);return {map,id:await newPlayGame(db,users,{fog:true},map)};};
  const get=async(id,u=a)=>(await userRpc(db,u,'get_game',{p_game_id:id})).game;
  const roll=async(id)=>{await forceDice(db,[2,3,4,5]);const g=await get(id),u=[a,b].find(x=>x.profile.id===g.rollerId);const r=await userRpc(db,u,'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()});assert.equal(r.ok,true);};
  const play=async(id,u,cell,args={})=>{const g=await get(id,u);return userRpc(db,u,'play_game_action',{p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:String(cell),p_use_red:false,p_request_id:randomUUID(),...args});};
  await t.test('Neue und bestehende Spieler erhalten 3/2 Varianten sofort, ohne Käufe oder Guthabenänderungen',async()=>{
   await db.exec(migration);const fresh=await register(db,'NeueRunenspielerin');
   for(const u of [a,b,fresh]){const shop=await userRpc(db,u,'get_marking_shop');assert.deepEqual(shop.items.filter(i=>i.price===0).map(i=>i.style),STARTER_MARKINGS);assert.ok(shop.items.filter(i=>i.price===0).every(i=>i.owned));
    assert.deepEqual(shop.cosmeticItems.filter(i=>i.category==='campStyle'&&i.price===0).map(i=>i.value),STARTER_BACKGROUNDS);assert.ok(shop.cosmeticItems.filter(i=>i.category==='campStyle'&&i.price===0).every(i=>i.owned));}
   const before=(await userRpc(db,a,'get_player_profile')).profile.cosmetics;
   const purchase=await userRpc(db,b,'buy_marking',{p_style:'weave',p_request_id:randomUUID()});assert.equal(purchase.charged,0);assert.equal(purchase.alreadyOwned,true);
   assert.equal((await db.query('select count(*) n from dungeon_private.marking_purchases where player_id=$1',[b.profile.id])).rows[0].n,0);
   assert.equal((await db.query("select price from dungeon_private.marking_purchases where player_id=$1 and style='pencil'",[a.profile.id])).rows[0].price,5);
   assert.deepEqual((await userRpc(db,a,'get_player_profile')).profile.cosmetics,before);
   for(const style of STARTER_MARKINGS){const p=(await userRpc(db,b,'get_player_profile')).profile;const r=await userRpc(db,b,'update_player_preferences',{p_preferences:{markStyle:style,campStyle:'dawn',sound:true,music:false,reduceMotion:false},p_expected_revision:p.revision});assert.equal(r.ok,true);assert.equal(r.profile.preferences.markStyle,style);assert.equal(r.profile.preferences.campStyle,'dawn');}
   const p=(await userRpc(db,b,'get_player_profile')).profile;assert.equal((await userRpc(db,b,'update_player_preferences',{p_preferences:{markStyle:'claws',sound:true,music:false,reduceMotion:false},p_expected_revision:p.revision})).error,'SHOP_STYLE_LOCKED');
   const checks=await db.exec(await readFile(new URL('../supabase/migrations/029_check_free_starters_and_rune_hits.sql',import.meta.url),'utf8'));assert.ok(checks[0].rows.every(r=>r.ergebnis==='OK'));
  });
  await t.test('Compiler, Veröffentlichungsprüfung, ungültige Werte und fehlender Boss',async()=>{
   const d=runeHitsFixture(),r=await report(d);assert.deepEqual(r.errors,[]);assert.deepEqual(r.rules.bossHits,d.rules.bossHits);assert.deepEqual(r.rules.unlocks,d.rules.unlocks);
   for(const value of [0,-1,101,1.5,'3',null]){const invalid=runeHitsFixture();invalid.rooms[1].runeHits=value;assert.equal(await valid(invalid),false,JSON.stringify(value));}
   for(const value of ['damage',3,null]){const invalid=runeHitsFixture();invalid.rooms[1].runeEffect=value;assert.equal(await valid(invalid),false);}
   const implicit=runeHitsFixture();delete implicit.rooms[1].runeHits;assert.equal((await report(implicit)).rules.bossHits[0].hits,3);
   const noBoss=runeHitsFixture();noBoss.rooms=noBoss.rooms.filter(r=>r.type!=='boss');assert.ok((await report(noBoss)).errors.some(e=>e.message.includes('Trefferrune')));
   const changed=runeHitsFixture();changed.rooms[1].runeEffect='unlock';const old=compileDocument(changed);old.rooms[1].runeEffect='hits';
   const sql=(await db.query('select dungeon_private.map_compile_v2($1::jsonb) d',[JSON.stringify(old)])).rows[0].d;assert.deepEqual(sql.rules,compileDocument(old).rules);assert.deepEqual(sql.rooms[4].attacks,compileDocument(old).rooms[4].attacks);assert.deepEqual((await report(old)).errors,[]);
   const multiple=runeHitsFixture();multiple.rooms.push({...structuredClone(multiple.rooms[4]),id:7,x:40,attacks:[{number:9,state:'active'}]});multiple.nextId=8;
   assert.deepEqual((await report(multiple)).rules.bossHits,compileDocument(multiple).rules.bossHits);
   assert.equal((await db.query("select has_function_privilege('anon','dungeon_private.damage_game_enemy(public.dungeon_games,uuid,jsonb,public.dungeon_map_cells,integer,text)','execute') p")).rows[0].p,false);
  });
  await t.test('Legale Runenzüge wirken nur auf das eigene Brett; ungültige Züge und Wiederholungen geben keine Treffer',async()=>{
   const {id}=await make();await roll(id);
   assert.equal((await play(id,a,2)).error,'GAME_CELL_UNREACHABLE');assert.deepEqual((await get(id)).ownState.monsterHits,{});
   await seedState(db,id,a,{reached:['1']});const g=await get(id),request=randomUUID(),args={p_game_id:id,p_round:g.round,p_state_revision:g.turn.ownRevision,p_action:'cell',p_cell_id:'2',p_use_red:false,p_request_id:request};
   assert.equal((await userRpc(db,a,'play_game_action',args)).ok,true);assert.equal((await userRpc(db,a,'play_game_action',args)).ok,true);
   assert.equal((await get(id)).ownState.monsterHits['5'],3);assert.ok(!(await get(id)).ownState.reached.includes('5'));assert.deepEqual((await get(id,b)).ownState.monsterHits,{});
   assert.equal((await db.query("select count(*) n from dungeon_game_events where game_id=$1 and kind='rune_triggered'",[id])).rows[0].n,1);
  });
  await t.test('Beide Runenerfolge in derselben Runde erhalten den Erstbonus; letzte Rune endet erst nach allen Zügen',async()=>{
   const {id}=await make();for(const u of [a,b])await seedState(db,id,u,{reached:['1','4'],monsterHits:{4:2,5:3}});await roll(id);
   assert.equal((await play(id,a,2)).ok,true);let g=await get(id);assert.equal(g.finalRound,g.round);assert.equal(g.status,'playing');assert.equal(g.ownState.diamonds,6);assert.equal(g.ownState.monsterHits['5'],6);assert.ok(g.ownState.firstKills.includes('5'));
   assert.equal((await play(id,b,2)).ok,true);g=await get(id);assert.equal(g.status,'finished');assert.equal(g.ownState.diamonds,6);assert.equal((await get(id,b)).ownState.diamonds,6);
   assert.equal(g.results.length,2);assert.ok(g.results.every(r=>r.breakdown.bossBonusDiamonds===0&&r.diamonds===6));
   assert.equal((await db.query("select count(*) n from dungeon_game_events where game_id=$1 and kind='enemy_defeated' and payload->>'cause'='rune'",[id])).rows[0].n,2);
   const replay=await userRpc(db,a,'get_game_replay',{p_game_id:id});assert.equal(replay.ok,true);assert.ok(JSON.stringify(replay).includes('monsterHits'));
  });
  await t.test('Fackel löst beide Runeffekte einmal aus und kappt die Treffer; besiegte Bosse bleiben unverändert',async()=>{
   const d=runeHitsFixture();d.rooms[2].runeHits=10;const {id}=await make(d);await seedState(db,id,a,{reached:['1'],torchUses:2});await roll(id);
   assert.equal((await play(id,a,3,{p_middle_cell_id:'2'})).ok,true);let g=await get(id);assert.equal(g.ownState.monsterHits['5'],6);assert.equal(g.ownState.diamonds,6);assert.equal(g.ownState.torchUses,1);assert.ok(g.ownState.reached.includes('2')&&g.ownState.reached.includes('3'));
   const state=g.ownState,again=(await db.query("select dungeon_private.reach_game_cell(g,$2,$3::jsonb,c) s from dungeon_games g join dungeon_map_cells c on c.version_id=g.map_version_id and c.cell_id='2' where g.id=$1",[id,a.profile.id,JSON.stringify(state)])).rows[0].s;assert.deepEqual(again,state);
  });
  await t.test('Späterer Runensieg erhält keinen Erstbonus; vollständige Bossgruppen zählen zur Endwertung',async()=>{
   const {id,map}=await make();await db.query('insert into dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values($1,$2,$3,$4,0)',[id,map.versionId,'5',b.profile.id]);
   await seedState(db,id,a,{reached:['1','4'],monsterHits:{4:2,5:3}});await seedState(db,id,b,{reached:['1','4','5'],monsterHits:{4:2,5:6},firstKills:['5']});await roll(id);
   assert.equal((await play(id,a,2)).ok,true);let g=await get(id);assert.equal(g.ownState.diamonds,0);assert.ok(!(g.ownState.firstKills||[]).includes('5'));
   assert.equal((await play(id,b,2)).ok,true);g=await get(id);assert.equal(g.status,'finished');const own=g.results.find(r=>r.id===a.profile.id||r.playerId===a.profile.id);
   assert.equal(own.breakdown.bossBonusDiamonds,2);assert.equal(own.diamonds,2);
  });
 }finally{await db.close();}
});
