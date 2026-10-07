// Zwei echte Browserkontexte, lokales PostgreSQL und Bilder im Spielplan.
// Supabase-Transport und Testwürfel sind ausschließlich lokal ersetzt.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {classicFixture} from './helpers/classic-game.mjs';
import {createStabilityDatabase} from './helpers/stability.mjs';
import {installTestDice,forceDice,newPlayGame,seedState} from './helpers/turns.mjs';
import {CONFIG} from '../web/js/config.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),address='http://localhost:5194';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5194'},stdio:'ignore'}),db=await createStabilityDatabase(),sockets=new Set(),errors=[],requests=[];
let queue=Promise.resolve(),lastSignal=0,browser,activePage,checks=0,png,assetRequests=0;
const serial=fn=>{const result=queue.then(fn);queue=result.catch(()=>{});return result;};
function check(value,label){assert.ok(value,label);checks++;console.log(`PASS ${label}`);}
async function signals(){const rows=(await db.query('select * from realtime.test_signals where id>$1 order by id',[lastSignal])).rows;for(const signal of rows){lastSignal=signal.id;for(const socket of sockets)if(socket.topics.has(`realtime:${signal.topic}`))socket.ws.send(JSON.stringify({topic:`realtime:${signal.topic}`,event:'broadcast',payload:{type:'broadcast',event:'changed',payload:signal.payload},ref:null}));}}
async function rpc(user,name,args={}){return serial(async()=>{const result=await userRpc(db,user,name,args);await signals();return result;});}
async function gateway(context,flags){
 context.on('page',page=>page.on('pageerror',e=>errors.push(e.message)));
 await context.routeWebSocket(url=>url.href.startsWith(CONFIG.supabaseUrl.replace('https:','wss:')+'/realtime/'),ws=>{
  const socket={ws,topics:new Set()};sockets.add(socket);ws.onClose(()=>sockets.delete(socket));ws.onMessage(text=>{const m=JSON.parse(text.toString());if(m.event==='phx_join'){socket.topics.add(m.topic);ws.send(JSON.stringify({topic:m.topic,event:'phx_reply',ref:m.ref,join_ref:m.join_ref,payload:{status:'ok',response:{}}}));}else if(m.event==='heartbeat')ws.send(JSON.stringify({topic:'phoenix',event:'phx_reply',ref:m.ref,payload:{status:'ok',response:{}}}));});
 });
 await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
  const req=route.request(),headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,GET,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
  if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
  if(new URL(req.url()).pathname.startsWith('/storage/v1/object/public/map-assets/')){assetRequests++;await route.fulfill({status:200,headers:{...headers,'content-type':'image/png'},body:png});return;}
  const method=new URL(req.url()).pathname.split('/').at(-1),args=req.postDataJSON();requests.push({method,args});
  try{const data=await serial(async()=>{const value=await callRpc(db,method,args);await signals();return value;});
   if(data.ok&&method==='resolve_game_wait'&&flags.dropWait){flags.dropWait=false;await route.abort('failed');return;}
   await route.fulfill({status:200,headers,body:JSON.stringify(data)});
  }catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
 });
}
async function login(page,name){await page.goto(address);await page.locator('#auth-form').waitFor();await page.fill('#username',name);await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();}
async function open(page,id){await page.goto(address+`/#/game?id=${id}`);await page.locator('#game-board-svg').waitFor({timeout:25000});await page.locator('.opponent-miniature').waitFor();}
const cell=(page,id)=>page.locator(`#gameTargets [data-cell-id="${id}"]`);
const get=async(user,id)=>(await rpc(user,'get_game',{p_game_id:id})).game;
async function refresh(page){await Promise.all([page.waitForResponse(r=>r.url().endsWith('/rpc/get_game')&&r.status()===200),page.evaluate(()=>document.querySelector('#refresh-game').click())]);await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));}
async function age(id,field){assert.ok(['choice_started_at','roll_wait_started_at'].includes(field));await serial(()=>db.query(`update dungeon_games set ${field}=now()-interval '61 seconds' where id=$1`,[id]));}
async function play(page,id){await cell(page,id).focus();await cell(page,id).press('Enter');}

try{
 await installTestDice(db);const flo=await register(db,'Flo'),joni=await register(db,'Joni');
 await mkdir(root+'/test-results',{recursive:true});for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const desktop=await browser.newContext({viewport:{width:1440,height:1040}}),phoneContext=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true}),df={dropWait:false},pf={dropWait:false};
 await gateway(desktop,df);await gateway(phoneContext,pf);const page=await desktop.newPage(),phone=await phoneContext.newPage();activePage=page;
 png=Buffer.from(await page.evaluate(()=>{const c=document.createElement('canvas');c.width=96;c.height=96;const ctx=c.getContext('2d');ctx.fillStyle='#b7c9b2';ctx.fillRect(0,0,96,96);ctx.fillStyle='#49725b';ctx.beginPath();ctx.arc(48,48,38,0,Math.PI*2);ctx.fill();return c.toDataURL('image/png').split(',')[1];}),'base64');
 const path=`${randomUUID()}/${randomUUID()}.png`;await db.query("insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values($1,'map',$2,'image/png',$3)",[path,flo.profile.id,png.length]);
 const d=classicFixture(),image={src:`asset:${path}`,width:96,height:96,name:'Testbild'};d.background={x:-4,y:-4,w:48,h:20,image};d.rooms.find(r=>r.id===5).image=image;d.rooms.find(r=>r.id===5).imageLayout={x:0,y:0,w:8,h:8};
 const map=await publishFixture(db,flo,'Stabile Bildkarte',d),id=await serial(()=>newPlayGame(db,[flo,joni],{cards:'open'},map));
 await serial(()=>seedState(db,id,flo,{reached:['1','2','3','4']}));await serial(()=>seedState(db,id,joni,{reached:['1','2','3','4']}));
 await login(page,'flo');await login(phone,'joni');await open(page,id);await open(phone,id);
 check(await page.locator('#game-board-svg image').count()===2&&await phone.locator('#game-board-svg image').count()===2,'Hintergrund und Monsterbild sind auf PC und Handy geladen');
 await serial(()=>forceDice(db,[4,4,1,2]));await page.click('#roll-dice');await phone.waitForFunction(()=>document.querySelectorAll('#game-dice .dice-face').length===4);
 await page.getByRole('button',{name:'Vergrößern',exact:true}).click();await cell(page,5).focus();
 const assetBefore=assetRequests;
 await page.evaluate(()=>{
  const board=document.querySelector('#game-board-svg');window.__stable={board,viewBox:board.getAttribute('viewBox'),images:[...board.querySelectorAll('image')],mark:board.querySelector('[data-marked-cell="1"]'),target:board.querySelector('[data-cell-id="5"]'),
   mini:document.querySelector('.opponent-miniature svg'),miniImages:[...document.querySelectorAll('.opponent-miniature image')],face:document.querySelector('#game-dice .dice-face'),score:document.querySelector('#own-points'),life:document.querySelector('.life-box'),removed:0};
  window.__observer=new MutationObserver(records=>{for(const r of records)for(const n of r.removedNodes)if(n.nodeType===1&&(n.matches('image,[data-marked-cell]')||n.querySelector('image,[data-marked-cell]')))window.__stable.removed++;});
  window.__observer.observe(document.querySelector('#game-content'),{childList:true,subtree:true});
 });
 for(let i=0;i<3;i++)await refresh(page);
 const stable=await page.evaluate(()=>{const s=window.__stable,b=document.querySelector('#game-board-svg');return {board:b===s.board,view:b.getAttribute('viewBox')===s.viewBox,images:s.images.every(n=>n.isConnected),mark:b.querySelector('[data-marked-cell="1"]')===s.mark,focus:document.activeElement===s.target,
  mini:document.querySelector('.opponent-miniature svg')===s.mini,miniImages:s.miniImages.every(n=>n.isConnected),face:document.querySelector('#game-dice .dice-face')===s.face,score:document.querySelector('#own-points')===s.score,life:document.querySelector('.life-box')===s.life,removed:s.removed};});
 check(stable.board&&stable.view&&stable.focus,'Aktualisieren bewahrt Spielplan, Zoom und Feldfokus');check(stable.images&&stable.mark&&stable.mini&&stable.miniImages&&stable.removed===0,'Polling entfernt keine Bilder, Markierungen oder Gegnervorschauen');check(stable.face&&stable.score&&stable.life,'Unveränderte Würfel, Punktestand und Leben bleiben im DOM');check(assetRequests===assetBefore,'Aktualisieren lädt keine Kartenbilder erneut');
 await play(phone,5);await page.waitForFunction(()=>document.querySelector('.opponent-miniature .enemy-info[data-id="5"] [data-hit="1"]')?.getAttribute('fill')==='#375b48');
 check(await page.evaluate(()=>window.__stable.images.every(n=>n.isConnected)&&document.querySelector('.opponent-miniature svg')===window.__stable.mini&&window.__stable.miniImages.every(n=>n.isConnected)&&document.querySelector('#game-dice .dice-face')===window.__stable.face),'Fremder Livezug aktualisiert Treffer ohne Bilder oder Würfel neu aufzubauen');
 await play(page,5);await phone.locator('#roll-dice').waitFor();check((await get(flo,id)).round===2,'Gezielte Darstellung verarbeitet weiterhin den Rundenwechsel');
 await page.locator('.opponent-miniature').click();await page.locator('#opponent-board-svg').waitFor();await refresh(page);check(await page.locator('#opponent-board-svg .enemy-info[data-id="5"] [data-hit="1"]').getAttribute('fill')==='#375b48','Vergrößerte Gegnerkarte bleibt mit dem neuen Rendering korrekt');await page.locator('.opponent-dialog').getByRole('button',{name:'Schließen',exact:true}).click();
 // Den gemeldeten Hänger vollständig durch die Oberfläche reproduzieren.
 const skipped=await serial(()=>newPlayGame(db,[flo,joni],{cards:'open'},map));await open(page,skipped);await open(phone,skipped);await serial(()=>forceDice(db,[2,3,4,5]));await page.click('#roll-dice');await play(page,1);await page.locator('#game-board-svg [data-marked-cell="1"]').waitFor();
 await age(skipped,'choice_started_at');await refresh(page);await page.locator('.player-wait-button:not([hidden]):not(:disabled)').first().click();await page.locator('#wait-management:not([hidden])').waitFor();page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Zug überspringen',exact:true}).click();await phone.locator('#roll-dice').waitFor();check((await get(flo,skipped)).rollerId===joni.profile.id,'Ein übersprungener Zug führt regulär zum Wurf dieses Spielers');
 await age(skipped,'roll_wait_started_at');await refresh(page);await page.locator('.player-wait-button:not([hidden]):not(:disabled)').first().click();await page.locator('#wait-management:not([hidden])').waitFor();check(await page.getByRole('button',{name:'Wurf weitergeben',exact:true}).count()===1,'Host bekommt auch für den fehlenden Wurf eine Entscheidung');check(await phone.locator('#wait-management:not([hidden])').count()===0,'Nur der Host sieht die Wartesteuerung');
 await page.getByRole('button',{name:'Weiter warten',exact:true}).click();check(await page.locator('#wait-management[hidden]').count()===1&&(await get(flo,skipped)).rollerId===joni.profile.id,'Weiter warten ändert den Spielstand nicht');
 // Wieder öffnen mit neuer Hostansicht; Warteentscheidung ist nicht automatisch.
 await page.reload();await page.locator('#game-board-svg').waitFor({timeout:25000});await page.locator('.player-wait-button:not([hidden]):not(:disabled)').first().click();await page.locator('#wait-management:not([hidden])').waitFor();df.dropWait=true;page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Wurf weitergeben',exact:true}).click();await page.locator('#roll-dice').waitFor();
 const waitRequests=requests.filter(r=>r.method==='resolve_game_wait'&&r.args.p_game_id===skipped&&r.args.p_round===2);check(waitRequests.length===2&&waitRequests[0].args.p_request_id===waitRequests[1].args.p_request_id,'Verlorene Antwort gibt denselben Wurf genau einmal weiter');
 let g=await get(flo,skipped);check(g.round===2&&g.rollerId===flo.profile.id&&g.participants.length===2&&(await get(joni,skipped)).ownState.lostLives===0,'Wurfweitergabe behält Runde, Teilnehmer und Lebensstand');
 await serial(()=>forceDice(db,[2,3,4,5]));await page.click('#roll-dice');await phone.waitForFunction(()=>document.querySelector('#gameTargets [data-cell-id="1"]')?.getAttribute('aria-disabled')==='false');await play(phone,1);await phone.locator('#game-board-svg [data-marked-cell="1"]').waitFor();check((await get(joni,skipped)).ownState.reached.includes('1'),'Zurückgekehrter Spieler kann nach dem weitergegebenen Wurf normal ziehen');
 await play(page,2);await page.locator('.powerup-dialog').waitFor();await page.locator('[data-powerup="redDice"]').click();await phone.locator('#roll-dice').waitFor();
 await age(skipped,'roll_wait_started_at');await refresh(page);await page.locator('.player-wait-button:not([hidden]):not(:disabled)').first().click();await page.locator('#wait-management:not([hidden])').waitFor();page.once('dialog',dialog=>dialog.accept());await page.locator('#wait-management').getByRole('button',{name:'Entfernen',exact:true}).click();await page.locator('#roll-dice').waitFor();check((await get(flo,skipped)).participants.length===1&&(await get(flo,skipped)).rollerId===flo.profile.id,'Entfernen des ausstehenden Würflers setzt das Spiel fort');
 await page.screenshot({path:root+'/test-results/stability-desktop.png',fullPage:true});await phone.screenshot({path:root+'/test-results/stability-handy.png',fullPage:true});
 check(errors.length===0,'Keine JavaScriptfehler auf PC oder Handy');console.log(`${checks} Stabilitäts-Browserprüfungen erfolgreich.`);
}catch(error){console.error(error.message);if(activePage)await activePage.screenshot({path:root+'/test-results/stability-error.png',fullPage:true}).catch(()=>{});throw error;}
finally{await browser?.close();server.kill();await queue;await db.close();}
