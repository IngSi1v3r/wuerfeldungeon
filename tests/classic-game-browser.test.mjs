// Echte Oberfläche mit isoliertem PostgreSQL. Nur HTTP/WebSocket-Transport
// und deterministische Testwürfel werden hier ersetzt; niemals das Liveprojekt.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir,readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {callRpc} from './helpers/database.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {createClassicDatabase,classicFixture} from './helpers/classic-game.mjs';
import {createShopDatabase} from './helpers/shop.mjs';
import {installTestDice,forceDice,newPlayGame,seedState,playFixture} from './helpers/turns.mjs';
import {CONFIG} from '../web/js/config.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),address='http://localhost:5193';
const release=process.argv.includes('--release');
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5193'},stdio:'ignore'}),db=release||process.argv.includes('--shop')?await createShopDatabase():await createClassicDatabase(),sockets=new Set(),errors=[],requests=[];
if(release)for(const name of ['020_round_two.sql','022_print_and_cosmetics.sql','024_original_map_rules.sql','026_release_1_0_0.sql','028_free_starters_and_rune_hits.sql','030_playtest_polish.sql'])await db.exec(await readFile(root+'supabase/migrations/'+name,'utf8'));
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
   if(data.ok&&((method==='roll_game_dice'&&flags.dropRoll)||(method==='play_game_action'&&flags.dropTurn)||(method==='choose_game_powerup'&&flags.dropPowerup))){flags.dropRoll=false;flags.dropTurn=false;flags.dropPowerup=false;await route.abort('failed');return;}
   await route.fulfill({status:200,headers,body:JSON.stringify(data)});
  }catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
 });
}
async function login(page,name){await page.goto(address);await page.locator('#auth-form').waitFor();await page.fill('#username',name);await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();}
async function open(page,id){await page.goto(address+`/#/game?id=${id}`);await page.locator('#game-board-svg').waitFor({timeout:25000});}
const cell=(page,id)=>page.locator(`#gameTargets [data-cell-id="${id}"]`);
const game=async(user,id)=>(await rpc(user,'get_game',{p_game_id:id})).game;
async function updateDice(values){await serial(()=>forceDice(db,values));}
async function acknowledge(page){
 const dialog=page.locator('.life-loss-dialog');
 // Verluste erscheinen erst nach der Würfelanimation und einer kurzen Pause.
 // Auf diesen echten Ablauf warten, statt den nächsten Wurf durch ein Modal zu erzwingen.
 if(await page.locator('#turn-message').textContent()==='Wurf wird ausgewertet …')await dialog.waitFor({state:'visible',timeout:15000});
 if(await dialog.count())await dialog.getByRole('button',{name:'Verstanden'}).click();
}
async function tap(cdp,node){await node.scrollIntoViewIfNeeded();const b=await node.boundingBox();await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:b.x+b.width/2,y:b.y+b.height/2,id:1}]});await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});}
try{
 await installTestDice(db);const flo=await register(db,'Flo'),joni=await register(db,'Joni'),map=await publishFixture(db,flo,'Feuermine',classicFixture()),id=await serial(()=>newPlayGame(db,[flo,joni],{cards:'open'},map));
 // Animationsdauer wird separat geprüft. Hier stehen vollständige Partien im Vordergrund.
 await db.exec(`update public.dungeon_players set preferences=preferences||'{"diceAnimation":"none","sound":false}'::jsonb`);
 await mkdir(root+'/test-results',{recursive:true});for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const desktop=await browser.newContext({viewport:{width:1440,height:1040}}),phoneContext=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true}),df={dropRoll:false,dropTurn:false},pf={dropRoll:false,dropTurn:false};
 await gateway(desktop,df);await gateway(phoneContext,pf);const page=await desktop.newPage(),phone=await phoneContext.newPage();activePage=page;await login(page,'flo');await login(phone,'joni');const cdp=await phoneContext.newCDPSession(phone);
 const play=async(p,id)=>{await p.waitForFunction(id=>document.querySelector(`#gameTargets [data-cell-id="${id}"]`)?.getAttribute('aria-disabled')==='false',String(id));await cell(p,id).focus();await cell(p,id).press('Enter');};
 const refresh=async p=>{await p.click('#refresh-game');await p.waitForTimeout(100);};
 const roll=async(p,values)=>{await acknowledge(page);await acknowledge(phone);const n=requests.filter(r=>r.method==='roll_game_dice').length;await updateDice(values);await p.click('#roll-dice');await p.waitForFunction(()=>!document.querySelector('#roll-dice'));await page.waitForTimeout(120);await acknowledge(page);await acknowledge(phone);check(requests.filter(r=>r.method==='roll_game_dice').length>n,'Wurf gespeichert');};
 await open(page,id);await open(phone,id);await page.locator('.opponent-miniature').waitFor();check(await page.locator('.opponent-miniature').count()===1&&await phone.locator('.opponent-miniature').count()===1,'Offene Karten zeigen den Gegnerplan auf beiden Geräten');
 const geometry=await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))));
 await roll(page,[2,3,4,5]);await play(page,1);await page.locator('#game-board-svg [data-marked-cell="1"]').first().waitFor();await tap(cdp,cell(phone,1));await phone.locator('#roll-dice').waitFor();
 await page.locator('.opponent-miniature [data-marked-cell="1"]').waitFor();check(true,'Gegnerminiaturen aktualisieren ihre erreichten Felder live');
 await page.locator('.opponent-miniature').click();await page.locator('.opponent-dialog #opponent-board-svg').waitFor();check(await page.locator('.opponent-dialog [data-marked-cell="1"]').count()===1,'Vergrößerte Gegnerkarte zeigt den eigenen Gegnerstand');await page.locator('.opponent-dialog').getByRole('button',{name:'Vergrößern',exact:true}).click();check(await page.locator('.opponent-dialog #opponent-board-svg').getAttribute('viewBox')!==await page.locator('#game-board-svg').getAttribute('viewBox'),'Gegnerkarte besitzt unabhängigen Zoom');await page.locator('.opponent-dialog').getByRole('button',{name:'Schließen',exact:true}).click();
 await roll(phone,[3,4,1,2]);await play(page,2);await page.locator('.powerup-dialog').waitFor();await play(phone,2);await phone.locator('.powerup-dialog').waitFor();check((await game(flo,id)).round===2,'Offene Truhen halten den nächsten Wurf zurück');
 df.dropPowerup=true;
 await page.locator('[data-powerup="torch"]').click();await page.locator('.powerup-dialog').waitFor({state:'detached'});await phone.locator('[data-powerup="axe"]').click();await page.locator('#roll-dice').waitFor();const powers=requests.filter(r=>r.method==='choose_game_powerup'&&r.args.p_powerup==='torch');check(powers.length===2&&powers[0].args.p_request_id===powers[1].args.p_request_id,'Verlorene Truhenantwort vergibt das Powerup nur einmal');check((await game(flo,id)).ownState.torchUses===2&&(await game(joni,id)).ownState.axeUses===2,'Truhen vergeben Fackel und Doppelhit an unterschiedliche Spieler');
 await roll(page,[4,5,5,5]);await page.locator('#torch-mode:not([disabled])').waitFor();await page.click('#torch-mode');await cell(page,3).waitFor();await page.waitForFunction(()=>document.querySelector('#gameTargets [data-cell-id="3"]')?.classList.contains('legal-cell'));check(await cell(page,3).evaluate(n=>n.classList.contains('legal-cell')),'Fackelmodus zeigt mögliche Zwischenräume erst nach Aktivierung');
 await play(page,3);check((await game(flo,id)).ownState.torchUses===2&&!((await game(flo,id)).ownState.reached).includes('3'),'Zwischenraumauswahl verbraucht noch nichts');await page.click('#torch-mode');check(await cell(page,3).evaluate(n=>!n.classList.contains('torch-middle'))&&(await game(flo,id)).ownState.torchUses===2,'Fackelmodus abbrechen kostet keine Verwendung');
 await page.click('#torch-mode');await page.waitForFunction(()=>document.querySelector('#gameTargets [data-cell-id="3"]')?.classList.contains('legal-cell'));await play(page,3);await play(page,4);await phone.locator('#roll-dice').waitFor();check((await game(flo,id)).ownState.diamonds===7&&(await game(flo,id)).ownState.torchUses===1,'Fackelzug markiert zwei Felder, vergibt Diamant und beide Spezialbelohnungen');
 await roll(phone,[4,4,1,2]);await play(page,5);await play(phone,3);await page.locator('#roll-dice').waitFor();await roll(page,[4,4,2,2]);await play(page,5);await play(phone,7);await phone.locator('.powerup-dialog').waitFor();check(await phone.locator('[data-powerup="axe"]').count()===0,'Bereits gewählter Powerup-Typ fehlt in der zweiten Truhe');await phone.locator('[data-powerup="extraLife"]').click();await phone.locator('#roll-dice').waitFor();check(await phone.locator('.life-box').count()===14,'Extraleben fügt drei Lebensfelder hinzu');
 // Zweite Fackel erreicht eine Truhe neben der Frontier und das benachbarte X-Feld.
 await roll(phone,[4,6,3,3]);await page.click('#torch-mode');await page.waitForFunction(()=>document.querySelector('#gameTargets [data-cell-id="9"]')?.classList.contains('legal-cell'));await play(page,9);await play(page,8);await page.locator('.powerup-dialog').waitFor();await page.locator('[data-powerup="axe"]').click();await page.locator('[data-powerup="extraLife"]').waitFor();await page.locator('[data-powerup="extraLife"]').click();await play(phone,4);await page.locator('#roll-dice').waitFor();
 check((await game(flo,id)).ownState.torchUses===0&&(await game(flo,id)).ownState.axeUses===2,'Fackel-Zwischenraum öffnet eine Truhe mit eigenem Powerup');
 await roll(page,[4,4,1,2]);await page.click('#axe-mode');df.dropTurn=true;await play(page,6);await page.waitForFunction(()=>document.querySelector('#game-board-svg .enemy-info[data-id="6"] [data-hit="2"]')?.getAttribute('fill')==='#375b48');const attacks=requests.filter(r=>r.method==='play_game_action'&&r.args.p_use_axe);check(attacks.length===2&&attacks[0].args.p_request_id===attacks[1].args.p_request_id&&(await game(flo,id)).ownState.monsterHits['6']===2,'Verlorene Doppelhit-Antwort verbraucht nur eine Axtladung');
 await phone.click('#axe-mode');await play(phone,5);await phone.locator('#roll-dice').waitFor();check((await game(joni,id)).ownState.monsterHits['5']===2,'Doppelhit besiegt den erreichbaren Troll');
 await roll(phone,[4,4,1,2]);await page.click('#axe-mode');await play(page,6);await phone.click('#axe-mode');await play(phone,6);await page.locator('#roll-dice').waitFor();check((await game(flo,id)).ownState.axeUses===0&&(await game(joni,id)).ownState.axeUses===0,'Beide Axtladungen sind nach zwei Angriffen aufgebraucht');
 // Ganze Partie, ohne Endzustand zu seed-en: bis zum letzten Treffer normal würfeln und spielen.
 for(let i=0;i<8;i++){
  // Erst den gespeicherten Rundenwechsel abwarten; der Tastendruck allein
  // wartet noch nicht auf den asynchronen Zug des zweiten Spielers.
  await page.waitForFunction(()=>['Dein Wurf','Joni würfelt'].includes(document.querySelector('#turn-message')?.textContent));
  const g=await game(flo,id),roller=g.rollerId===flo.profile.id?page:phone;await roller.locator('#roll-dice').waitFor();await roll(roller,[4,4,1,2]);await play(page,6);
  if(i===7){check((await game(flo,id)).status==='playing'&&(await game(flo,id)).finalRound===g.round,'Letzter Boss-Treffer beendet noch nicht den offenen Mitspielerzug');}
  await play(phone,6);
 }
 await page.locator('.result-dialog').waitFor();await phone.locator('.result-dialog').waitFor();const result=await game(flo,id);check(result.status==='finished'&&result.results.length===2,'Letzter Mitspielerzug erzeugt für alle das endgültige Ergebnis');check(result.results.find(r=>r.playerId===joni.profile.id).breakdown.bossBonusDiamonds===3,'Teilweise besiegter Boss wird in vollständigen Dreiergruppen gewertet');check(await page.locator('#roll-dice').count()===0,'Nach dem Ende wird kein weiterer Wurf angeboten');
 await page.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();await phone.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();
 const afterGeometry=await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))));check(JSON.stringify(geometry)===JSON.stringify(afterGeometry),'Alle Spielmarkierungen bewahren die ursprüngliche Geometrie');check(await phone.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Powerups, Gegnerkarten und Score passen auf das Handy');
 await page.screenshot({path:root+'/test-results/classic-desktop.png',fullPage:true});await phone.screenshot({path:root+'/test-results/classic-handy.png',fullPage:true});
 await page.goto(address+'/#/profile');await page.waitForFunction(()=>Number(document.querySelector('.stats-grid .stat-card strong')?.textContent)>=1);check(true,'Abgeschlossene Partie erscheint unmittelbar in der Profilstatistik');
 const hidden=await serial(()=>newPlayGame(db,[flo,joni],{cards:'hidden',hints:false},map));await serial(()=>seedState(db,hidden,joni,{reached:['1','2'],torchUses:2}));await open(page,hidden);await open(phone,hidden);check(await page.locator('.opponent-miniature').count()===0&&await phone.locator('.opponent-miniature').count()===0,'Verdeckte Karten übertragen und zeigen keine Gegnerminiaturen');await roll(page,[4,5,5,5]);await phone.click('#torch-mode');check(await phone.locator('.legal-cell').count()===0&&await phone.locator('.combination-list').count()===0,'Fackelmodus bleibt ohne Tipps frei von Vorschlägen');await play(phone,3);await play(phone,4);await phone.locator('#game-board-svg [data-marked-cell="4"]').waitFor();check((await game(joni,hidden)).ownState.torchUses===1,'Fackel ist auch ohne Tipps vollständig bedienbar');
 const redTorch=await serial(()=>newPlayGame(db,[flo,joni],{cards:'hidden',hints:false},map));await serial(()=>seedState(db,redTorch,joni,{reached:['1'],torchUses:2}));await open(page,redTorch);await open(phone,redTorch);await roll(page,[1,1,1,5]);await phone.click('#torch-mode');await play(phone,2);await play(phone,7);await phone.locator('.red-dice-dialog').waitFor();await phone.click('#cancel-red');check((await game(joni,redTorch)).ownState.redUses===3&&(await game(joni,redTorch)).ownState.torchUses===2,'Abgebrochene rote Fackelaktion verbraucht keine Ressource');await play(phone,7);await phone.locator('.red-dice-dialog').waitFor();await phone.click('#confirm-red');await phone.locator('.powerup-dialog').waitFor();check((await game(joni,redTorch)).ownState.redUses===2&&(await game(joni,redTorch)).ownState.torchUses===1,'Bestätigte rote Fackelaktion verbraucht genau je eine Ladung');await phone.locator('[data-powerup="redDice"]').click();await phone.locator('[data-powerup="extraLife"]').waitFor();await phone.locator('[data-powerup="extraLife"]').click();await phone.locator('#roll-dice').waitFor();check((await game(joni,redTorch)).ownState.redUses===5,'Zwei mit der Fackel geöffnete Truhen sind vollständig auswählbar');
 check(errors.length===0,'Keine JavaScript-Fehler im Desktop- oder Handybrowser');console.log(`${checks} Mehrspieler-Browserprüfungen erfolgreich.`);
}catch(error){console.error(error.message);if(activePage)await activePage.screenshot({path:root+'/test-results/classic-error.png',fullPage:true}).catch(()=>{});throw error;}
finally{await browser?.close();server.kill();await queue;await db.close();}
