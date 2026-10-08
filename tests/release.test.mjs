import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {releaseFixture} from './helpers/release.mjs';
import {compileDocument,canHaveFieldFlags} from '../web/js/maps/features.js';
import {connections} from '../web/js/maps/model.js';
import {visibleCells} from '../web/js/games/visibility.js';
import {TestGame} from '../web/js/games/test-engine.js';
import {createShopDatabase} from './helpers/shop.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {newPlayGame} from './helpers/turns.mjs';
import {callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';


test('Sonderfelder sind unabhängig Start- und Angriffsfelder; Sicht und Testspiel folgen denselben Regeln',()=>{
 const d=releaseFixture('doubleSum'),definition={document:d,rules:d.rules,graph:connections(d)};
 assert.deepEqual(d.rules.unlocks,[{sourceCellId:1,targetCellId:2,number:6}]);
 assert.equal(canHaveFieldFlags(d.rooms[1]),false);
 const g=new TestGame(definition);g.phase='choosing';g.dice=[3,3,2,1];
 assert.ok(g.actions().some(a=>a.cellId==='1'));
 assert.deepEqual(new Set(visibleCells(definition,{reached:[]})),new Set(['1','2']));
 g.play(1);assert.ok(g.attacks(g.room(2)).includes('6'));
 assert.equal(g.state.diamonds,0);
 assert.deepEqual(new Set(visibleCells(definition,{reached:['1','2']})),new Set(['1','2','3','4']));
});

test('Graue variable Felder verlinken ihre möglichen Zahlen ohne doppelte Freischaltungen',()=>{
 const d=releaseFixture('crazy');d.rooms[0].number=null;d.rooms[0].requirements=[3,7,'doubles'];
 const c=compileDocument(d);
 assert.deepEqual(c.rules.unlocks.map(u=>u.number),[3,7,'doubles']);
 assert.deepEqual(compileDocument(c),c);
});

test('Vollständige Neueinrichtung funktioniert atomar ohne alten Registrierungscode',async()=>{
 const db=new PGlite({extensions:{pgcrypto}});
 try{
  await db.exec('create role anon;create role authenticated;create role service_role;grant usage on schema public to anon,authenticated,service_role;create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);');
  const install=await readFile(new URL('../supabase/install.sql',import.meta.url),'utf8');
  await db.exec(install);
  const checks=await db.exec(await readFile(new URL('../supabase/migrations/035_check_adventurers.sql',import.meta.url),'utf8'));
  assert.ok(checks[0].rows.every(r=>r.ergebnis==='OK'));
  const status=await callRpc(db,'app_status');assert.equal(status.registrationOpen,true);assert.equal(status.registrationCodeRequired,false);
  const u=await callRpc(db,'register_player',{p_username:'erstespielerin',p_display_name:'Erste Spielerin',p_password:'Passwort123',p_access_code:''});assert.equal(u.ok,true);
  const map=await publishFixture(db,u,'Neue Welt',releaseFixture());assert.ok(map.versionId);
  await assert.rejects(db.exec(install),/bereits eingerichtet/);await db.exec('rollback');
  assert.equal((await userRpc(db,u,'get_player_profile')).profile.id,u.profile.id);
 }finally{await db.close();}
});

test('Release-Upgrade, Registrierung, Shop und vollständiger Reset',async t=>{
 const db=await createShopDatabase();
 const migration=await readFile(new URL('../supabase/migrations/026_release_1_0_0.sql',import.meta.url),'utf8');
 try{
  for(const name of ['020_round_two.sql','022_print_and_cosmetics.sql','024_original_map_rules.sql'])await db.exec(await readFile(new URL(`../supabase/migrations/${name}`,import.meta.url),'utf8'));
  const a=await register(db,'Flo'),b=await register(db,'Joni');
  await db.query("insert into dungeon_private.marking_purchases(player_id,style,price,source) values($1,'spiral',70,'legacy')",[a.profile.id]);
  await db.exec(migration);
  const rpc=(name,args={})=>userRpc(db,a,name,args);
  const report=async d=>(await db.query('select dungeon_private.map_report($1::jsonb) r',[JSON.stringify(d)])).rows[0].r;
  await t.test('Upgrade bewahrt Spieler und frühere Kaufpreise; erneutes Ausführen halbiert nicht nochmals',async()=>{
   await db.exec(migration);
   const profile=(await rpc('get_player_profile')).profile;assert.equal(profile.id,a.profile.id);
   assert.ok(profile.cosmetics.unlocked.includes('spiral'));
   assert.equal((await db.query("select price from dungeon_private.marking_purchases where player_id=$1 and style='spiral'",[a.profile.id])).rows[0].price,70);
   const shop=await rpc('get_marking_shop');assert.equal(shop.ok,true);
   const prices=Object.fromEntries(shop.items.map(i=>[i.style,i.price]));
   assert.equal(prices.weave,8);assert.equal(prices.spiral,10);
   assert.ok(['stars','runes','claws'].every(s=>prices[s]>prices.seal));
   assert.equal(shop.cosmeticItems.find(i=>i.category==='cupStyle'&&i.value==='runic').price,30);
   const checks=await db.exec(await readFile(new URL('../supabase/migrations/027_check_release_1_0_0.sql',import.meta.url),'utf8'));
   assert.ok(checks[0].rows.every(r=>r.ergebnis==='OK'));
  });
  await t.test('Registrierung ohne Code; spätere Reaktivierung bleibt auch nach erneutem Upgrade erhalten',async()=>{
   let status=(await db.query('select public.app_status() s')).rows[0].s;
   assert.equal(status.releaseVersion,'1.0.0');assert.equal(status.registrationCodeRequired,false);assert.equal(status.registrationOpen,true);
   const args={p_username:'ohnecode',p_display_name:'Ohne Code',p_password:'Passwort123',p_access_code:'',p_device_label:'Test'};
   assert.equal((await callRpc(db,'register_player',args)).ok,true);
   await db.exec('update dungeon_private.app_config set registration_code_required=true where singleton');
   await db.exec(migration);
   assert.equal((await callRpc(db,'register_player',{...args,p_username:'falscher_code'})).error,'ACCESS_CODE_INVALID');
   assert.equal((await callRpc(db,'register_player',{...args,p_username:'richtiger_code',p_access_code:TEST_ACCESS_CODE})).ok,true);
   await db.exec('update dungeon_private.app_config set registration_code_required=false where singleton');
   await db.exec('update dungeon_private.app_config set registration_enabled=false where singleton');
   assert.equal((await callRpc(db,'register_player',{...args,p_username:'geschlossen'})).error,'REGISTRATION_CLOSED');
   await db.exec('update dungeon_private.app_config set registration_enabled=true where singleton');
  });
  await t.test('Prüfung akzeptiert Sonder-Startfelder und angrenzende Freischaltungen; verbietet Monsterflags',async()=>{
   for(const type of ['normal','doubleSum','diamond','chest','trap','crazy','goldSack','goldCoin','bonus']){
    const d=releaseFixture(type);
    if(type==='trap')Object.assign(d.rooms[0],{trapKind:'diamonds',trapCost:1});
    if(type==='crazy')Object.assign(d.rooms[0],{number:null,requirements:[6,7]});
    if(type==='bonus')Object.assign(d.rooms[0],{number:null,name:'Bonus',hits:2,attacks:[{number:6,state:'active'}],rewardFirst:1,rewardLater:0,image:null,imageLayout:null});
    assert.deepEqual((await report(d)).errors,[],type);
   }
   const d=releaseFixture();d.rooms[1].start=true;assert.ok((await report(d)).errors.length);
   d.rooms[1].start=false;d.rooms[1].dimmed=true;assert.ok((await report(d)).errors.length);
   const closed=releaseFixture();closed.closedDoors['1:2']=true;assert.ok((await report(closed)).errors.some(e=>e.cellId==='1'));
   const js=compileDocument(releaseFixture('crazy'));js.rooms[0].number=null;js.rooms[0].requirements=[3,7,'doubles'];
   const sql=(await report(js)).rules;assert.deepEqual(sql.unlocks,compileDocument(js).rules.unlocks);
  });
  const map=await publishFixture(db,a,'Release-Karte',releaseFixture());
  const game=await newPlayGame(db,[a,b],{fog:true},map);
  await t.test('Server erreicht Sonder-Startfeld und hält am unbesiegten Monster die Sicht an',async()=>{
   const reachable=(await db.query("select dungeon_private.cell_reachable($1,'1','{\"reached\":[]}'::jsonb) r",[map.versionId])).rows[0].r;assert.equal(reachable,true);
   const g=(await rpc('get_game',{p_game_id:game})).game;
   assert.deepEqual(new Set(g.visibleCells),new Set(['1','2']));
  });
  await t.test('Reset löscht alle Spieldatentabellen und behält Schema, Konfiguration und Kataloge',async()=>{
   await db.query("insert into dungeon_private.auth_attempts(bucket,attempt_count) values('reset-test',3)");
   await db.query("insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values($1,'avatar',$2,'image/webp',100)",[a.profile.id+'/reset.webp',a.profile.id]);
   await db.query("insert into dungeon_private.marking_credits(player_id,game_id,amount) values($1,$2,10)",[a.profile.id,game]);
   await db.exec(await readFile(new URL('../supabase/RESET_ALL_DATA.sql',import.meta.url),'utf8'));
   const tables=await db.query("select schemaname,tablename from pg_tables where schemaname='dungeon_private' and tablename not in ('schema_migrations','app_config','marking_catalog','cosmetic_catalog') or schemaname='public' and tablename like 'dungeon_%'");
   for(const row of tables.rows){const count=(await db.query(`select count(*) n from ${row.schemaname}.${row.tablename}`)).rows[0].n;assert.equal(Number(count),0,row.tablename);}
   assert.equal((await db.query('select public.app_status() s')).rows[0].s.releaseVersion,'1.0.0');
   assert.equal((await db.query('select count(*) n from dungeon_private.marking_catalog')).rows[0].n,10);
   assert.ok((await db.query('select registration_code_hash h from dungeon_private.app_config')).rows[0].h);
   const args={p_username:'neustart',p_display_name:'Neustart',p_password:'Passwort123',p_access_code:'',p_device_label:'Test'};
   const fresh=await callRpc(db,'register_player',args);assert.equal(fresh.ok,true);assert.equal(fresh.profile.cosmetics.balance,0);
  });
 }finally{await db.close();}
});
