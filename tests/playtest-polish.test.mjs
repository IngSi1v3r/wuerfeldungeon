import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {visibleCells,viewVisibility,graphEdges} from '../web/js/games/visibility.js';
import {pendingWaitPlayers} from '../web/js/games/rules.js';
import {TestGame} from '../web/js/games/test-engine.js';
import {createRuneHitsDatabase} from './helpers/rune-hits.mjs';
import {portalFixture,portalDefinition,playtestMigration} from './helpers/playtest-polish.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {newPlayGame,seedState,installTestDice,forceDice} from './helpers/turns.mjs';

test('Nebel: unbekannter Portalausgang bleibt verborgen, auch mit Fernglas und eingefrorenem Onlinegraph',()=>{
 for(const frozen of [false,true]){
  const d=portalDefinition(portalFixture(),frozen);
  for(const s of [{reached:[]},{reached:['1']},{reached:['1'],powerups:['binocular']}]){
   const visible=visibleCells(d,s);assert.ok(visible.includes('2'));assert.ok(!visible.includes('4'));assert.ok(!visible.includes('5'));
  }
  assert.ok(graphEdges(d).some(e=>e.includes('2')&&e.includes('4')),'Portal bleibt im Bewegungsgraph');
 }
});
test('Nebel: Betreten enthüllt das Partnerportal und seine Wege; Gegner blockieren weiterhin',()=>{
 const d=portalDefinition(),g=new TestGame(d);g.roll([2,3,4,5]);g.play(1);g.roll([2,3,4,5]);g.play(2);
 assert.ok(g.reached(2)&&g.reached(4));const visible=visibleCells(d,g.state);
 assert.ok(visible.includes('4')&&visible.includes('5')&&visible.includes('6'));assert.ok(!visible.includes('7'));
 assert.ok(!visibleCells(d,{...g.state,powerups:['binocular']}).includes('7'));
 assert.ok(visibleCells(d,{...g.state,reached:[...g.state.reached,'6']}).includes('7'));
});
test('Nebel: echte offene Durchgänge zwischen Portalpartnern sind sichtbar, geschlossene nicht',()=>{
 assert.ok(visibleCells(portalDefinition(portalFixture(true)),{reached:['1']}).includes('10'));
 assert.ok(!visibleCells(portalDefinition(portalFixture(true,true)),{reached:['1']}).includes('10'));
});
test('Horn zeigt Gegner, aber weder das unbekannte Partnerportal noch den Weg dorthin',()=>{
 const d=portalDefinition(),s={reached:['1'],hornUntil:'2026-10-05T10:00:10Z'};
 const v=viewVisibility(d,s,null,Date.parse('2026-10-05T10:00:05Z'));assert.ok(v.includes('6'));assert.ok(!v.includes('4')&&!v.includes('5'));
});
test('Warteanzeige zählt nur offene aktive Züge, Powerups und ausstehenden Würfler',()=>{
 const p=(id,extra={})=>({id,active:true,eliminated:false,turnDone:false,hasPendingPowerup:false,...extra});
 const g={phase:'choosing',participants:[p('a',{turnDone:true}),p('b'),p('c',{active:false}),p('d',{eliminated:true}),p('e',{turnDone:true,hasPendingPowerup:true})]};
 assert.deepEqual(pendingWaitPlayers(g).map(p=>p.id),['b','e']);
 g.phase='waiting_roll';g.rollWaitStartedAt='2026-10-05T10:00:00Z';g.rollerId='b';g.participants[4].hasPendingPowerup=false;
 assert.deepEqual(pendingWaitPlayers(g).map(p=>p.id),['b']);g.participants[1].eliminated=true;assert.deepEqual(pendingWaitPlayers(g),[]);
 g.phase='finished';assert.deepEqual(pendingWaitPlayers(g),[]);
});
test('Update 1.0.2: Portalregeln, neue Shoppreise und Wiederholbarkeit',async t=>{
 const db=await createRuneHitsDatabase();
 try{
  const a=await register(db,'PlaytestFlo'),b=await register(db,'PlaytestGast'),map=await publishFixture(db,a,'Portaltest',portalFixture());
  const id=await newPlayGame(db,[a,b],{fog:true,cards:'open'},map);
  await db.query("insert into dungeon_private.marking_credits(player_id,game_id,amount) values($1,$2,100)",[a.profile.id,id]);
  await db.query("insert into dungeon_private.marking_purchases(player_id,style,price,source) values($1,'spiral',10,'purchase')",[a.profile.id]);
  const before=(await userRpc(db,a,'get_player_profile')).profile;
  const migration=await readFile(new URL('../supabase/migrations/'+playtestMigration,import.meta.url),'utf8');await db.exec(migration);
  const rpc=(u,n,p={})=>userRpc(db,u,n,p),get=async u=>(await rpc(u,'get_game',{p_game_id:id})).game;
  const seen=async(game,state)=>(await db.query('select dungeon_private.game_visible_cells(g,$2::jsonb) v from dungeon_games g where id=$1',[game,JSON.stringify(state)])).rows[0].v;
  await t.test('Preise steigen einmal, Gratis-Auswahl, Konten, Guthaben und alte Käufe bleiben',async()=>{
   const after=(await rpc(a,'get_player_profile')).profile;assert.deepEqual(after,before);
   const shop=await rpc(a,'get_marking_shop'),prices=Object.fromEntries(shop.items.map(i=>[i.style,i.price]));
   assert.equal(prices.waves,15);assert.equal(prices.solid,23);assert.equal(prices.claws,45);assert.ok(shop.items.filter(i=>['cross','pencil','weave'].includes(i.style)).every(i=>i.price===0&&i.owned));
   assert.equal(shop.cosmeticItems.find(i=>i.category==='cupStyle'&&i.value==='runic').price,45);
   assert.ok(shop.cosmeticItems.filter(i=>i.category==='campStyle'&&['forest','dawn'].includes(i.value)).every(i=>i.price===0&&i.owned));
   await db.exec(migration);assert.deepEqual((await rpc(a,'get_marking_shop')).items,shop.items);assert.deepEqual((await rpc(a,'get_player_profile')).profile,before);
   assert.equal((await db.query("select price from dungeon_private.marking_purchases where player_id=$1 and style='spiral'",[a.profile.id])).rows[0].price,10);
  });
  await t.test('Unbetretenes Partnerportal und entfernte Felder sind auch serverseitig unsichtbar',async()=>{
   for(const s of [{reached:[]},{reached:['1']},{reached:['1'],powerups:['binocular']}]){
    assert.deepEqual(new Set(await seen(id,s)),new Set(visibleCells(portalDefinition(),s)));
    assert.ok(!(await seen(id,s)).includes('4'));
   }
   const g=await get(a);assert.ok(!g.visibleCells.includes('4'));assert.ok(!g.states.find(s=>s.playerId===b.profile.id).visibleCells.includes('4'));
   const edges=(await db.query('select cell_a,cell_b from dungeon_map_connections where version_id=$1',[map.versionId])).rows;
   assert.ok(edges.some(e=>e.cell_a==='2'&&e.cell_b==='4'),'Navigationsgraph bleibt unverändert');
  });
  await t.test('Legaler Portalzug aktiviert beide Felder nur auf dem eigenen Brett und enthüllt den Ausgang',async()=>{
   await installTestDice(db);await forceDice(db,[2,3,4,5]);await seedState(db,id,a,{reached:['1']});
   const g=await get(a);assert.equal((await rpc(a,'roll_game_dice',{p_game_id:id,p_round:g.round,p_request_id:randomUUID()})).ok,true);
   const turn=await get(a);assert.equal((await rpc(a,'play_game_action',{p_game_id:id,p_round:turn.round,p_state_revision:turn.turn.ownRevision,p_action:'cell',p_cell_id:'2',p_use_red:false,p_request_id:randomUUID()})).ok,true);
   const after=await get(a);assert.ok(after.ownState.reached.includes('2')&&after.ownState.reached.includes('4'));
   assert.ok(after.visibleCells.includes('4')&&after.visibleCells.includes('5')&&after.visibleCells.includes('6'));assert.ok(!after.visibleCells.includes('7'));
   assert.ok(!(await get(b)).visibleCells.includes('4'));
  });
  await t.test('Offene Wanddurchgänge, geschlossene Portale und JS/SQL-Sicht stimmen überein',async()=>{
   for(const closed of [false,true]){
    const d=portalFixture(true,closed),m=await publishFixture(db,a,'Nachbarportale '+closed,d),g=await newPlayGame(db,[a],{fog:true},m),s={reached:['1']};
    const actual=await seen(g,s);assert.equal(actual.includes('10'),!closed);assert.deepEqual(new Set(actual),new Set(visibleCells(portalDefinition(d),s)));
   }
   const complete={reached:['1','2','4','6'],powerups:['binocular']};assert.deepEqual(new Set(await seen(id,complete)),new Set(visibleCells(portalDefinition(),complete)));
   await db.query("update dungeon_games set settings=settings||'{\"fog\":false}'::jsonb where id=$1",[id]);
   assert.equal((await seen(id,{reached:[]})).length,portalFixture().rooms.length);
  });
  await t.test('Käufe verwenden erhöhte Preise, Wiederholungen buchen weiterhin einmal',async()=>{
   const req=randomUUID(),args={p_style:'waves',p_request_id:req},buy=await rpc(a,'buy_marking',args);assert.equal(buy.charged,15);
   assert.equal((await rpc(a,'buy_marking',args)).profile.cosmetics.spent,25);
   const cup=await rpc(a,'buy_cosmetic',{p_category:'cupStyle',p_value:'wood',p_request_id:randomUUID()});assert.equal(cup.charged,30);assert.equal(cup.profile.cosmetics.balance,45);
  });
  await t.test('Fünf Installationsprüfungen ergeben OK',async()=>{
   const checks=(await db.exec(await readFile(new URL('../supabase/migrations/031_check_playtest_polish.sql',import.meta.url),'utf8')))[0].rows;
   assert.equal(checks.length,5);assert.ok(checks.every(r=>r.ergebnis==='OK'));
  });
 }finally{await db.close();}
});

