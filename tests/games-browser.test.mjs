// Echte App + PostgreSQL + dokumentiertes WebSocket-Protokoll. Nur das
// Supabase-Gateway, Storage und Realtime-Transport werden lokal simuliert.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {createGamesDatabase,register,userRpc,publishFixture,gameFixture} from './helpers/games.mjs';
import {CONFIG} from '../web/js/config.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),address='http://localhost:5191';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5191'},stdio:'ignore'});
const db=await createGamesDatabase(),sockets=new Set(),objects=new Map(),errors=[],wire=[],creates=[];let queue=Promise.resolve(),lastSignal=0,browser,activePage,checks=0,dropCreate=true;
const serial=fn=>{const result=queue.then(fn);queue=result.catch(()=>{});return result;};
function check(value,label){assert.ok(value,label);checks++;console.log(`PASS ${label}`);}
async function signals(){const rows=(await db.query('select * from realtime.test_signals where id>$1 order by id',[lastSignal])).rows;for(const signal of rows){lastSignal=signal.id;for(const socket of sockets)if(socket.topics.has(`realtime:${signal.topic}`)&&!socket.flags.offline&&!socket.flags.blockRealtime)socket.ws.send(JSON.stringify({topic:`realtime:${signal.topic}`,event:'broadcast',payload:{type:'broadcast',event:signal.event,payload:signal.payload},ref:null}));}}
async function rpc(user,name,args={}){return serial(async()=>{const data=await userRpc(db,user,name,args);await signals();return data;});}
async function gateway(context,flags={offline:false,blockRealtime:false}) {
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));
 await context.routeWebSocket(url=>url.href.startsWith(CONFIG.supabaseUrl.replace('https:','wss:')+'/realtime/'),ws=>{
  const socket={ws,topics:new Set(),flags};sockets.add(socket);
  if(flags.blockRealtime){sockets.delete(socket);ws.close({code:1001,reason:'test disconnect'});return;}
  ws.onMessage(text=>{const msg=JSON.parse(text.toString());wire.push(msg);if(msg.event==='phx_join'){socket.topics.add(msg.topic);ws.send(JSON.stringify({topic:msg.topic,event:'phx_reply',ref:msg.ref,join_ref:msg.join_ref,payload:{status:'ok',response:{}}}));}else if(msg.event==='heartbeat')ws.send(JSON.stringify({topic:'phoenix',event:'phx_reply',ref:msg.ref,payload:{status:'ok',response:{}}}));});
  ws.onClose(()=>{sockets.delete(socket);});
 });
 await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
  const req=route.request(),path=new URL(req.url()).pathname,headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,GET,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
  if(flags.offline){await route.abort('failed');return;}
  if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
  if(path.startsWith('/storage/v1/object/public/map-assets/')){const object=objects.get(path.split('/map-assets/')[1]);await route.fulfill({status:object?200:404,headers:{...headers,'content-type':object?.type||'text/plain'},body:object?.bytes||''});return;}
  try {const args=req.postDataJSON(),method=path.split('/').at(-1),data=await serial(async()=>{const r=await callRpc(db,method,args);await signals();return r;});
   if(method==='create_game'){creates.push(args);if(dropCreate){dropCreate=false;await route.abort('failed');return;}}
   await route.fulfill({status:200,headers,body:JSON.stringify(data)});
  }catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
 });
}
async function login(page,name){await page.goto(address);await page.locator('#auth-form').waitFor();await page.fill('#username',name);await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();}
const status=(page,text)=>page.waitForFunction(value=>document.querySelector('#game-status')?.textContent===value,text);
const hasRoom=page=>page.locator('#game-board-svg').waitFor({timeout:25000});
try {
 const flo=await register(db,'Flo'),joni=await register(db,'Joni'),mira=await register(db,'Mira');
 await mkdir(root+'/test-results',{recursive:true});
 for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const floContext=await browser.newContext({viewport:{width:1440,height:1040}}),floFlags={offline:false,blockRealtime:false};await gateway(floContext,floFlags);const page=await floContext.newPage();activePage=page;await login(page,'flo');
 const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=160;c.height=160;const x=c.getContext('2d');x.fillStyle='#709574';x.beginPath();x.ellipse(80,91,49,52,0,0,Math.PI*2);x.fill();x.fillStyle='#bccc92';x.beginPath();x.ellipse(80,55,37,30,0,0,Math.PI*2);x.fill();x.fillStyle='#173829';for(const a of [66,94]){x.beginPath();x.arc(a,51,5,0,Math.PI*2);x.fill();}return c.toDataURL('image/png').split(',')[1];});
 const path=`${randomUUID()}/${randomUUID()}.png`,bytes=Buffer.from(png,'base64');objects.set(path,{bytes,type:'image/png'});
 await serial(()=>db.query('insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values($1,\'map\',$2,\'image/png\',$3)',[path,flo.profile.id,bytes.length]));
 const doc=gameFixture();doc.rooms[4].image={src:`asset:${path}`,width:160,height:160,name:'Testtroll'};
 const map=await serial(()=>publishFixture(db,flo,'Lava Mine',doc));await rpc(flo,'create_map',{p_name:'Unfertige Karte'});
 await page.click('.menu-card[href="#/play"]');await page.locator('#lobby-list .game-empty').waitFor();check(await page.locator('.play-view').isVisible(),'Spielen öffnet die echte Auswahl mit Warteräumen und fortsetzbaren Spielen');
 await page.click('#new-game');await page.locator('.game-map-choice').waitFor();check(await page.locator('.game-map-choice').count()===1,'Neue Spiele bieten ausschließlich veröffentlichte Karten an');
 await page.locator('.game-map-choice').click();await page.fill('#game-name','Freunde in der Mine');await page.selectOption('#game-max-players','2');await page.fill('#game-password','mine42');await page.selectOption('#game-cards','hidden');await page.selectOption('#game-hints','false');await page.click('#create-game');await status(page,'Warteraum');
 const gameId=new URLSearchParams(page.url().split('?')[1]).get('id');check(creates.length===2&&creates[0].p_request_id===creates[1].p_request_id&&(await serial(()=>db.query('select count(*)::int n from dungeon_games'))).rows[0].n===1,'Verlorene Antwort bei Erstellung erzeugt keinen zweiten Warteraum');
 check((await page.locator('.game-heading').innerText()).includes('Verdeckte Karten')&&(await page.locator('.game-heading').innerText()).includes('Ohne Tipps'),'Karte und Einstellungen erscheinen im Warteraum korrekt');
 const joniContext=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true}),joniFlags={offline:false,blockRealtime:false};await gateway(joniContext,joniFlags);const phone=await joniContext.newPage();activePage=phone;await login(phone,'joni');await phone.click('.menu-card[href="#/play"]');await phone.locator('.game-card').waitFor();
 check((await phone.locator('.game-card').innerText()).includes('Flo')&&(await phone.locator('.game-card').innerText()).includes('1 / 2 Spieler'),'Anderer Spieler sieht Karte, Host, belegte Plätze und Passwortschutz');
 await phone.locator('.game-card button').click();await phone.fill('#join-password','falsch');await phone.click('#join-submit');await phone.locator('.join-form .feedback:not([hidden])').waitFor();check((await phone.locator('.join-form .feedback').innerText()).includes('stimmt nicht'),'Falsches Spielpasswort erhält eine verständliche Meldung');
 await phone.fill('#join-password','mine42');await phone.click('#join-submit');await status(phone,'Warteraum');await page.waitForFunction(()=>document.querySelector('#game-player-count')?.textContent==='2 / 2');
 check(await page.locator('.lobby-player').count()===2&&await phone.locator('#start-game').count()===0,'Beitritt wird automatisch per Realtime sichtbar; nur Host hat den Startknopf');
 await phone.screenshot({path:root+'/test-results/warteraum-handy.png',fullPage:true});check(await phone.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Warteraum passt ohne horizontales Überlaufen aufs Handy');
 await page.screenshot({path:root+'/test-results/warteraum-desktop.png',fullPage:true});
 const invitationContext=await browser.newContext();await gateway(invitationContext);const invited=await invitationContext.newPage();activePage=invited;await invited.goto(address+`/#/game?id=${gameId}`);await invited.locator('#auth-form').waitFor();await invited.reload();await invited.locator('#auth-form').waitFor();await invited.fill('#username','mira');await invited.fill('#password','testing42');await invited.click('#auth-submit');await invited.locator('.invited-game').waitFor();check(invited.url().endsWith(`#/game?id=${gameId}`),'Einladungslink bleibt über Anmeldung und Neuladen der Anmeldeseite erhalten');await invitationContext.close();
 const miraContext=await browser.newContext({viewport:{width:1100,height:900}});await gateway(miraContext);const other=await miraContext.newPage();activePage=other;await login(other,'mira');await other.click('.menu-card[href="#/play"]');await other.locator('.game-card').waitFor();check(await other.getByRole('button',{name:'Voll',exact:true}).isDisabled(),'Volle Warteräume erlauben keinen weiteren Beitritt');
 activePage=page;await page.click('#start-game');await status(page,'Laufend');await status(phone,'Laufend');await hasRoom(page);await hasRoom(phone);
 check(await page.locator('#game-players .opponent-seat').count()===1,'Nach Start sieht man im Spielraum nur die Mitspieler neben dem eigenen Spielplan');
 check(await page.locator('#game-board-svg .room').count()===doc.rooms.length&&await page.locator('#game-board-svg #doorsLayer').count()===0,'Spielraum zeigt die unveränderte Karte ohne Editor-Menüs und Durchgangsknöpfe');
 check(await page.locator('#game-board-svg .room.start .room-body').getAttribute('fill')==='rgb(217, 239, 197)','Startfelder behalten ihre grüne Füllung im Spielplan');
 check(await page.locator('#game-board-svg image').count()>0,'Monsterbild aus Supabase Storage erscheint auch im Spielraum');
 const boxBefore=await page.locator('#game-board-svg').getAttribute('viewBox');await page.getByRole('button',{name:'Vergrößern',exact:true}).click();check(await page.locator('#game-board-svg').getAttribute('viewBox')!==boxBefore,'Spielplan lässt sich vergrößern und an den Bildschirm anpassen');
 await page.locator('#game-board-svg').scrollIntoViewIfNeeded();const rect=await page.locator('#game-board-svg').boundingBox(),panBefore=await page.locator('#game-board-svg').getAttribute('viewBox');await page.mouse.move(rect.x+rect.width/2,rect.y+rect.height/2);await page.mouse.down();await page.mouse.move(rect.x+rect.width/2+60,rect.y+rect.height/2+40);await page.mouse.up();check(await page.locator('#game-board-svg').getAttribute('viewBox')!==panBefore,'Spielplan lässt sich mit der Maus verschieben');await page.getByRole('button',{name:'Alles zeigen',exact:true}).click();
 activePage=phone;await phone.locator('#game-board-svg').scrollIntoViewIfNeeded();const phoneRect=await phone.locator('#game-board-svg').boundingBox(),touchBefore=await phone.locator('#game-board-svg').getAttribute('viewBox'),cdp=await joniContext.newCDPSession(phone);
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:phoneRect.x+100,y:phoneRect.y+150,id:1}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:phoneRect.x+155,y:phoneRect.y+190,id:1}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
 check(await phone.locator('#game-board-svg').getAttribute('viewBox')!==touchBefore,'Ein Finger verschiebt den Spielplan am Handy');
 const pinchBefore=(await phone.locator('#game-board-svg').getAttribute('viewBox')).split(' ').map(Number);
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:phoneRect.x+130,y:phoneRect.y+180,id:1},{x:phoneRect.x+230,y:phoneRect.y+180,id:2}]});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:phoneRect.x+115,y:phoneRect.y+180,id:1},{x:phoneRect.x+245,y:phoneRect.y+180,id:2}]});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:phoneRect.x+100,y:phoneRect.y+180,id:1},{x:phoneRect.x+260,y:phoneRect.y+180,id:2}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
 check((await phone.locator('#game-board-svg').getAttribute('viewBox')).split(' ').map(Number)[2]<pinchBefore[2],'Zwei Finger vergrößern den Spielplan am Handy');await phone.getByRole('button',{name:'Alles zeigen',exact:true}).click();
 await phone.screenshot({path:root+'/test-results/spielraum-handy.png',fullPage:true});check(await phone.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Spielraum bleibt auch am Handy innerhalb des Bildschirms');
 activePage=page;await page.click('#pause-game');await status(page,'Pausiert');await status(phone,'Pausiert');check(await phone.locator('#pause-game').count()===0,'Hostpause gilt für alle und kann nur vom Host beendet werden');await page.click('#pause-game');await status(page,'Laufend');await status(phone,'Laufend');
 await page.screenshot({path:root+'/test-results/spielraum-desktop.png',fullPage:true});
 activePage=other;await other.goto(address+`/#/game?id=${gameId}`);await other.locator('.feedback:not([hidden])').waitFor();check(await other.locator('#game-board-svg').count()===0,'Nichtteilnehmer können nach Spielstart keinen Spielraum betreten');
 activePage=phone;await phone.locator('.table-back').click();await phone.locator('#ongoing-list .game-card').waitFor();check((await phone.locator('#ongoing-list .game-card').innerText()).includes('Fortsetzen'),'Begonnenes Spiel steht separat zum Fortsetzen bereit');await phone.locator('#ongoing-list .button').click();await hasRoom(phone);await phone.reload();await hasRoom(phone);check(await phone.locator('#game-status').innerText()==='Laufend','Neuladen behält Teilnahme, Karte und Spielstand');
 const second=(await rpc(flo,'create_game',{p_map_version_id:map.versionId,p_name:'Zweite Runde',p_settings:{maxPlayers:4,cards:'open',hints:true},p_password:'',p_request_id:randomUUID()})).gameId;
 await rpc(mira,'join_game',{p_game_id:second,p_password:'',p_request_id:randomUUID()});const secondState=(await rpc(flo,'get_game',{p_game_id:second})).game;await rpc(flo,'start_game',{p_game_id:second,p_expected_revision:secondState.revision,p_request_id:randomUUID()});
 activePage=page;await page.locator('.table-back').click();await page.waitForFunction(()=>document.querySelectorAll('#ongoing-list .game-card').length===2);check(true,'Ein Spieler kann mehrere parallele Spiele fortsetzen');
 const device=await browser.newContext({viewport:{width:1100,height:900}});await gateway(device);const laptop=await device.newPage();activePage=laptop;await login(laptop,'flo');await laptop.click('.menu-card[href="#/play"]');await laptop.waitForFunction(()=>document.querySelectorAll('#ongoing-list .game-card').length===2);check(true,'Zweites Gerät sieht dieselben gespeicherten Spiele');await device.close();
 activePage=page;await page.screenshot({path:root+'/test-results/spielauswahl-desktop.png',fullPage:true});
 await rpc(flo,'delete_map',{p_map_id:map.id,p_expected_revision:map.revision});await page.locator(`#ongoing-list [data-game-id="${gameId}"] .button`).click();await hasRoom(page);check(await page.locator('#game-board-svg .room').count()===doc.rooms.length,'Archivierte Karte bleibt in ihren begonnenen Spielen erhalten');
 await page.locator('.table-back').click();await page.click('#new-game');await page.locator('.game-empty').waitFor();check(await page.locator('.game-map-choice').count()===0,'Archivierte Karte kann für neue Spiele nicht ausgewählt werden');
 const fresh=await serial(()=>publishFixture(db,flo,'Waldgewölbe'));
 activePage=other;await other.goto(address+'/#/play');await other.locator('#lobby-list .game-empty').waitFor();
 // Realtime absichtlich abschalten: eine neue Lobby muss über Polling auftauchen.
 const fallbackFlags={offline:false,blockRealtime:true},fallbackContext=await browser.newContext({viewport:{width:390,height:844}});await gateway(fallbackContext,fallbackFlags);const fallback=await fallbackContext.newPage();activePage=fallback;await login(fallback,'joni');await fallback.click('.menu-card[href="#/play"]');await fallback.locator('#lobby-list .game-empty').waitFor();
 const waiting=(await rpc(flo,'create_game',{p_map_version_id:fresh.versionId,p_name:'Ohne Live-Verbindung',p_settings:{maxPlayers:4,cards:'open',hints:true},p_password:'',p_request_id:randomUUID()})).gameId;
 await fallback.locator(`[data-game-id="${waiting}"]`).waitFor({timeout:18000});check(true,'Bei ausgefallenem Realtime erscheinen Änderungen automatisch über Polling');
 await fallback.locator(`[data-game-id="${waiting}"] button`).click();await fallback.click('#join-submit');await status(fallback,'Warteraum');check(true,'Warteraum ohne Passwort kann direkt betreten werden');
 const token=await fallback.evaluate(key=>JSON.parse(localStorage.getItem(key)).token,CONFIG.sessionStorageKey);fallbackFlags.offline=true;await fallback.evaluate(()=>window.dispatchEvent(new Event('offline')));await fallback.click('#refresh-game');await fallback.locator('.feedback:not([hidden])').waitFor();check(await fallback.locator('.lobby-player').count()===2,'Verbindungsfehler lassen den letzten Warteraumstand sichtbar');fallbackFlags.offline=false;await fallback.evaluate(()=>window.dispatchEvent(new Event('online')));await fallback.waitForFunction(()=>document.querySelector('.feedback')?.hidden===true);check(await fallback.evaluate(({key,token})=>JSON.parse(localStorage.getItem(key)).token===token,{key:CONFIG.sessionStorageKey,token}),'Wiederverbindung erhält die gespeicherte Anmeldung');
 activePage=page;await page.goto(address+`/#/game?id=${waiting}`);await status(page,'Warteraum');page.once('dialog',dialog=>dialog.accept());await page.locator(`[data-player-id="${joni.profile.id}"]`).getByRole('button',{name:'Host übergeben',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.game-heading .muted')?.textContent.includes('Host: Joni'));await fallback.click('#refresh-game');await fallback.locator('#start-game').waitFor();check(await page.locator('#start-game').count()===0,'Gezielte Hostübergabe überträgt den Startknopf an den anderen Spieler');
 fallback.once('dialog',dialog=>dialog.accept());await fallback.click('#leave-lobby');await fallback.locator('.play-view').waitFor();await page.locator('#start-game').waitFor();check(true,'Beim Verlassen des Hosts übernimmt der verbleibende Teilnehmer automatisch');
 await serial(()=>db.query(`update dungeon_games set status='finished',phase='finished',finished_at=now() where id=$1`,[gameId]));for(const user of [flo,joni])await serial(()=>db.query('insert into dungeon_game_results(game_id,player_id,total_points,diamonds,life_penalty,monsters_defeated,won) values($1,$2,21,8,-3,2,true)',[gameId,user.profile.id]));
 activePage=page;await page.goto(address+'/#/history');await page.locator('.history-card').waitFor();check((await page.locator('.history-winners').innerText()).includes('Gemeinsamer Sieg: Flo · Joni'),'Chronik zeigt mehrere Sieger bei Gleichstand');await page.locator('.history-card button').click();await page.locator('.result-dialog').waitFor();check(await page.locator('.result-row.winner').count()===2,'Ergebnisdetails zeigen Punkte, Diamanten und Lebensabzug je Spieler');await page.getByRole('button',{name:'Schließen',exact:true}).click();
 await page.fill('#history-search','passtnicht');await page.locator('.history-list .game-empty').waitFor();check(true,'Chronik kann nach Spiel, Karte und Host durchsucht werden');await page.fill('#history-search','Lava');await page.locator('.history-card').waitFor();await page.selectOption('#history-scope','won');await page.locator('.history-card').waitFor();await page.screenshot({path:root+'/test-results/chronik-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.screenshot({path:root+'/test-results/chronik-handy.png',fullPage:true});check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Chronik mit Filtern passt auf einen Handybildschirm');
 check(wire.some(m=>m.event==='phx_join')&&wire.every(m=>!JSON.stringify(m).includes('mine42')&&!m.payload?.p_session_token),'Realtime überträgt keine Sitzungsschlüssel oder Spielpasswörter');
 check(errors.length===0,`Keine JavaScript-Laufzeitfehler (${errors.join('; ')})`);await fallbackContext.close();await miraContext.close();await joniContext.close();console.log(`TOTAL ${checks} Phase-3-Browserprüfungen bestanden.`);
}catch(error){console.error(error.stack);process.exitCode=1;await activePage?.screenshot({path:root+'/test-results/games-failure.png',fullPage:true}).catch(()=>{});}
finally{await browser?.close();server.kill();await db.close();}
