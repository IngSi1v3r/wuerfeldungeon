// Echte Oberfläche mit isoliertem PostgreSQL. Nur HTTP/WebSocket-Transport
// und deterministische Testwürfel werden hier ersetzt; niemals das Liveprojekt.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {createPlayDatabase,installTestDice,forceDice,newPlayGame,seedState,playFixture} from './helpers/turns.mjs';
import {CONFIG} from '../web/js/config.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),address='http://localhost:5192';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5192'},stdio:'ignore'}),db=await createPlayDatabase(),sockets=new Set(),errors=[],requests=[];
let queue=Promise.resolve(),lastSignal=0,browser,activePage,checks=0;
const serial=fn=>{const result=queue.then(fn);queue=result.catch(()=>{});return result;};
function check(value,label){assert.ok(value,label);checks++;console.log(`PASS ${label}`);}
async function signals(){const rows=(await db.query('select * from realtime.test_signals where id>$1 order by id',[lastSignal])).rows;for(const signal of rows){lastSignal=signal.id;for(const socket of sockets)if(socket.topics.has(`realtime:${signal.topic}`))socket.ws.send(JSON.stringify({topic:`realtime:${signal.topic}`,event:'broadcast',payload:{type:'broadcast',event:'changed',payload:signal.payload},ref:null}));}}
async function rpc(user,name,args={}){return serial(async()=>{const result=await userRpc(db,user,name,args);await signals();return result;});}
async function gateway(context,flags) {
 context.on('page',page=>page.on('pageerror',e=>errors.push(e.message)));
 await context.routeWebSocket(url=>url.href.startsWith(CONFIG.supabaseUrl.replace('https:','wss:')+'/realtime/'),ws=>{
  const socket={ws,topics:new Set()};sockets.add(socket);ws.onClose(()=>sockets.delete(socket));ws.onMessage(text=>{const m=JSON.parse(text.toString());if(m.event==='phx_join'){socket.topics.add(m.topic);ws.send(JSON.stringify({topic:m.topic,event:'phx_reply',ref:m.ref,join_ref:m.join_ref,payload:{status:'ok',response:{}}}));}else if(m.event==='heartbeat')ws.send(JSON.stringify({topic:'phoenix',event:'phx_reply',ref:m.ref,payload:{status:'ok',response:{}}}));});
 });
 await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
  const req=route.request(),headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
  if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
  if(flags.offline){await route.abort('failed');return;}
  const method=new URL(req.url()).pathname.split('/').at(-1),args=req.postDataJSON();requests.push({method,args});
  try{const data=await serial(async()=>{const value=await callRpc(db,method,args);await signals();return value;});
   if(data.ok&&((method==='roll_game_dice'&&flags.dropRoll)||(method==='play_game_turn'&&flags.dropTurn))){flags.dropRoll=false;flags.dropTurn=false;await route.abort('failed');return;}
   await route.fulfill({status:200,headers,body:JSON.stringify(data)});
  }catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
 });
}
async function login(page,name){await page.goto(address);await page.locator('#auth-form').waitFor();await page.fill('#username',name);await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();}
async function open(page,id){await page.goto(address+`/#/game?id=${id}`);await page.locator('#game-board-svg').waitFor({timeout:25000});}
const cell=(page,id)=>page.locator(`#gameTargets [data-cell-id="${id}"]`);
const game=async(user,id)=>(await rpc(user,'get_game',{p_game_id:id})).game;
async function updateDice(values){await serial(()=>forceDice(db,values));}
async function tap(cdp,node){await node.scrollIntoViewIfNeeded();const b=await node.boundingBox();await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:b.x+b.width/2,y:b.y+b.height/2,id:1}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});}
try{
 await installTestDice(db);const flo=await register(db,'Flo'),joni=await register(db,'Joni');const doc=playFixture();doc.rooms[4].attacks.push({number:'doubles',state:'locked'});doc.rules.unlocks.push({sourceCellId:4,targetCellId:5,number:'doubles'});
 const map=await publishFixture(db,flo,'Lava Mine',doc),id=await newPlayGame(db,[flo,joni],{},map);
 await mkdir(root+'/test-results',{recursive:true});for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const desktop=await browser.newContext({viewport:{width:1440,height:1040}}),phoneContext=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true}),df={dropRoll:true,dropTurn:false},pf={dropRoll:false,dropTurn:false};
 await gateway(desktop,df);await gateway(phoneContext,pf);const page=await desktop.newPage(),phone=await phoneContext.newPage();activePage=page;await login(page,'flo');await login(phone,'joni');const cdp=await phoneContext.newCDPSession(phone);
 await open(page,id);await open(phone,id);
 check(await page.locator('#roll-dice').count()===1&&await phone.locator('#roll-dice').count()===0,'Nur der aktuelle Roller erhält den Würfeln-Knopf');
 check(!(await page.locator('.turn-panel').innerText()).includes('null')&&!(await phone.locator('.game-score').innerText()).includes('null'),'Leere Anzeigeelemente erzeugen keinen sichtbaren Platzhaltertext');
 const geometry=await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))));
 await updateDice([2,3,4,5]);await page.click('#roll-dice');await page.locator('#game-dice .dice-face').first().waitFor();await phone.locator('#game-dice .dice-face').first().waitFor();
 check(await page.locator('#game-dice .dice-face.white').count()===3&&await page.locator('#game-dice .dice-face.red').count()===1,'Alle sehen drei weiße und einen roten Würfel als Würfelflächen');
 const rolls=requests.filter(r=>r.method==='roll_game_dice');check(rolls.length===2&&rolls[0].args.p_request_id===rolls[1].args.p_request_id,'Verlorene Wurfantwort wird mit derselben UUID wiederholt');
 check((await game(flo,id)).dice.join(',')==='2,3,4,5','Wiederholung bewahrt den einmal gespeicherten Wurf');
 check(await cell(page,1).evaluate(n=>n.classList.contains('legal-cell'))&&await cell(phone,1).evaluate(n=>n.classList.contains('legal-cell')),'Tipps markieren die eigene legale Frontier auf beiden Geräten');
 await cell(page,6).click();await page.locator('.game-view>.feedback:not([hidden])').waitFor();check((await page.locator('.game-view>.feedback').innerText()).includes('offenen Durchgang'),'Unzugängliche Felder werden auch beim Klicken serverseitig abgelehnt');
 await cell(page,1).click();await page.locator('#game-board-svg [data-marked-cell="1"]').waitFor();check((await game(flo,id)).ownState.reached.length===1&&(await game(joni,id)).ownState.reached.length===0,'Erreichte Felder gehören ausschließlich zum eigenen Brett');
 activePage=phone;await tap(cdp,cell(phone,1));await phone.locator('#roll-dice').waitFor();await page.waitForFunction(()=>document.querySelector('#turn-message')?.textContent.includes('Joni'));
 check((await game(flo,id)).round===2&&await page.locator('#roll-dice').count()===0,'Ein echter Fingertipp speichert den Zug; danach wechselt der Roller');
 const afterGeometry=await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))));check(JSON.stringify(geometry)===JSON.stringify(afterGeometry),'Spielmarkierungen verändern keine Feldposition oder Feldgröße');
 await updateDice([1,6,1,2]);await phone.click('#roll-dice');await page.locator('#game-dice').waitFor();activePage=page;
 await cell(page,2).scrollIntoViewIfNeeded();const b=await cell(page,2).boundingBox();await page.mouse.move(b.x+b.width/2,b.y+b.height/2);await page.mouse.down();await page.mouse.move(b.x+b.width/2+50,b.y+b.height/2+25);await page.mouse.up();
 check(!(await game(flo,id)).ownState.reached.includes('2'),'Ziehen an einem Feld verschiebt den Ausschnitt und spielt keinen Zug');
 await page.getByRole('button',{name:'Alles zeigen',exact:true}).click();await cell(page,2).focus();await page.keyboard.press('Enter');await page.locator('#game-board-svg [data-marked-cell="2"]').waitFor();check(true,'Felder sind auch per Tastatur erreichbar und auswählbar');
 await tap(cdp,cell(phone,2));await page.locator('#roll-dice').waitFor();check((await game(flo,id)).round===3,'Alle Spieler erhalten genau einen Zug je Wurf');
 await phone.screenshot({path:root+'/test-results/phase4-handy.png',fullPage:true});check(await phone.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Würfel, Spielplan und Lebensanzeige passen auf den Handybildschirm');
 await page.screenshot({path:root+'/test-results/phase4-desktop.png',fullPage:true});

 const hidden=await serial(()=>newPlayGame(db,[flo,joni],{hints:false,cards:'hidden'},map));await open(page,hidden);await open(phone,hidden);await updateDice([1,1,1,4]);await page.click('#roll-dice');await phone.locator('#game-dice').waitFor();
 check(await phone.locator('.combination-list').count()===0&&await phone.locator('.legal-cell').count()===0&&(await game(joni,hidden)).turn.actions===undefined,'Ohne Tipps erscheinen weder Kombinationen noch markierte Vorschläge');
 await tap(cdp,cell(phone,1));await phone.locator('.red-dice-dialog').waitFor();check((await game(joni,hidden)).ownState.redUses===3,'Roter Zug fragt auch ohne Tipps nach und verbraucht vorher nichts');
 await phone.click('#cancel-red');check((await game(joni,hidden)).ownState.reached.length===0,'Abbrechen der roten Bestätigung speichert keinen Zug');
 await tap(cdp,cell(phone,1));await phone.locator('.red-dice-dialog').waitFor();await phone.click('#confirm-red');await phone.locator('#game-board-svg [data-marked-cell="1"]').waitFor();check((await game(joni,hidden)).ownState.redUses===2,'Bestätigter roter Zug verbraucht genau eine Verwendung');
 await cell(page,1).click();await phone.locator('#roll-dice').waitFor();await updateDice([2,3,4,5]);await phone.click('#roll-dice');await page.locator('#game-dice').waitFor();await cell(page,2).click();await page.locator('#game-board-svg [data-marked-cell="2"]').waitFor();check(await page.locator('.red-dice-dialog').count()===0&&(await game(flo,hidden)).ownState.redUses===3,'Weiße Kombinationen kosten keine rote Verwendung und brauchen keine Bestätigung');

 const combat=await serial(()=>newPlayGame(db,[flo,joni],{hints:true,cards:'open'},map));for(const u of [flo,joni])await serial(()=>seedState(db,combat,u,{reached:['3'],monsterHits:{}}));await open(page,combat);await open(phone,combat);await updateDice([4,4,1,2]);await page.click('#roll-dice');await phone.locator('#game-dice').waitFor();
 df.dropTurn=true;const beforeRequests=requests.filter(r=>r.method==='play_game_turn').length;await cell(page,5).click();await page.waitForFunction(()=>document.querySelector('#game-board-svg .enemy-info[data-id="5"] [data-hit="1"]')?.getAttribute('fill')==='#375b48');
 const attacks=requests.filter(r=>r.method==='play_game_turn').slice(beforeRequests);check(attacks.length===2&&attacks[0].args.p_request_id===attacks[1].args.p_request_id&&(await game(flo,combat)).ownState.monsterHits['5']===1,'Verlorene Angriffsantwort erzeugt keinen Doppelhit');
 check(await page.locator('#game-board-svg [data-marked-cell="5"]').count()===0,'Ein angegriffenes, noch lebendes Monster bleibt nicht durchquerbar');
 await tap(cdp,cell(phone,5));await phone.locator('#roll-dice').waitFor();await updateDice([4,4,1,2]);await phone.click('#roll-dice');await page.locator('#game-dice').waitFor();await tap(cdp,cell(phone,5));await phone.locator('#game-board-svg [data-marked-cell="5"]').waitFor();
 await page.waitForFunction(()=>document.querySelector('#game-board-svg .enemy-info[data-id="5"] [data-reward-strike]'));
 check((await game(joni,combat)).ownState.diamonds===3,'Der zuerst bestätigte Gegnersieg vergibt die Erstbelohnung');
 check((await page.locator('#toast-region').innerText()).includes('Joni hat Höhlentroll besiegt'),'Offene Karten melden den Gegnersieg mit Spielername');
 await cell(page,5).click();await page.locator('#game-board-svg [data-marked-cell="5"]').waitFor();check((await game(flo,combat)).ownState.diamonds===1&&await page.locator('#own-points').innerText()==='3','Späterer Sieg vergibt nur die kleinere Belohnung und aktualisiert den Punktestand');
 check(await page.locator('#game-board-svg .enemy-info[data-id="5"] [data-hit][fill="#375b48"]').count()===2,'Trefferkästchen werden im bestehenden Monsterlayout gefüllt');
 const viewBefore=await page.locator('#game-board-svg').getAttribute('viewBox');await page.getByRole('button',{name:'Vergrößern',exact:true}).click();const zoomed=await page.locator('#game-board-svg').getAttribute('viewBox');await page.click('#refresh-game');await page.waitForTimeout(200);check(zoomed!==viewBefore&&await page.locator('#game-board-svg').getAttribute('viewBox')===zoomed,'Aktualisierung behält Zoom und Spielplanausschnitt bei');
 await page.getByRole('button',{name:'Alles zeigen',exact:true}).click();await serial(()=>seedState(db,combat,flo,{reached:['3','4','5']}));await page.click('#refresh-game');await page.waitForFunction(()=>document.querySelector('#game-board-svg .enemy-info[data-id="5"] [data-attack="9"]')?.getAttribute('data-state')==='active');
 const pasch=await page.locator('#game-board-svg .enemy-info[data-id="5"] [data-attack="doubles"]').evaluate(n=>({state:n.getAttribute('data-state'),pips:[...n.querySelectorAll('circle')].map(c=>c.getAttribute('fill'))}));check(pasch.state==='active'&&pasch.pips.length===6&&pasch.pips.every(c=>c==='#172b3b'),'Freischaltungen färben auch einen kompletten Pasch-Angriff aktiv');

 await updateDice([4,4,1,2]);await page.click('#roll-dice');await phone.locator('#game-dice').waitFor();await page.click('#pause-game');await phone.waitForFunction(()=>document.querySelector('#game-status')?.textContent==='Pausiert');const pausedDice=(await game(flo,combat)).dice;
 check(await phone.locator('.legal-cell').count()===0&&await phone.locator('#roll-dice').count()===0,'Pause nimmt die interaktiven Vorschläge bei allen Spielern zurück');await page.click('#pause-game');await phone.waitForFunction(()=>document.querySelector('#game-status')?.textContent==='Laufend');check(JSON.stringify((await game(flo,combat)).dice)===JSON.stringify(pausedDice),'Fortsetzen erhält den Wurf und die offene Zugphase');
 await cell(page,6).click();await serial(()=>db.query(`update dungeon_games set choice_started_at=now()-interval '61 seconds' where id=$1`,[combat]));await page.click('#refresh-game');await page.locator('.player-wait-button:not([hidden]):not(:disabled)').first().click();await page.locator('#wait-management:not([hidden])').waitFor();
 check(await page.locator('#turn-hourglass:not([hidden])').count()===1,'Gespeicherte Wartezeit zeigt Sanduhr und Hostentscheidung');page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Zug überspringen',exact:true}).click();await phone.locator('#roll-dice').waitFor();check((await game(joni,combat)).ownState.lostLives===0,'Host kann einen offenen Zug ausdrücklich ohne Lebensabzug überspringen');
 await page.reload();await page.locator('#game-board-svg').waitFor();check((await game(flo,combat)).ownState.monsterHits['6']===1&&await page.locator('#game-board-svg [data-marked-cell="5"]').count()===1,'Neuladen stellt Wege und Monsterhits aus der Datenbank wieder her');

 const terminal=await serial(()=>newPlayGame(db,[flo,joni],{},map));await serial(()=>seedState(db,terminal,flo,{reached:['1','2','3','4','5','7','8','9','10','11'],monsterHits:{5:2,6:2,11:1}}));await serial(()=>seedState(db,terminal,joni,{reached:['1']}));await open(page,terminal);await open(phone,terminal);await updateDice([4,4,3,4]);await page.click('#roll-dice');await phone.locator('#game-dice').waitFor();await cell(page,6).click();await phone.waitForFunction(()=>document.querySelector('#game-round')?.dataset.final==='true');check((await game(flo,terminal)).phase==='choosing','Alle Gegner besiegt löst die letzte Runde aus und lässt die anderen fertig ziehen');
 await tap(cdp,cell(phone,2));await page.waitForFunction(()=>document.querySelector('#turn-message')?.textContent==='Schlusswertung');check(await page.locator('#roll-dice').count()===0&&(await game(flo,terminal)).phase==='round_complete','Endrunde ist dauerhaft abgeschlossen und wartet auf die Phase-5-Wertung');
 const impossible=await serial(()=>newPlayGame(db,[flo,joni],{},map));await open(page,impossible);await updateDice([1,1,1,1]);await page.click('#roll-dice');await page.waitForFunction(()=>document.querySelectorAll('.life-box.lost').length===1);check((await game(flo,impossible)).round===2&&await page.locator('.life-box.lost').count()===1,'Ohne legalen Zug wird automatisch ein Lebensfeld gefüllt und die Runde fortgesetzt');
 await page.screenshot({path:root+'/test-results/phase4-leben.png',fullPage:true});
 check(errors.length===0,`Keine JavaScript-Laufzeitfehler (${errors.join('; ')})`);console.log(`TOTAL ${checks} Phase-4-Browserprüfungen bestanden.`);
}catch(error){console.error(error.stack);process.exitCode=1;await activePage?.screenshot({path:root+'/test-results/turns-failure.png',fullPage:true}).catch(()=>{});}
finally{await browser?.close();server.kill();await db.close();}
