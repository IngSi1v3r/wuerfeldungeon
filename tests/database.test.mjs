import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createDatabase,callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';

test('Phase-1-SQL auf echtem PostgreSQL (PGlite + pgcrypto)',{timeout:120000},async t=>{
  const db=await createDatabase();let flo,joni,versionId;
  const register=(username,extra={})=>callRpc(db,'register_player',{p_username:username,p_display_name:username,p_password:'testing42',p_access_code:TEST_ACCESS_CODE,...extra});
  try {
    await t.test('Migration ist wiederholbar, Konfiguration bleibt erhalten',async()=>{
      await db.exec(await readFile(new URL('../supabase/migrations/001_phase1.sql',import.meta.url),'utf8'));
      assert.deepEqual(await callRpc(db,'app_status'),{ok:true,schemaVersion:1,registrationOpen:true});
      const buckets=(await db.query('select id from storage.buckets order by id')).rows;
      assert.deepEqual(buckets.map(row=>row.id),['avatars','map-assets']);
    });
    await t.test('Registrierungscode-Vorlage und lesender Installationscheck funktionieren',async()=>{
      const script=await readFile(new URL('../supabase/migrations/002_registration_code.sql',import.meta.url),'utf8');
      await assert.rejects(db.exec(script),/Bitte zuerst deinen privaten Registrierungscode/);
      await db.exec('rollback');
      await db.exec(script.replace("'DEIN_PRIVATER_ZUGANGSCODE'",`'${TEST_ACCESS_CODE}'`));
      assert.equal((await callRpc(db,'app_status')).registrationOpen,true);
      const checks=await db.exec(await readFile(new URL('../supabase/migrations/003_check_installation.sql',import.meta.url),'utf8'));
      assert.deepEqual(checks.at(-1).rows[0],{public_login_rpc_allowed:true,direct_player_read_allowed:false,direct_avatar_commit_allowed:false});
    });
    await t.test('Zugangscode, Grenzen und doppelte Namen werden geprüft',async()=>{
      assert.equal((await register('flo',{p_access_code:'wrong'})).error,'ACCESS_CODE_INVALID');
      assert.equal((await register('ab')).error,'USERNAME_INVALID');
      assert.equal((await register('flo',{p_password:'short'})).error,'PASSWORD_INVALID');
      assert.equal((await register('flo',{p_display_name:' '})).error,'DISPLAY_NAME_INVALID');
      flo=await register(' FLO ',{p_display_name:'Flo 🐉'});assert.equal(flo.ok,true);assert.equal(flo.profile.username,'flo');
      joni=await register('joni');assert.equal(joni.ok,true);
      assert.equal((await register('FLO')).error,'USERNAME_TAKEN');
    });
    await t.test('Passwörter und Zugangscode sind bcrypt, Sitzungstoken nur SHA-256',async()=>{
      const secrets=(await db.query('select password_hash from dungeon_private.player_credentials')).rows;
      assert.ok(secrets.every(row=>/^\$2[aby]\$10\$/.test(row.password_hash)));
      assert.ok(secrets.every(row=>!row.password_hash.includes('testing42')));
      const code=(await db.query('select registration_code_hash from dungeon_private.app_config')).rows[0].registration_code_hash;
      assert.ok(code.startsWith('$2'));assert.notEqual(code,TEST_ACCESS_CODE);
      const hashes=(await db.query('select token_hash from dungeon_private.player_sessions')).rows;
      assert.ok(hashes.every(row=>row.token_hash.length===64));
      assert.ok(hashes.every(row=>row.token_hash!==flo.session.token));
    });
    await t.test('Direkter Tabellenzugriff und interne RPCs sind gesperrt',async()=>{
      await db.exec('set role anon');
      try {
        for (const query of ['select * from public.dungeon_players','select * from dungeon_private.player_credentials','select * from public.dungeon_game_player_states']) {
          await assert.rejects(db.query(query),/permission denied/);
        }
        await assert.rejects(db.query("select public.app_finish_avatar_upload('a','b',1)"),/permission denied/);
      } finally {await db.exec('reset role');}
      const rows=(await db.query("select tablename,rowsecurity from pg_tables where schemaname='public' and tablename like 'dungeon_%'")).rows;
      assert.ok(rows.length>=10);assert.ok(rows.every(row=>row.rowsecurity));
    });
    await t.test('Login liefert einen eigenen Schlüssel für jedes Gerät',async()=>{
      assert.equal((await callRpc(db,'login_player',{p_username:'flo',p_password:'wrong'})).error,'LOGIN_INVALID');
      assert.equal((await callRpc(db,'login_player',{p_username:'unknown',p_password:'wrong'})).error,'LOGIN_INVALID');
      const second=await callRpc(db,'login_player',{p_username:'Flo',p_password:'testing42',p_device_label:'Laptop'});
      assert.equal(second.ok,true);assert.notEqual(second.session.token,flo.session.token);
      const validated=await callRpc(db,'validate_player_session',{p_session_token:second.session.token});
      assert.equal(validated.profile.id,flo.profile.id);
      const list=await callRpc(db,'list_player_sessions',{p_session_token:flo.session.token});
      assert.equal(list.sessions.length,2);assert.equal(list.sessions.filter(row=>row.current).length,1);
      assert.ok(!JSON.stringify(list).includes(second.session.token));
      await callRpc(db,'revoke_player_session',{p_session_token:joni.session.token,p_session_id:second.session.id});
      assert.equal((await callRpc(db,'validate_player_session',{p_session_token:second.session.token})).ok,true);
      await callRpc(db,'revoke_player_session',{p_session_token:flo.session.token,p_session_id:second.session.id});
      await assert.rejects(callRpc(db,'validate_player_session',{p_session_token:second.session.token}),/SESSION_INVALID/);
    });
    await t.test('Startseite und echte Null-Statistik funktionieren',async()=>{
      const data=await callRpc(db,'get_home_data',{p_session_token:flo.session.token});
      assert.deepEqual(data.counts,{publishedMaps:0,openLobbies:0,activeGames:0});
      assert.deepEqual(data.profile.stats,{gamesPlayed:0,totalPoints:0,averagePoints:0,wins:0,monstersDefeated:0});
    });
    await t.test('Profil und Einstellungen verhindern verlorene Änderungen',async()=>{
      const changed=await callRpc(db,'update_player_profile',{p_session_token:flo.session.token,p_display_name:'<script>kein HTML</script>',p_expected_revision:1});
      assert.equal(changed.ok,true);assert.equal(changed.profile.revision,2);
      const stale=await callRpc(db,'update_player_profile',{p_session_token:flo.session.token,p_display_name:'Stale',p_expected_revision:1});
      assert.equal(stale.error,'PROFILE_CHANGED');
      const invalid=await callRpc(db,'update_player_preferences',{p_session_token:flo.session.token,p_preferences:{markStyle:'cross'},p_expected_revision:2});
      assert.equal(invalid.error,'PREFERENCES_INVALID');
      const prefs={markStyle:'waves',sound:false,music:true,reduceMotion:true};
      const saved=await callRpc(db,'update_player_preferences',{p_session_token:flo.session.token,p_preferences:{...prefs,injected:'ignored'},p_expected_revision:2});
      assert.deepEqual(saved.profile.preferences,prefs);flo.profile=saved.profile;
    });
    await t.test('Profilbild kann nur serverseitig für den richtigen Spieler gesetzt werden',async()=>{
      const wrongPath=`${joni.profile.id}/11111111-1111-4111-8111-111111111111.webp`;
      await assert.rejects(callRpc(db,'app_finish_avatar_upload',{p_session_token:flo.session.token,p_path:wrongPath,p_bytes:100},'service_role'),/AVATAR_INVALID/);
      const path=`${flo.profile.id}/11111111-1111-4111-8111-111111111111.webp`;
      const uploaded=await callRpc(db,'app_finish_avatar_upload',{p_session_token:flo.session.token,p_path:path,p_bytes:100},'service_role');
      assert.equal(uploaded.profile.avatarPath,path);
      const removed=await callRpc(db,'remove_player_avatar',{p_session_token:flo.session.token,p_expected_revision:uploaded.profile.revision});
      assert.equal(removed.profile.avatarPath,null);
    });
    await t.test('Sitzungen laufen aus, werden verlängert und Logout ist idempotent',async()=>{
      await db.query("update dungeon_private.player_sessions set last_seen_at=now()-interval '2 days',expires_at=now()+interval '2 days' where id=$1",[flo.session.id]);
      const renewed=await callRpc(db,'validate_player_session',{p_session_token:flo.session.token});
      assert.ok(new Date(renewed.expiresAt).getTime()>Date.now()+170*86400000);
      await db.query("update dungeon_private.player_sessions set expires_at=now()-interval '1 second' where id=$1",[joni.session.id]);
      await assert.rejects(callRpc(db,'get_player_profile',{p_session_token:joni.session.token}),/SESSION_INVALID/);
      await callRpc(db,'logout_player_session',{p_session_token:flo.session.token});
      await callRpc(db,'logout_player_session',{p_session_token:flo.session.token});
      await assert.rejects(callRpc(db,'get_player_profile',{p_session_token:flo.session.token}),/SESSION_INVALID/);
    });
    await t.test('Veröffentlichte Definitionen sind unveränderbar',async()=>{
      const map=(await db.query("insert into public.dungeon_maps(name,created_by,updated_by) values('Testmap',$1,$1) returning id",[flo.profile.id])).rows[0].id;
      const version=(await db.query("insert into public.dungeon_map_versions(map_id,name,document,compiled_graph,allowed_powerups,content_hash,published_by) values($1,'Testmap','{}','{}','[]','test',$2) returning id",[map,flo.profile.id])).rows[0].id;
      versionId=version;
      await assert.rejects(db.query("update public.dungeon_map_versions set name='bad' where id=$1",[version]),/PUBLISHED_MAP_IMMUTABLE/);
      await assert.rejects(db.query('delete from public.dungeon_map_versions where id=$1',[version]),/PUBLISHED_MAP_IMMUTABLE/);
    });
    await t.test('Erstbesieger sind eindeutig; echte Ergebnisse liefern korrekte Statistiken und Gleichstände',async()=>{
      await db.query("insert into public.dungeon_map_cells(version_id,cell_id,kind,x,y,w,h,definition) values($1,'boss','boss',0,0,16,8,'{}')",[versionId]);
      for (let i=0;i<2;i++) {
        const game=(await db.query("insert into public.dungeon_games(name,host_id,map_version_id,status) values('Testspiel',$1,$2,'finished') returning id",[flo.profile.id,versionId])).rows[0].id;
        await db.query('insert into public.dungeon_game_players(game_id,player_id,seat) values($1,$2,0),($1,$3,1)',[game,flo.profile.id,joni.profile.id]);
        if (i===0) {
          await db.query("insert into public.dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values($1,$2,'boss',$3,1)",[game,versionId,flo.profile.id]);
          await assert.rejects(db.query("insert into public.dungeon_game_monster_claims(game_id,map_version_id,monster_cell_id,first_player_id,claimed_in_round) values($1,$2,'boss',$3,1)",[game,versionId,joni.profile.id]),/duplicate key/);
        }
        await db.query('insert into public.dungeon_game_results(game_id,player_id,total_points,diamonds,life_penalty,monsters_defeated,won) values($1,$2,$3,$4,$5,$6,true)',[game,flo.profile.id,i===0 ? 30 : 12,i===0 ? 10 : 5,i===0 ? 0 : -3,i===0 ? 4 : 2]);
        await db.query('insert into public.dungeon_game_results(game_id,player_id,total_points,won) values($1,$2,$3,$4)',[game,joni.profile.id,i===0 ? 24 : 12,i===1]);
      }
      const login=await callRpc(db,'login_player',{p_username:'flo',p_password:'testing42'});
      assert.deepEqual(login.profile.stats,{gamesPlayed:2,totalPoints:42,averagePoints:21,wins:2,monstersDefeated:6});
    });
    await t.test('Anmeldeversuche werden begrenzt, ohne die erfolgreiche Sitzung zu verändern',async()=>{
      await db.exec('delete from dungeon_private.auth_attempts');
      for (let i=0;i<15;i++) assert.equal((await callRpc(db,'login_player',{p_username:'nobody',p_password:'incorrect'})).error,'LOGIN_INVALID');
      assert.equal((await callRpc(db,'login_player',{p_username:'nobody',p_password:'incorrect'})).error,'RATE_LIMIT');
      await db.exec('update dungeon_private.app_config set registration_enabled=false where singleton');
      assert.equal((await register('newfriend')).error,'REGISTRATION_CLOSED');
      assert.equal((await callRpc(db,'login_player',{p_username:'flo',p_password:'testing42'})).ok,true);
    });
  } finally {await db.close();}
});
