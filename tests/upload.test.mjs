import test from 'node:test';
import assert from 'node:assert/strict';
import {createHandler,isWebP} from '../supabase/functions/avatar-upload/index.ts';

const id='11111111-1111-4111-8111-111111111111',token='b'.repeat(64);
const secret='sb_secret_test_server_only';
const env=name=>({SUPABASE_URL:'https://test.supabase.co',SUPABASE_SECRET_KEYS:JSON.stringify({default:secret})})[name];
const bytes=Uint8Array.from([82,73,70,70,20,0,0,0,87,69,66,80,86,80,56,32,0,0,0,0]);
function request({file=new Blob([bytes],{type:'image/webp'}),headers={},method='POST'}={}) {
  const form=new FormData();form.append('file',file,'avatar.webp');
  return new Request('https://function.example',{method,headers:{'x-session-token':token,...headers},body:method==='POST' ? form : undefined});
}
function mockFetch(log,{commitError=false,uncertainCommit=false}={}) {
  return async(url,options)=>{
    log.push({url,options});
    if (url.includes('validate_player_session')) return Response.json({ok:true,profile:{id}});
    if (url.includes('app_finish_avatar_upload')) {
      if (uncertainCommit) throw TypeError('network after commit');
      if (commitError) return Response.json({message:'SESSION_INVALID'},{status:400});
      return Response.json({ok:true,oldPath:`${id}/old.webp`,profile:{id,avatarPath:`${id}/new.webp`}});
    }
    if (url.includes('remove_player_avatar')) return Response.json({ok:true,oldPath:`${id}/old.webp`,profile:{id,avatarPath:null}});
    return Response.json({ok:true});
  };
}
test('WebP-Signatur wird vor dem Upload geprüft',()=>{
  assert.equal(isWebP(bytes),true);assert.equal(isWebP(new Uint8Array(20)),false);
});
test('Fehlende Sitzung und fremde Origins werden vor jedem Serverzugriff abgefangen',async()=>{
  let calls=0;
  const handler=createHandler({env,fetcher:()=>{calls++;throw Error();}});
  assert.equal((await handler(request({headers:{'x-session-token':''}}))).status,401);
  assert.equal((await handler(request({method:'GET'}))).status,405);assert.equal(calls,0);
  const restricted=createHandler({env:name=>name==='ALLOWED_ORIGINS' ? 'https://friends.example' : env(name)});
  assert.equal((await restricted(request({headers:{Origin:'https://evil.example'}}))).status,403);
});
test('Erlaubter Upload: Sitzung prüfen, speichern, Profil aktualisieren, altes Bild aufräumen',async()=>{
  const log=[],handler=createHandler({env,fetcher:mockFetch(log),uuid:()=>id});
  const result=await handler(request());assert.equal(result.status,200);
  const data=await result.json();assert.equal(data.profile.id,id);assert.ok(!JSON.stringify(data).includes(secret));
  assert.equal(log.length,4);assert.ok(log[0].url.includes('validate_player_session'));
  assert.equal(log[1].options.headers['Content-Type'],'image/webp');
  assert.equal(log[1].options.headers.Authorization,undefined);assert.equal(log[1].options.headers.apikey,secret);
  assert.equal(log[3].options.method,'DELETE');
});
test('Falsche Datei und zu große Datei werden nicht gespeichert',async()=>{
  for (const file of [new Blob(['bad'],{type:'image/webp'}),new Blob([bytes],{type:'image/png'}),new Blob([new Uint8Array(524289)],{type:'image/webp'})]) {
    const log=[],handler=createHandler({env,fetcher:mockFetch(log)});
    const response=await handler(request({file}));assert.ok([400,413].includes(response.status));assert.equal(log.length,1);
  }
});
test('Bestätigt ungültige Sitzung beim Commit entfernt nur das neue Bild',async()=>{
  const log=[],handler=createHandler({env,fetcher:mockFetch(log,{commitError:true}),uuid:()=>id});
  assert.equal((await handler(request())).status,401);assert.equal(log[3].options.method,'DELETE');
});
test('Unklarer Commit nach Netzwerkfehler löscht kein möglicherweise aktives Bild',async()=>{
  const log=[],handler=createHandler({env,fetcher:mockFetch(log,{uncertainCommit:true}),uuid:()=>id});
  assert.equal((await handler(request())).status,503);assert.equal(log.length,3);
});
test('CORS-Preflight und fehlende Serverkonfiguration',async()=>{
  const handler=createHandler({env:()=>undefined});
  assert.equal((await handler(request({method:'OPTIONS'}))).status,204);
  assert.equal((await handler(request())).status,503);
});
test('Profilbild entfernen löscht nach erfolgreichem Commit auch das Storage-Objekt',async()=>{
  const log=[],handler=createHandler({env,fetcher:mockFetch(log)});
  const response=await handler(new Request('https://function.example',{
    method:'POST',headers:{'x-session-token':token,'Content-Type':'application/json'},
    body:JSON.stringify({action:'remove',revision:3}),
  }));
  assert.equal(response.status,200);assert.equal((await response.json()).profile.avatarPath,null);
  assert.equal(log.length,3);assert.equal(log[2].options.method,'DELETE');
});
