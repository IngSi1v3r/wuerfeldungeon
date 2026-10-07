import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeUsername,validateUsername,validatePassword,validateDisplayName,cleanPreferences,initials,safeAvatarUrl} from '../web/js/validation.js';
import {SessionStore,deviceLabel,sessionTokenFromRaw} from '../web/js/session.js';
import {Api,AppError} from '../web/js/api.js';

const token='a'.repeat(64);
function storage() {
  const values=new Map();
  return {getItem:key=>values.get(key) ?? null,setItem:(key,value)=>values.set(key,value),removeItem:key=>values.delete(key)};
}

test('Spielernamen und Unicode-Grenzen',()=>{
  assert.equal(normalizeUsername(' FLO_Test '),'flo_test');
  assert.equal(validateUsername('Flo-Test'),'');
  for (const value of ['ab','ü','a b','a'.repeat(33)]) assert.ok(validateUsername(value));
  assert.equal(validateDisplayName('Johanna 🐉'),'');
  assert.equal(validateDisplayName('🐉'.repeat(40)),'');
  assert.ok(validateDisplayName('🐉'.repeat(41)));
  assert.ok(validateDisplayName('   '));
  assert.equal(validatePassword('sicher42'),'');
  assert.ok(validatePassword('12345'));
  assert.ok(validatePassword('ä'.repeat(37)));
});
test('Einstellungen erlauben nur definierte Werte',()=>{
  assert.deepEqual(cleanPreferences({markStyle:'evil',sound:'true',music:true,reduceMotion:true,extra:'x'}),{markStyle:'cross',sound:true,music:true,reduceMotion:true});
  assert.equal(initials('Johanna Winter'),'JW');
  assert.equal(initials(''),'?');
  assert.equal(safeAvatarUrl('https://x','../private'),null);
  assert.ok(safeAvatarUrl('https://x/','a'.repeat(36)+'/'+'b'.repeat(36)+'.webp').startsWith('https://x/storage/'));
});
test('Sitzung wird ohne Passwort gespeichert und wieder geladen',()=>{
  const memory=storage(),first=new SessionStore(memory);
  assert.equal(first.read(),null);
  assert.equal(first.save({token,id:'id',expiresAt:'later',password:'NEVER'}),true);
  const second=new SessionStore(memory);
  assert.deepEqual(second.read(),{token,id:'id',expiresAt:'later'});
  first.clear();assert.equal(new SessionStore(memory).read(),null);
  assert.throws(()=>first.save({token:'broken'}));
});
test('Gesperrter Browser-Speicher verhindert nicht die Anmeldung',()=>{
  const store=new SessionStore({getItem(){throw Error();},setItem(){throw Error();},removeItem(){throw Error();}});
  assert.equal(store.save({token}),false);assert.equal(store.read().token,token);
  store.clear();assert.equal(store.read(),null);
});
test('Gerätebezeichnungen sind lesbar',()=>{
  assert.equal(deviceLabel('Windows Chrome/123'),'Windows · Chrome');
  assert.equal(deviceLabel('iPhone Safari/12'),'iPhone / iPad · Safari');
});
test('Sitzungsmetadaten sind von einem tatsächlichen Identitätswechsel unterscheidbar',()=>{
  assert.equal(sessionTokenFromRaw(JSON.stringify({token,expiresAt:'later'})),token);
  assert.equal(sessionTokenFromRaw(JSON.stringify({token,expiresAt:'even-later'})),token);
  assert.equal(sessionTokenFromRaw(null),null);assert.equal(sessionTokenFromRaw('{broken'),null);
});
test('RPC benutzt apikey, aber keinen falschen Bearer-Publishable-Key',async()=>{
  const store=new SessionStore(storage());store.save({token});let captured;
  const api=new Api(store,{fetcher:async(url,options)=>{captured={url,options};return new Response(JSON.stringify({ok:true}),{status:200});}});
  await api.authRpc('get_player_profile');
  assert.equal(captured.options.headers.Authorization,undefined);
  assert.ok(captured.options.headers.apikey.startsWith('sb_publishable_'));
  assert.equal(JSON.parse(captured.options.body).p_session_token,token);
  assert.equal(captured.options.credentials,'omit');
});
test('Ungültige Sitzung wird erkannt, Netzwerkfehler melden NICHT ab',async()=>{
  const store=new SessionStore(storage());store.save({token});let invalid=0;
  const api=new Api(store,{onInvalidSession:()=>invalid++,fetcher:async()=>new Response(JSON.stringify({message:'SESSION_INVALID'}),{status:400})});
  await assert.rejects(api.authRpc('get_player_profile'),error=>error instanceof AppError && error.code==='SESSION_INVALID');
  assert.equal(invalid,1);
  api.fetcher=async()=>{throw TypeError('fetch failed');};
  await assert.rejects(api.authRpc('get_player_profile'),error=>error.code==='NETWORK');
  assert.equal(invalid,1);assert.equal(store.read().token,token);
});
test('Fehlende Migrationen liefern eine handlungsfähige Meldung',async()=>{
  const api=new Api(new SessionStore(storage()),{fetcher:async()=>new Response(JSON.stringify({code:'PGRST202'}),{status:404})});
  await assert.rejects(api.status(),error=>error.code==='APP_NOT_INSTALLED' && error.message.includes('SETUP.md'));
});
test('Schreiboperationen werden nicht automatisch wiederholt',async()=>{
  let calls=0;
  const api=new Api(new SessionStore(storage()),{fetcher:async()=>{calls++;throw TypeError('offline');}});
  await assert.rejects(api.rpc('register_player',{p_password:'test-secret'}));
  assert.equal(calls,1);
});
