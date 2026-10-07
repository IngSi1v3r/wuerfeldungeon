import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDatabase,callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';
import {emptyDocument,connections} from '../web/js/maps/model.js';

export function fixture() {
 const d=emptyDocument();
 d.rooms=[{id:1,type:'normal',x:0,y:0,w:4,h:4,number:5,start:true,dimmed:false},{id:2,type:'normal',x:4,y:0,w:4,h:4,number:'doubles',start:false,dimmed:false},
  {id:3,type:'monster',x:8,y:0,w:8,h:8,number:null,start:false,dimmed:false,name:'Höhlentroll',hits:4,attacks:[{number:7,state:'active'},{number:9,state:'locked'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null},
  {id:4,type:'special',x:4,y:4,w:4,h:4,number:9,start:false,dimmed:false},{id:5,type:'chest',x:0,y:4,w:4,h:8,number:6,start:false,dimmed:false},
  {id:6,type:'chest',x:8,y:8,w:4,h:8,number:8,start:false,dimmed:false},{id:7,type:'boss',x:12,y:8,w:16,h:8,number:null,start:false,dimmed:false,name:'Glutdrache',hits:12,attacks:[{number:'doubles',state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}];
 d.nextId=8;d.rules.unlocks=[{sourceCellId:4,targetCellId:3,number:9}];return d;
}
test('Editorgraph: offene Kanten, mindestens eine Rasterlänge, keine Ecken und geschlossene Türen',()=>{
 const d=emptyDocument();d.rooms=[{id:1,x:0,y:0,w:4,h:4},{id:2,x:4,y:3,w:4,h:4},{id:3,x:-4,y:4,w:4,h:4},{id:10,x:0,y:4,w:4,h:4}];
 assert.deepEqual(connections(d),[['1','2'],['1','10'],['10','2'],['10','3']]);d.closedDoors['1:2']=true;assert.equal(connections(d).some(e=>e.includes('1')&&e.includes('2')),false);
});

test('Phase 2 auf echtem PostgreSQL: Bibliothek, Sperren, Save-CAS, Veröffentlichung und Regeln',{timeout:120000},async t=>{
 const db=await createDatabase(),migration=await readFile(new URL('../supabase/migrations/004_phase2.sql',import.meta.url),'utf8');
 let flo,joni,map,revision,version;const editor=randomUUID(),otherEditor=randomUUID();
 const rpc=(name,args={},user=flo)=>callRpc(db,name,{p_session_token:user.session.token,...args});
 const lockArgs=()=>({p_map_id:map.id,p_editor_id:editor});
 const saveArgs=(d=fixture(),extra={})=>({...lockArgs(),p_expected_revision:revision,p_name:map.name,p_document:d,p_request_id:randomUUID(),...extra});
 try {
  await t.test('Additive Migration ist wiederholbar; Registrierungscode und bestehendes Profil bleiben erhalten',async()=>{
   flo=await callRpc(db,'register_player',{p_username:'flo',p_display_name:'Flo',p_password:'testing42',p_access_code:TEST_ACCESS_CODE});
   const before=(await db.query('select registration_code_hash from dungeon_private.app_config')).rows[0];await db.exec(migration);await db.exec(migration);
   assert.deepEqual((await db.query('select registration_code_hash from dungeon_private.app_config')).rows[0],before);assert.equal((await rpc('get_player_profile')).profile.id,flo.profile.id);
   assert.equal((await callRpc(db,'app_status')).editorSchemaVersion,2);
   joni=await callRpc(db,'register_player',{p_username:'joni',p_display_name:'Joni',p_password:'testing42',p_access_code:TEST_ACCESS_CODE});
  });
  await t.test('Neue Karte, echte leere Bibliothek und eindeutiger Name',async()=>{
   assert.equal((await rpc('list_maps')).maps.length,0);const result=await rpc('create_map',{p_name:'Lava Mine'});assert.equal(result.ok,true,JSON.stringify(result));map=result.map;revision=map.revision;
   assert.equal((await rpc('create_map',{p_name:'  LAVA MINE '})).error,'MAP_NAME_TAKEN');assert.equal((await rpc('list_maps',{},joni)).maps[0].creator,'Flo');
  });
  await t.test('Sperre schützt auch zwei Tabs mit demselben Sitzungsschlüssel',async()=>{
   assert.equal((await rpc('acquire_map_lock',lockArgs())).acquired,true);
   assert.equal((await rpc('acquire_map_lock',{p_map_id:map.id,p_editor_id:otherEditor})).acquired,false);
   assert.equal((await rpc('acquire_map_lock',{p_map_id:map.id,p_editor_id:otherEditor},joni)).acquired,false);
   assert.equal((await rpc('heartbeat_map_lock',lockArgs())).ok,true);
   assert.equal((await rpc('delete_map',{p_map_id:map.id,p_expected_revision:revision},joni)).error,'MAP_BUSY');
  });
  await t.test('Speichern akzeptiert unfertige Entwürfe, prüft Geometrie und verhindert falsche Bildreferenzen',async()=>{
   const d=fixture();d.rooms[1].number=null;const saved=await rpc('save_map',saveArgs(d));assert.equal(saved.ok,true,JSON.stringify(saved));revision=saved.map.revision;
   const overlap=fixture();overlap.rooms[1].x=0;assert.equal((await rpc('save_map',saveArgs(overlap))).error,'MAP_DOCUMENT_INVALID');
   const badImage=fixture();badImage.rooms[2].image={src:`asset:${map.id}/${randomUUID()}.png`,width:10,height:10,name:'test'};assert.equal((await rpc('save_map',saveArgs(badImage))).error,'MAP_DOCUMENT_INVALID');
   assert.equal((await rpc('check_map',{p_map_id:map.id})).report.errors.some(e=>e.cellId==='2'),true);
  });
  await t.test('CAS und Anfrage-ID verhindern Überschreiben sowie Doppelspeichern nach unklarem Commit',async()=>{
   const attempt=saveArgs(),result=await rpc('save_map',attempt);assert.equal(result.ok,true);revision=result.map.revision;
   assert.deepEqual(await rpc('save_map',attempt),result);assert.equal((await rpc('get_map',{p_map_id:map.id})).map.revision,revision);
   assert.equal((await rpc('save_map',{...attempt,p_name:'Changed'})).error,'MAP_REQUEST_INVALID');
   assert.equal((await rpc('save_map',saveArgs(fixture(),{p_expected_revision:1}))).error,'MAP_CHANGED');
  });
  await t.test('Abgelaufene Sperre ist übernehmbar; alter Bearbeiter kann nicht mehr schreiben oder freigeben',async()=>{
   await db.query("update dungeon_private.map_edit_locks set lease_until=now()-interval '1 second' where map_id=$1",[map.id]);
   assert.equal((await rpc('acquire_map_lock',{p_map_id:map.id,p_editor_id:otherEditor},joni)).acquired,true);
   assert.equal((await rpc('save_map',saveArgs())).error,'MAP_LOCK_LOST');await rpc('release_map_lock',lockArgs());
   assert.equal((await rpc('heartbeat_map_lock',{p_map_id:map.id,p_editor_id:otherEditor},joni)).ok,true);
   await rpc('release_map_lock',{p_map_id:map.id,p_editor_id:otherEditor},joni);assert.equal((await rpc('acquire_map_lock',lockArgs())).acquired,true);
  });
  await t.test('Freischaltungen, Bossbelohnung und Spezialziele werden unabhängig vom Browser geprüft',async()=>{
   const d=fixture();d.rules.unlocks=[];d.rooms.at(-1).rewardLater=1;d.rules.customGoal={type:'defeatEnemies',cellIds:[1],diamonds:3};
   const result=await rpc('save_map',saveArgs(d));assert.equal(result.ok,true);revision=result.map.revision;
   const report=(await rpc('check_map',{p_map_id:map.id})).report;assert.ok(report.errors.length>=3);
   assert.equal((await rpc('publish_map',{...lockArgs(),p_expected_revision:revision,p_accept_warnings:true})).error,'MAP_INCOMPLETE');
   const good=await rpc('save_map',saveArgs());assert.equal(good.ok,true);revision=good.map.revision;
  });
  await t.test('Veröffentlichung benötigt bewusste Hinweisbestätigung und friert serverberechneten Graph ein',async()=>{
   const report=(await rpc('check_map',{p_map_id:map.id})).report;assert.equal(report.errors.length,0,JSON.stringify(report));assert.ok(report.warnings.length>0);
   assert.equal((await rpc('publish_map',{...lockArgs(),p_expected_revision:revision})).error,'MAP_WARNINGS');
   const result=await rpc('publish_map',{...lockArgs(),p_expected_revision:revision,p_accept_warnings:true});assert.equal(result.ok,true,JSON.stringify(result));version=result.map.versionId;revision=result.map.revision;
   const rows=(await db.query('select cell_a,cell_b from public.dungeon_map_connections where version_id=$1 order by cell_a,cell_b',[version])).rows;
   assert.deepEqual(rows.map(r=>[r.cell_a,r.cell_b]),connections(fixture()).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b))));
   assert.equal((await db.query('select count(*)::int n from public.dungeon_map_cells where version_id=$1',[version])).rows[0].n,7);
   assert.equal((await rpc('save_map',saveArgs())).error,'MAP_READ_ONLY');assert.equal((await rpc('acquire_map_lock',lockArgs())).acquired,false);
   assert.equal((await rpc('publish_map',{...lockArgs(),p_expected_revision:revision})).map.versionId,version);
   await assert.rejects(db.query("update public.dungeon_map_versions set name='Bad' where id=$1",[version]),/IMMUTABLE/);
   await assert.rejects(db.query("update public.dungeon_maps set status='draft' where id=$1",[map.id]),/IMMUTABLE/);
  });
  await t.test('Alle Freunde dürfen kopieren; fertige Karten werden archiviert und Spieldefinitionen bleiben erhalten',async()=>{
   const result=await rpc('copy_map',{p_map_id:map.id,p_name:'Joni Variante'},joni);assert.equal(result.ok,true);assert.equal(result.map.status,'draft');assert.equal(result.map.creator,'Joni');assert.equal(result.map.versionId,null);
   assert.equal((await rpc('delete_map',{p_map_id:map.id,p_expected_revision:revision},joni)).archived,true);
   assert.equal((await db.query('select count(*)::int n from public.dungeon_map_versions where id=$1',[version])).rows[0].n,1);
   assert.equal((await rpc('delete_map',{p_map_id:result.map.id,p_expected_revision:result.map.revision})).deleted,true);
  });
  await t.test('Direkte Tabellenzugriffe und serverseitige Upload-Funktionen bleiben für Browser gesperrt',async()=>{
   await db.exec('set role anon');try{await assert.rejects(db.query('select * from public.dungeon_maps'),/permission denied/);await assert.rejects(db.query("select public.app_authorize_map_asset('x',$1,$2)",[map.id,editor]),/permission denied/);}finally{await db.exec('reset role');}
  });
 }finally{await db.close();}
});
