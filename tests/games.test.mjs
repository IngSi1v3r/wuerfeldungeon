import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {createGamesDatabase,register,userRpc,publishFixture,gameFixture} from './helpers/games.mjs';

test('Phase 3 auf PostgreSQL: Spiele, Sperren, Wiederaufnahme, Broadcasts und Chronik',{timeout:120000},async t=>{
 const db=await createGamesDatabase();let flo,joni,mira,map,gameId,second;
 const rpc=(name,args={},user=flo)=>userRpc(db,user,name,args),get=(id=gameId,user=flo)=>rpc('get_game',{p_game_id:id},user);
 const create=(extra={},user=flo)=>rpc('create_game',{p_map_version_id:map.versionId,p_name:'Abendrunde',p_settings:{maxPlayers:2,cards:'hidden',hints:true},p_password:'mine42',p_request_id:randomUUID(),...extra},user);
 const join=(user,id=gameId,password='mine42')=>rpc('join_game',{p_game_id:id,p_password:password,p_request_id:randomUUID()},user);
 const manage=async(action,user=flo,id=gameId,target=null)=>rpc('manage_game',{p_game_id:id,p_action:action,p_expected_revision:(await get(id,user)).game.revision,p_target_player_id:target,p_request_id:randomUUID()},user);
 try {
  await t.test('Zusätzliche Migration ist wiederholbar und lässt Spieler, Karten und Sitzungen erhalten',async()=>{
   flo=await register(db,'Flo');joni=await register(db,'Joni');mira=await register(db,'Mira');map=await publishFixture(db,flo);
   await db.exec(await readFile(new URL('../supabase/migrations/006_phase3.sql',import.meta.url),'utf8'));
   assert.equal((await callRpc(db,'app_status')).gameSchemaVersion,3);assert.equal((await rpc('get_player_profile')).profile.id,flo.profile.id);assert.equal((await rpc('get_map',{p_map_id:map.id})).map.versionId,map.versionId);
  });
  await t.test('Spielauswahl enthält veröffentlichte Karten und keine Entwürfe',async()=>{
   await rpc('create_map',{p_name:'Unfertige Höhle'});const maps=(await rpc('list_game_maps')).maps;assert.equal(maps.length,1);assert.equal(maps[0].versionId,map.versionId);
  });
  await t.test('Eingaben werden serverseitig geprüft; Erstellung wird bei Wiederholung nur einmal ausgeführt',async()=>{
   assert.equal((await create({p_settings:{maxPlayers:1,cards:'open',hints:true}})).error,'GAME_SETTINGS_INVALID');assert.equal((await create({p_name:' '})).error,'GAME_INPUT_INVALID');
   assert.equal((await create({p_password:'ä'.repeat(40)})).error,'GAME_PASSWORD_INVALID');
   const id=randomUUID(),first=await create({p_request_id:id});gameId=first.gameId;assert.ok(gameId);assert.equal((await create({p_request_id:id})).gameId,gameId);
   assert.equal((await create({p_request_id:id,p_name:'Andere Runde'})).error,'GAME_REQUEST_INVALID');assert.equal((await db.query('select count(*)::int n from dungeon_games')).rows[0].n,1);
   const hash=(await db.query('select password_hash from dungeon_private.game_passwords where game_id=$1',[gameId])).rows[0].password_hash;assert.match(hash,/^\$2[aby]\$/);assert.ok(!hash.includes('mine42'));
  });
  await t.test('Fremde sehen die Lobbydaten, aber vor Beitritt keine Definition oder Spielerstände',async()=>{
   const listed=(await rpc('list_games',{},joni)).lobbies[0];assert.equal(listed.mine,false);assert.equal(listed.passwordRequired,true);assert.equal(listed.playerCount,1);
   assert.equal(JSON.stringify(listed).includes('mine42'),false);assert.equal(JSON.stringify(listed).includes('password_hash'),false);const result=await get(gameId,joni);assert.equal(result.error,'GAME_JOIN_REQUIRED');assert.equal(result.lobby.id,gameId);assert.equal(result.game,undefined);
  });
  await t.test('Passwort und Platzlimit gelten serverseitig; ein Beitritt erzeugt genau einen Teilnehmer',async()=>{
   assert.equal((await join(joni,gameId,'falsch')).error,'GAME_PASSWORD_WRONG');const request=randomUUID(),args={p_game_id:gameId,p_password:'mine42',p_request_id:request};const first=await rpc('join_game',args,joni);assert.equal(first.ok,true);assert.deepEqual(await rpc('join_game',args,joni),first);
   assert.equal((await join(mira)).error,'GAME_FULL');assert.equal((await get()).game.playerCount,2);assert.equal((await get()).game.participants.length,2);
  });
  await t.test('Nur Host startet, Änderungen an Teilnehmern werden vor Start erneut geprüft',async()=>{
   const g=(await get()).game;assert.equal((await rpc('start_game',{p_game_id:gameId,p_expected_revision:g.revision,p_request_id:randomUUID()},joni)).error,'GAME_HOST_ONLY');
   assert.equal((await rpc('start_game',{p_game_id:gameId,p_expected_revision:g.revision-1,p_request_id:randomUUID()})).error,'GAME_CHANGED');
   const args={p_game_id:gameId,p_expected_revision:g.revision,p_request_id:randomUUID()},answer=await rpc('start_game',args);assert.equal(answer.ok,true);assert.deepEqual(await rpc('start_game',args),answer);
   const started=(await get()).game;assert.equal(started.status,'playing');assert.equal(started.round,1);assert.equal(started.phase,'waiting_roll');assert.equal(started.rollerId,flo.profile.id);assert.equal((await join(mira)).error,'GAME_ALREADY_STARTED');assert.equal((await rpc('list_games')).lobbies.length,0);
  });
  await t.test('Jeder Teilnehmer erhält seinen eigenen dauerhaft gespeicherten Anfangsstand',async()=>{
   const states=(await db.query('select player_id,state,last_completed_round from dungeon_game_player_states where game_id=$1',[gameId])).rows;assert.equal(states.length,2);
   for(const s of states){assert.deepEqual(s.state.reached,[]);assert.equal(s.state.redUses,3);assert.equal(s.state.diamonds,0);assert.equal(s.last_completed_round,0);}
   const login=await callRpc(db,'login_player',{p_username:'flo',p_password:'testing42'});assert.equal((await get(gameId,login)).game.id,gameId);assert.equal((await get(gameId,login)).game.ownState.redUses,3);
  });
  await t.test('Verdeckte Karten werden auf dem Server gefiltert, nicht nur in CSS versteckt',async()=>{
   await db.query(`update dungeon_game_player_states set state=state||'{"reached":[999],"monsterHits":{"5":3}}'::jsonb where game_id=$1 and player_id=$2`,[gameId,joni.profile.id]);
   const g=(await get()).game;assert.equal(g.states.length,1);assert.equal(g.states[0].playerId,flo.profile.id);assert.ok(g.states.every(s=>!s.state.reached.includes(999)&&s.state.monsterHits['5']!==3));assert.deepEqual((await get(gameId,joni)).game.ownState.reached,[999]);
   await db.query(`insert into dungeon_game_events(game_id,game_revision,kind,payload) values($1,99,'move','{"cellId":999}'::jsonb)`,[gameId]);assert.ok(!(await get()).game.events.some(e=>e.kind==='move'));
  });
  await t.test('Host kann pausieren und fortsetzen; andere Spieler dürfen dies nicht',async()=>{
   assert.equal((await manage('pause',joni)).error,'GAME_HOST_ONLY');assert.equal((await manage('pause')).ok,true);assert.equal((await get()).game.status,'paused');assert.ok((await get()).game.pausedAt);
   assert.equal((await manage('resume')).ok,true);assert.equal((await get()).game.status,'playing');assert.equal((await get()).game.round,1);assert.equal((await get()).game.pausedAt,null);
  });
  await t.test('Mehrere Spiele bleiben parallel offen; Gerätwechsel verliert weder Platz noch Karte',async()=>{
   second=(await create({p_name:'Runde mit Mira',p_password:'',p_settings:{maxPlayers:4,cards:'open',hints:false}})).gameId;assert.equal((await join(mira,second,'')).ok,true);
   const g=(await get(second)).game;await rpc('start_game',{p_game_id:second,p_expected_revision:g.revision,p_request_id:randomUUID()});assert.equal((await rpc('list_games')).ongoing.length,2);assert.equal((await rpc('list_games',{},joni)).ongoing.length,1);
   const login=await callRpc(db,'login_player',{p_username:'flo',p_password:'testing42'});assert.equal((await rpc('list_games',{},login)).ongoing.length,2);assert.deepEqual((await get(second)).game.definition.document,gameFixture());
  });
  await t.test('Archivierung verhindert neue Spiele, laufende Spiele behalten ihre feste Definition',async()=>{
   assert.equal((await rpc('delete_map',{p_map_id:map.id,p_expected_revision:map.revision})).archived,true);assert.equal((await rpc('list_game_maps')).maps.length,0);assert.equal((await create()).error,'GAME_MAP_UNAVAILABLE');
   assert.deepEqual((await get()).game.definition.document,gameFixture());assert.equal((await get()).game.map.name,'Lava Mine');map=await publishFixture(db,flo,'Neue Höhle');
  });
  await t.test('Hostübertragung und freiwilliges Verlassen betreffen nur diesen Warteraum',async()=>{
   const id=(await create({p_name:'Wartende Runde',p_password:'',p_settings:{maxPlayers:4,cards:'open',hints:true}})).gameId;await join(joni,id,'');await join(mira,id,'');
   const request=randomUUID(),args={p_game_id:id,p_request_id:request};const answer=await rpc('leave_game',args);assert.equal(answer.ok,true);assert.deepEqual(await rpc('leave_game',args),answer);assert.equal((await get(id,joni)).game.host.id,joni.profile.id);
   assert.equal((await join(flo,id,'')).ok,true);assert.equal((await get(id)).game.participants.at(-1).id,flo.profile.id);const before=(await get(id)).game.events.filter(e=>e.kind==='host_changed').length;
   await rpc('leave_game',{p_game_id:id,p_request_id:randomUUID()},mira);assert.equal((await get(id,joni)).game.events.filter(e=>e.kind==='host_changed').length,before);
   assert.equal((await manage('host',joni,id,flo.profile.id)).ok,true);assert.equal((await get(id)).game.host.id,flo.profile.id);
  });
  await t.test('Entfernte Lobbyspieler können nicht direkt wieder beitreten; letzte Person schließt die Lobby',async()=>{
   const id=(await create({p_name:'Kleine Runde',p_password:''})).gameId;await join(joni,id,'');assert.equal((await manage('remove',flo,id,joni.profile.id)).ok,true);assert.equal((await join(joni,id,'')).error,'GAME_REMOVED');assert.equal((await get(id,joni)).error,'GAME_REMOVED');
   await rpc('leave_game',{p_game_id:id,p_request_id:randomUUID()});assert.equal((await get(id)).game.status,'cancelled');assert.equal((await rpc('get_player_profile')).profile.stats.gamesPlayed,0);
  });
  await t.test('Abbruch erhält gespeicherten Spielstand und erzeugt keine Ergebnisstatistik',async()=>{
   assert.equal((await manage('cancel',flo,second)).ok,true);assert.equal((await rpc('list_games')).ongoing.length,1);assert.equal((await get(second)).game.status,'cancelled');assert.equal((await rpc('get_game_result',{p_game_id:second})).game.results.length,0);assert.equal((await join(mira,second,'')).error,'GAME_CLOSED');
  });
  await t.test('Chronik zeigt Ergebnisse, gemeinsame Sieger, Filter und stabile Cursor-Paginierung',async()=>{
   await db.query(`update dungeon_games set status='finished',phase='finished',finished_at=now() where id=$1`,[gameId]);
   for(const user of [flo,joni])await db.query('insert into dungeon_game_results(game_id,player_id,total_points,diamonds,life_penalty,monsters_defeated,won) values($1,$2,21,8,-3,2,true)',[gameId,user.profile.id]);
   const result=(await rpc('get_game_result',{p_game_id:gameId},mira)).game;assert.equal(result.results.length,2);assert.ok(result.results.every(r=>r.won));assert.equal(result.participated,false);
   assert.equal((await rpc('list_game_history')).games.length,1);assert.equal((await rpc('list_game_history',{p_scope:'won'})).games.length,1);assert.equal((await rpc('list_game_history',{p_scope:'won'},mira)).games.length,0);
   assert.equal((await rpc('list_game_history',{p_query:'LAVA'})).games.length,1);assert.equal((await rpc('list_game_history',{p_query:'unknown'})).games.length,0);
   const first=await rpc('list_game_history',{p_status:'all',p_limit:1});assert.equal(first.games.length,1);assert.equal(first.hasMore,true);const after=await rpc('list_game_history',{p_status:'all',p_limit:1,p_before:first.games[0].finishedAt,p_before_id:first.games[0].id});assert.equal(after.games.length,1);assert.notEqual(after.games[0].id,first.games[0].id);
   assert.equal((await rpc('list_game_history',{p_since:new Date(Date.now()+86400000).toISOString()})).games.length,0);assert.equal((await rpc('list_game_history',{p_limit:0})).error,'GAME_INPUT_INVALID');
   assert.equal((await rpc('get_player_profile')).profile.stats.wins,1);
  });
  await t.test('Broadcasts enthalten ausschließlich Änderungsmarker und keine privaten Daten',async()=>{
   const signals=(await db.query('select payload,event,topic,is_private from realtime.test_signals')).rows;assert.ok(signals.length>10);
   assert.ok(signals.some(s=>s.topic==='dungeon:lobbies'));assert.ok(signals.some(s=>s.topic===`dungeon:game:${gameId}`));
   for(const s of signals){assert.equal(s.event,'changed');assert.equal(s.is_private,false);assert.ok(Object.keys(s.payload).every(k=>k==='revision'));assert.equal(JSON.stringify(s.payload).includes('mine42'),false);}
  });
  await t.test('Ohne Realtime funktionieren RPCs weiterhin; Browser hat Polling als Rückfall',async()=>{
   await db.exec('drop function realtime.send(jsonb,text,text,boolean)');assert.equal((await callRpc(db,'app_status')).realtimeAvailable,false);const r=await create({p_password:''});assert.equal(r.ok,true);
  });
  await t.test('Direkte Tabellen, Passwortdaten und interne Kommando-Funktionen sind für Browser gesperrt',async()=>{
   await db.exec('set role anon');try{await assert.rejects(db.query('select * from dungeon_games'),/permission denied/);await assert.rejects(db.query('select * from dungeon_private.game_passwords'),/permission denied/);await assert.rejects(db.query("select dungeon_private.game_command_replay($1,$2,$3,'start','{}')",[gameId,flo.profile.id,randomUUID()]),/permission denied/);}finally{await db.exec('reset role');}
   await assert.rejects(callRpc(db,'list_games',{p_session_token:'x'}),/SESSION_INVALID/);
  });
 } finally {await db.close();}
});
