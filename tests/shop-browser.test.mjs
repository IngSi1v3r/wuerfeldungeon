// Echte Desktop-/Handybrowser und isoliertes PostgreSQL. Keine Live-Schreibzugriffe.
import {chromium} from 'playwright';import assert from 'node:assert/strict';import {spawn} from 'node:child_process';import {createRequire} from 'node:module';import {mkdir} from 'node:fs/promises';import {fileURLToPath} from 'node:url';import {randomUUID} from 'node:crypto';
import {createUpgradedDatabase,modernFixture} from './helpers/game-upgrade.mjs';import {register,userRpc,publishFixture} from './helpers/games.mjs';import {callRpc} from './helpers/database.mjs';import {installTestDice,forceDice,newPlayGame,seedState} from './helpers/turns.mjs';import {goalDefault} from '../web/js/maps/features.js';import {CONFIG} from '../web/js/config.js';

import {createShopDatabase} from './helpers/shop.mjs';
const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),address='http://localhost:5198';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5198'},stdio:'ignore'}),db=await createShopDatabase(),sockets=new Set(),errors=[],requests=[],images=new Map();
let queue=Promise.resolve(),lastSignal=0,browser,page,phone,checks=0,assetReads=0,dropTurn=false;
const serial=fn=>{const p=queue.then(fn);queue=p.catch(()=>{});return p;};
const check=(value,label)=>{assert.ok(value,label);checks++;console.log(`PASS ${label}`);};
async function signals(){for(const s of (await db.query('select * from realtime.test_signals where id>$1 order by id',[lastSignal])).rows){lastSignal=s.id;for(const socket of sockets)if(socket.topics.has(`realtime:${s.topic}`))socket.ws.send(JSON.stringify({topic:`realtime:${s.topic}`,event:'broadcast',payload:{type:'broadcast',event:'changed',payload:s.payload},ref:null}));}}
async function rpc(user,name,args={}){return serial(async()=>{const data=await userRpc(db,user,name,args);await signals();return data;});}
async function gateway(context){
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));
 await context.routeWebSocket(url=>url.href.startsWith(CONFIG.supabaseUrl.replace('https:','wss:')+'/realtime/'),ws=>{
  const socket={ws,topics:new Set()};sockets.add(socket);ws.onClose(()=>sockets.delete(socket));ws.onMessage(text=>{const m=JSON.parse(text.toString());if(m.event==='phx_join'){socket.topics.add(m.topic);ws.send(JSON.stringify({topic:m.topic,event:'phx_reply',ref:m.ref,join_ref:m.join_ref,payload:{status:'ok',response:{}}}));}else if(m.event==='heartbeat')ws.send(JSON.stringify({topic:'phoenix',event:'phx_reply',ref:m.ref,payload:{status:'ok',response:{}}}));});
 });
 await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
  const req=route.request(),url=new URL(req.url()),headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,GET,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
  if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
  if(url.pathname.startsWith('/storage/v1/object/public/map-assets/')){assetReads++;const img=images.get(url.pathname.split('/map-assets/')[1]);await route.fulfill({status:img?200:404,headers:{...headers,'content-type':'image/png'},body:img||''});return;}
  const method=url.pathname.split('/').at(-1),args=req.postDataJSON();requests.push({method,args});
  try{const data=await serial(async()=>{const answer=await callRpc(db,method,args);await signals();return answer;});if(dropTurn&&method==='buy_marking'&&data.ok){dropTurn=false;await route.abort('failed');return;}await route.fulfill({status:200,headers,body:JSON.stringify(data)});}catch(e){await route.fulfill({status:400,headers,body:JSON.stringify({message:e.message})});}
 });
}
async function login(p,name){await p.goto(address);await p.locator('#auth-form').waitFor();await p.fill('#username',name);await p.fill('#password','testing42');await p.click('#auth-submit');await p.locator('.home-view').waitFor();}
async function open(p,id,lobby=false){await p.goto(address+`/#/game?id=${id}`);await p.locator(lobby?'#start-game':'#game-board-svg').waitFor({timeout:25000});}
const cell=(p,id)=>p.locator(`#gameTargets [data-cell-id="${id}"]`);
async function play(p,id){await p.waitForFunction(id=>document.querySelector(`#gameTargets [data-cell-id="${id}"]`)?.getAttribute('aria-disabled')==='false',String(id));await cell(p,id).focus();await cell(p,id).press('Enter');}
async function refresh(p){await Promise.all([p.waitForResponse(r=>r.url().endsWith('/rpc/get_game')&&r.status()===200),p.evaluate(()=>document.querySelector('#refresh-game').click())]);await p.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));}
const get=async(u,id)=>(await rpc(u,'get_game',{p_game_id:id})).game;
async function acknowledge(p){const d=p.locator('.life-loss-dialog');if(await d.count())await d.getByRole('button',{name:'Verstanden'}).click();}
// Prüft Layout, Vollbild, Live-Animation und Eingaben über echte Browser.
async function inViewport(p,selectors){
 return p.evaluate(selectors=>selectors.map(selector=>{const n=document.querySelector(selector),r=n?.getBoundingClientRect();return {selector,visible:r&&r.width>0&&r.height>0&&r.left>=-1&&r.top>=-1&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1,rect:r?{x:r.x,y:r.y,w:r.width,h:r.height}:null};}),selectors);
}
async function stableNodes(p){return p.evaluate(()=>{const b=document.querySelector('#game-board-svg');window.__tableStable={board:b,box:b.getAttribute('viewBox'),images:[...b.querySelectorAll('image')],face:document.querySelector('#game-dice .dice-face'),mini:document.querySelector('.opponent-miniature svg'),score:document.querySelector('#own-points'),target:b.querySelector('[data-cell-id="3"]')};});}
async function noAnimation(p){return p.locator('.dice-presentation').evaluate(n=>n.hidden);}
async function stopAnimation(p){await p.locator('.dice-presentation .roll-skip').evaluate(n=>{if(!n.closest('.dice-presentation').hidden)n.click();});}
try{
 await installTestDice(db);const flo=await register(db,'Flo'),d=modernFixture(),map=await publishFixture(db,flo,'Shop-Mine',d);await mkdir(root+'/test-results',{recursive:true});
 const previousGame=await serial(()=>newPlayGame(db,[flo],{},map));await serial(()=>seedState(db,previousGame,flo,{diamonds:30}));await serial(()=>db.query('select dungeon_private.finalize_game($1)',[previousGame]));
 for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const desktop=await browser.newContext({viewport:{width:1440,height:1000}}),mobile=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});await gateway(desktop);await gateway(mobile);page=await desktop.newPage();phone=await mobile.newPage();await login(page,'flo');await login(phone,'flo');
 const settings=async p=>{await p.goto(address+'/#/settings');await p.waitForFunction(()=>document.querySelector('#settings-form')?.getAttribute('aria-busy')==='false');};
 const accept=async(p,style)=>{p.once('dialog',d=>d.accept());await p.locator(`[data-buy-marking="${style}"]`).click();await p.waitForFunction(style=>document.querySelector(`#mark-${style}`)?.disabled===false,style);};
 const save=async p=>{await p.click('#save-settings');await p.waitForFunction(()=>document.querySelector('#settings-form .feedback')?.textContent==='Deine Einstellungen wurden gespeichert.');};
 await settings(page);await settings(phone);
 check(await page.locator('#shop-balance').innerText()==='30'&&await phone.locator('#shop-balance').innerText()==='30','Beide Geräte sehen das Guthaben aus einer abgeschlossenen Partie');
 check(await page.locator('.mark-option').count()===7&&await page.locator('.mark-preview-svg').count()===7,'Sieben Markierungen besitzen echte Vektorvorschauen');
 check(await page.isChecked('#mark-cross')&&await page.locator('#mark-stars').isDisabled()&&await phone.isChecked('#mark-cross'),'Neue Spieler beginnen mit X; nicht gekaufte Stile sind gesperrt');
 const prior=await rpc(flo,'get_player_profile');page.once('dialog',d=>d.dismiss());await page.locator('[data-buy-marking="claws"]').click();check((await rpc(flo,'get_player_profile')).profile.cosmetics.balance===30,'Abbrechen des Kaufdialogs verbraucht keine Diamanten');
 await page.click('#audio-preferences summary');await page.uncheck('#sound');await page.check('#music');await page.check('#reduceMotion');dropTurn=true;await accept(page,'pencil');
 const attempts=requests.filter(r=>r.method==='buy_marking'&&r.args.p_style==='pencil');check(attempts.length===2&&attempts[0].args.p_request_id===attempts[1].args.p_request_id,'Verlorene Kaufantwort wird mit derselben UUID wiederholt');
 check(await page.locator('#shop-balance').innerText()==='25'&&(await rpc(flo,'get_player_profile')).profile.cosmetics.spent===5,'Auch nach verlorener Antwort wird genau ein Kauf abgebucht');
 check(await page.isChecked('#mark-pencil')&&await page.isChecked('#music')&&!(await page.isChecked('#sound'))&&await page.isChecked('#reduceMotion'),'Kauf behält ungespeicherte Vorlieben und wählt den freigeschalteten Stil vor');
 check((await rpc(flo,'get_player_profile')).profile.preferences.markStyle==='cross','Freischaltung verändert den gespeicherten Stil erst beim Speichern');await save(page);
 check(await page.locator('#mark-stars').isDisabled(),'Speichern öffnet keine weiterhin gesperrten Markierungen');
 await accept(phone,'stars');await save(phone);check(await phone.locator('#shop-balance').innerText()==='5'&&!(await phone.isChecked('#sound'))&&await phone.isChecked('#music'),'Anderes Gerät kauft mit aktuellem Guthaben und übernimmt unberührte Vorlieben');
 page.once('dialog',d=>d.accept());await page.locator('[data-buy-marking="solid"]').click();await page.waitForFunction(()=>document.querySelector('#settings-form .feedback')?.textContent.includes('Guthaben reicht'));
 check(await page.locator('#shop-balance').innerText()==='5'&&await page.locator('[data-buy-marking="solid"]').isDisabled(),'Veraltetes Guthaben wird beim Kauf geprüft und die Oberfläche aktualisiert');
 check(await page.isChecked('#mark-stars')&&await page.isChecked('#reduceMotion'),'Synchronisation übernimmt die neue Markierung ohne Vorlieben zu verlieren');
 check(JSON.stringify((await rpc(flo,'get_player_profile')).profile.stats)===JSON.stringify(prior.profile.stats),'Shop-Käufe ändern weder Punkte noch Statistik');
 await phone.reload();await phone.waitForFunction(()=>document.querySelector('#settings-form')?.getAttribute('aria-busy')==='false');check(await phone.isChecked('#mark-stars')&&await phone.locator('#shop-balance').innerText()==='5','Gekaufte und gewählte Markierung bleibt nach Reload erhalten');
 await page.screenshot({path:root+'/test-results/shop-desktop.png',fullPage:true});await phone.screenshot({path:root+'/test-results/shop-phone.png',fullPage:true});
 await page.goto(address+'/#/profile');await page.waitForFunction(()=>document.querySelector('#profile-shop-balance')?.textContent==='5');check(await page.locator('.diamond-wallet').innerText().then(t=>t.includes('30 erspielt')&&t.includes('25 für Markierungen')),'Profil zeigt verfügbares Guthaben und bisherige Ausgaben');
 const match=await serial(()=>newPlayGame(db,[flo],{},map));await serial(()=>seedState(db,match,flo,{reached:['3'],monsterHits:{3:2,12:11},diamonds:55}));await open(page,match);
 const geometry=await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))));
 check(await page.locator('[data-marked-cell="3"].stars path[stroke="#54446b"]').count()===3,'Sternensiegel erscheint auf dem tatsächlichen persönlichen Spielplan');await serial(()=>forceDice(db,[4,4,1,1]));await page.click('#roll-dice');await play(page,12);await page.locator('.result-dialog').waitFor();
 const completed=await get(flo,match),credited=(await rpc(flo,'get_player_profile')).profile;check(completed.status==='finished'&&credited.cosmetics.balance===5+completed.results[0].diamonds,'Normaler letzter Angriff schreibt die finalen Diamanten automatisch gut');
 await page.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();const originalStats=credited.stats;
 for(const [style,selector] of [['runes','circle[stroke="#285d63"]'],['claws','path[stroke="#793b32"]']]){await settings(page);await accept(page,style);await save(page);await open(page,match);await page.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();check(await page.locator(`[data-marked-cell="3"].${style} ${selector}`).count()>0,`${style}: gekaufter Stil wird im bestehenden Spiel angewendet`);check(JSON.stringify(geometry)===JSON.stringify(await page.locator('#roomsLayer .room-body').evaluateAll(nodes=>nodes.map(n=>['x','y','width','height'].map(a=>n.getAttribute(a))))),'Stilwechsel verändert keine Feldposition oder Größe');}
 check(JSON.stringify((await rpc(flo,'get_player_profile')).profile.stats)===JSON.stringify(originalStats),'Neue Stile verändern keine abgeschlossene Wertung');
 await settings(phone);await phone.setViewportSize({width:360,height:780});check(await phone.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Shop ist auch bei 360 Pixeln ohne horizontales Scrollen bedienbar');
 await phone.click('#reload-settings');await phone.waitForFunction(()=>document.querySelector('#shop-balance')?.textContent==='11');check(await phone.isChecked('#mark-claws'),'Manuelles Neuladen übernimmt Käufe und Auswahl des anderen Geräts');
 await phone.check('#mark-cross');await save(phone);check((await rpc(flo,'get_player_profile')).profile.preferences.markStyle==='cross'&&(await rpc(flo,'get_player_profile')).profile.cosmetics.balance===11,'Kostenloser Wechsel zu X behält Guthaben und Freischaltungen');
 check(errors.length===0,`Keine JavaScript-Fehler (${errors.join('; ')})`);console.log(`${checks} Shop-Browserprüfungen erfolgreich.`);
}catch(e){console.error(e.stack);await page?.screenshot({path:root+'/test-results/shop-error.png',fullPage:true}).catch(()=>{});throw e;}finally{await browser?.close();server.kill();await queue;await db.close();}
