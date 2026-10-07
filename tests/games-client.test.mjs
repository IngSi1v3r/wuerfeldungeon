import test from 'node:test';
import assert from 'node:assert/strict';
import {GameCommands} from '../web/js/games/commands.js';
import {RealtimeSignals} from '../web/js/games/realtime.js';

test('Spielbefehle: verlorene Antwort wird mit identischer UUID wiederholt',async()=>{
 const calls=[],api={authRpc:async(name,params)=>{calls.push({name,params});if(calls.length===1)throw Object.assign(Error('lost'),{code:'NETWORK'});return {ok:true};}};
 const commands=new GameCommands(api);assert.equal((await commands.run('create_game',{p_name:'Abend'})).ok,true);assert.equal(calls.length,2);assert.deepEqual(calls[0],calls[1]);assert.match(calls[0].params.p_request_id,/^[a-f0-9-]{36}$/);
});
test('Spielbefehle: manueller Retry und geänderte Eingaben teilen keine falsche UUID',async()=>{
 const calls=[],api={authRpc:async(_,params)=>{calls.push(params);throw Object.assign(Error('lost'),{code:'NETWORK'});}},commands=new GameCommands(api);
 await assert.rejects(commands.run('create_game',{p_name:'Abend'}));await assert.rejects(commands.run('create_game',{p_name:'Abend'}));assert.equal(calls[0].p_request_id,calls[3].p_request_id);
 await assert.rejects(commands.run('create_game',{p_name:'Morgen'}));assert.notEqual(calls[3].p_request_id,calls[4].p_request_id);
});
test('Spielbefehle: gleichzeitiger Doppelklick führt nur eine Aktion aus',async()=>{
 let finish;const commands=new GameCommands({authRpc:()=>new Promise(resolve=>finish=resolve)}),first=commands.run('start_game',{p_game_id:'test'});
 await assert.rejects(commands.run('start_game',{p_game_id:'test'}),/vorige Aktion/);finish({ok:true});await first;assert.equal(commands.busy,false);
});
test('Spielbefehle: auch eine unlesbare Serverantwort behält die UUID bis zur Klärung',async()=>{
 const calls=[],commands=new GameCommands({authRpc:async(_,params)=>{calls.push(params);throw Object.assign(Error('unreadable'),{code:'SERVER_ERROR'});}});
 await assert.rejects(commands.run('create_game',{p_name:'Abend'}));await assert.rejects(commands.run('create_game',{p_name:'Abend'}));assert.equal(calls[0].p_request_id,calls[3].p_request_id);
});
function socketFactory(sockets){return url=>{const s={url,readyState:0,sent:[],send(message){this.sent.push(JSON.parse(message));},close(){this.readyState=3;this.onclose?.();},open(){this.readyState=1;this.onopen?.();},receive(data){this.onmessage?.({data:JSON.stringify(data)});}};sockets.push(s);return s;};}
function acknowledge(s) {for(const m of s.sent.filter(m=>m.event==='phx_join'))s.receive({topic:m.topic,event:'phx_reply',ref:m.ref,payload:{status:'ok',response:{}}});}
test('Realtime: dokumentiertes öffentliches Protokoll, keine Sitzung und keine Tabellen-Abos',()=>{
 const sockets=[],states=[],signals=[],realtime=new RealtimeSignals(['dungeon:lobbies','dungeon:game:test'],{socketFactory:socketFactory(sockets),onState:s=>states.push(s),onSignal:()=>signals.push(1)});
 try{realtime.start();const s=sockets[0];assert.match(s.url,/vsn=1\.0\.0/);assert.match(s.url,/apikey=sb_publishable_/);s.open();assert.equal(s.sent.length,2);
  for(const msg of s.sent){assert.equal(msg.event,'phx_join');assert.equal(msg.payload.config.private,false);assert.deepEqual(msg.payload.config.postgres_changes,[]);assert.equal(msg.payload.access_token,undefined);}
  acknowledge(s);assert.equal(states.at(-1),'connected');assert.equal(signals.length,1);
  s.receive({topic:'realtime:dungeon:lobbies',event:'broadcast',payload:{event:'changed',type:'broadcast',payload:{}}});assert.equal(signals.length,2);
  s.receive({topic:'realtime:unknown',event:'broadcast',payload:{event:'changed'}});assert.equal(signals.length,2);
 }finally{realtime.stop();}
});
test('Realtime: Join-Fehler aktivieren Rückfall, Stop beendet alle Verbindungen',()=>{
 const sockets=[],states=[],r=new RealtimeSignals(['dungeon:lobbies'],{socketFactory:socketFactory(sockets),onState:s=>states.push(s)});
 r.start();sockets[0].open();sockets[0].receive({event:'phx_reply',ref:sockets[0].sent[0].ref,payload:{status:'error'}});assert.equal(states.at(-1),'fallback');assert.equal(sockets[0].readyState,3);r.stop();assert.equal(r.socket,null);assert.equal(r.stopped,true);
});
test('Realtime: fehlende Heartbeat-Antwort führt zur Wiederverbindung',async t=>{
 t.mock.timers.enable({apis:['setTimeout','setInterval']});const sockets=[],states=[],r=new RealtimeSignals(['dungeon:lobbies'],{socketFactory:socketFactory(sockets),onState:s=>states.push(s),heartbeatMs:100,joinTimeoutMs:400,reconnectBaseMs:20});
 try{r.start();const s=sockets[0];s.open();acknowledge(s);t.mock.timers.tick(100);assert.equal(s.sent.at(-1).event,'heartbeat');t.mock.timers.tick(100);assert.equal(states.at(-1),'fallback');t.mock.timers.tick(20);assert.equal(sockets.length,2);sockets[1].open();acknowledge(sockets[1]);assert.equal(states.at(-1),'connected');}
 finally{r.stop();t.mock.timers.reset();}
});
test('Realtime: rechtzeitige Heartbeat-Antwort erhält die Verbindung',async t=>{
 t.mock.timers.enable({apis:['setTimeout','setInterval']});const sockets=[],r=new RealtimeSignals(['dungeon:lobbies'],{socketFactory:socketFactory(sockets),heartbeatMs:100,joinTimeoutMs:400});
 try{r.start();const s=sockets[0];s.open();acknowledge(s);t.mock.timers.tick(100);const heart=s.sent.at(-1);s.receive({event:'phx_reply',ref:heart.ref,payload:{status:'ok'}});t.mock.timers.tick(100);assert.equal(s.readyState,1);assert.equal(sockets.length,1);}
 finally{r.stop();t.mock.timers.reset();}
});
