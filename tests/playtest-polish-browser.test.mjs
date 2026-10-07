// Oberfläche und Spielregeln gegen isoliertes PostgreSQL; keine Live-Zugriffe.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createPlaytestDatabase,portalFixture} from './helpers/playtest-polish.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,newPlayGame} from './helpers/turns.mjs';
import {callRpc} from './helpers/database.mjs';
import {browserOptions} from './helpers/browser.mjs';
import {CONFIG} from '../web/js/config.js';

const root=fileURLToPath(new URL('../',import.meta.url)),url='http://localhost:5215',out=root+'test-artifacts/1_0_2';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5215'},stdio:'ignore'});
let browser,db,page,guest,queue=Promise.resolve(),checks=0;const errors=[],requests=[];
const serial=fn=>{const p=queue.then(fn);queue=p.catch(()=>{});return p;};
const check=(v,label)=>{assert.ok(v,label);checks++;console.log('PASS',label);};
async function gateway(context){
 await context.route(CONFIG.supabaseUrl+'/**',async route=>{
  const request=route.request(),path=new URL(request.url()).pathname;
  if(!path.startsWith('/rest/v1/rpc/'))return route.abort();
  try{
   const name=path.split('/').at(-1),params=request.postDataJSON()||{};
   let result=await serial(()=>callRpc(db,name,params));if(name==='app_status')result={...result,realtimeAvailable:false};
   requests.push({name,params});await route.fulfill({contentType:'application/json',body:JSON.stringify(result)});
  }catch(error){await route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:error.message})});}
 });
 context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));
}
const rpc=(u,n,p={})=>serial(()=>userRpc(db,u,n,p));
const get=async(u,id)=>(await rpc(u,'get_game',{p_game_id:id})).game;
const target=(p,id)=>p.locator('#gameTargets [data-cell-id="'+id+'"]');
const waitButton=(p,id)=>p.locator('[data-wait-player="'+id+'"]');
async function open(p,id){await p.goto(url+'/#/game?id='+id);await p.locator('#game-board-svg').waitFor();}
async function refresh(p){
 await Promise.all([p.waitForResponse(r=>r.url().endsWith('/rpc/get_game')&&r.status()===200),p.locator('#refresh-game').click()]);
 await p.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
}
async function age(id,field,seconds=61){
 assert.ok(['choice_started_at','roll_wait_started_at'].includes(field));
 await serial(()=>db.query('update dungeon_games set '+field+"=now()-($2::int*interval '1 second') where id=$1",[id,seconds]));
}
try{
 db=await createPlaytestDatabase();await installTestDice(db);
 const a=await register(db,'TestFlo'),b=await register(db,'TestJoni'),c=await register(db,'TestMira');
 await db.query(`update dungeon_players set preferences=preferences||'{"diceAnimation":"none","sound":false,"music":false}'::jsonb`);
 const map=await publishFixture(db,a,'Portalreise',portalFixture()),id=await serial(()=>newPlayGame(db,[a,b,c],{fog:true,cards:'open'},map));
 for(let i=0;i<100;i++){try{if((await fetch(url)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 await mkdir(out,{recursive:true});browser=await chromium.launch(browserOptions());
 const desktop=await browser.newContext({viewport:{width:1366,height:900}}),mobile=await browser.newContext({viewport:{width:844,height:390},isMobile:true,hasTouch:true});
 await gateway(desktop);await gateway(mobile);page=await desktop.newPage();guest=await mobile.newPage();page.setDefaultTimeout(15000);guest.setDefaultTimeout(15000);
 await page.goto(url);await page.locator('#register-tab').click();
 check(!await page.locator('#username').getAttribute('placeholder'),'Registrierung enthält kein Beispiel Flo im Namensfeld');
 await page.locator('#login-tab').click();check(!await page.locator('#username').getAttribute('placeholder'),'Auch die Anmeldung zeigt keinen Beispielnamen');
 await page.locator('#username').fill('testflo');await page.locator('#password').fill('testing42');await page.locator('#auth-submit').click();await page.locator('.home-view').waitFor();
 check(await page.locator('#version-label').textContent()===CONFIG.version,'Oberfläche zeigt Version 1.0.2');
 await guest.goto(url);await guest.locator('#username').fill('testjoni');await guest.locator('#password').fill('testing42');await guest.locator('#auth-submit').click();await guest.locator('.home-view').waitFor();
 await page.goto(url+'/#/new-game');await page.locator('#game-map-selection button').click();await page.locator('#game-fog').check();await page.locator('.fog-preview img').waitFor();
 const preview=await page.locator('.fog-preview img').getAttribute('src');
 check(await page.evaluate(src=>{const svg=new DOMParser().parseFromString(atob(src.split(',')[1]),'image/svg+xml');return svg.querySelector('.room[data-id="2"]')?.getAttribute('visibility')!=='hidden'&&svg.querySelector('.room[data-id="4"]')?.getAttribute('visibility')==='hidden';},preview),'Nebelvorschau zeigt nur das nahe Portal, keinen vorzeitig enthüllten Ausgang');
 await open(page,id);await open(guest,id);
 check(await page.locator('#game-board-svg .room[data-id="4"]').getAttribute('visibility')==='hidden','Unbekanntes Partnerportal ist im Spiel verborgen');
 check(await page.locator('#game-board-svg .room[data-id="2"]').getAttribute('visibility')!=='hidden','Nahe Portale bleiben innerhalb der normalen Sicht sichtbar');
 await serial(()=>forceDice(db,[2,3,4,5]));await page.locator('#roll-dice').click();await target(page,1).click();await page.locator('#game-board-svg [data-marked-cell="1"]').waitFor();await refresh(guest);
 check(await page.locator('#wait-management').isHidden(),'In der Zugphase erscheint kein automatisches Warte-Popup');
 await age(id,'choice_started_at',45);await refresh(page);
 check(await waitButton(page,b.profile.id).isHidden()&&await waitButton(page,c.profile.id).isHidden(),'Vor einer Minute bleiben die Spieler-Sanduhren verborgen');
 await age(id,'choice_started_at');await refresh(page);await refresh(guest);
 await waitButton(page,b.profile.id).waitFor({state:'visible'});await waitButton(page,c.profile.id).waitFor({state:'visible'});
 check(await page.locator('.player-wait-button:not([hidden])').count()===2,'Nach einer Minute zeigen nur die zwei ausstehenden Spieler eine Sanduhr');
 check(await page.locator('#wait-management').isHidden(),'Auch nach Ablauf der Minute öffnet sich kein Popup von selbst');
 check(await waitButton(guest,c.profile.id).isVisible()&&await waitButton(guest,c.profile.id).isDisabled(),'Mitspieler sehen die kleine Warteanzeige; Entscheidungen bleiben beim Host');
 await page.locator('#pause-game').click();await waitButton(page,b.profile.id).waitFor({state:'hidden'});
 check(await page.locator('#wait-management').isHidden(),'Pause blendet Warteaktionen aus');
 await page.locator('#pause-game').click();await waitButton(page,b.profile.id).waitFor({state:'visible'});
 await waitButton(page,b.profile.id).click();await page.locator('#wait-management').waitFor({state:'visible'});
 check(await page.locator('#wait-management [data-player-id="'+b.profile.id+'"]').count()===1&&await page.locator('#wait-management [data-player-id="'+c.profile.id+'"]').count()===0,'Klick auf die Sanduhr öffnet ausschließlich die Optionen des gewählten Spielers');
 await page.screenshot({path:out+'/Warteoptionen.png'});
 const commandsBefore=requests.filter(r=>r.name==='resolve_game_wait').length;
 await page.getByRole('button',{name:'Weiter warten',exact:true}).click();
 check(await page.locator('#wait-management').isHidden()&&await waitButton(page,b.profile.id).isVisible(),'Weiter warten schließt das Popup; die Sanduhr bleibt sichtbar');
 check(requests.filter(r=>r.name==='resolve_game_wait').length===commandsBefore,'Weiter warten sendet keinen Spielbefehl und ändert keinen Spielstand');
 await waitButton(page,b.profile.id).click();check(await page.locator('#wait-management').isVisible(),'Warteoptionen lassen sich unmittelbar erneut öffnen');
 await page.keyboard.press('Escape');check(await page.locator('#wait-management').isHidden(),'Escape schließt die Warteoptionen');
 await waitButton(page,b.profile.id).click();await page.locator('#wait-management button[aria-label="Warteoptionen schließen"]').click();
 check(await page.locator('#wait-management').isHidden(),'Schließen-Knopf beendet nur das Popup');
 await waitButton(page,b.profile.id).click();await refresh(page);check(await page.locator('#wait-management').isVisible(),'Aktualisieren erhält die bewusst geöffneten Warteoptionen');
 page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Zug überspringen',exact:true}).click();await waitButton(page,b.profile.id).waitFor({state:'hidden'});
 check((await get(a,id)).round===1&&(await get(b,id)).ownState.lostLives===0,'Überspringen beendet nur den ausgewählten Zug ohne Lebensabzug');
 check(await page.locator('#wait-management').isHidden()&&await waitButton(page,c.profile.id).isVisible(),'Erledigter Spieler verliert die Sanduhr, anderer offener Zug bleibt steuerbar');
 await page.screenshot({path:out+'/Sanduhren_Desktop.png'});await refresh(guest);
 check(await guest.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Sanduhr-Anzeigen passen in die mobile Spieloberfläche');
 await guest.screenshot({path:out+'/Sanduhren_Handy.png'});
 await waitButton(page,c.profile.id).click();page.once('dialog',d=>d.accept());await page.locator('#wait-management').getByRole('button',{name:'Entfernen',exact:true}).click();
 let g=await get(a,id);check(g.participants.length===2&&g.round===2&&g.rollerId===b.profile.id,'Entfernen des letzten ausstehenden Spielers führt zum nächsten Wurf');
 await age(id,'roll_wait_started_at');await refresh(page);await waitButton(page,b.profile.id).waitFor({state:'visible'});
 check(await page.locator('#wait-management').isHidden(),'Fehlender Wurf zeigt nur eine anklickbare Sanduhr');
 await waitButton(page,b.profile.id).click();check(await page.getByRole('button',{name:'Wurf weitergeben',exact:true}).isVisible(),'Sanduhr bietet auch für einen ausstehenden Wurf die passende Aktion');
 await page.getByRole('button',{name:'Weiter warten',exact:true}).click();await waitButton(page,b.profile.id).click();
 page.once('dialog',d=>d.accept());await page.getByRole('button',{name:'Wurf weitergeben',exact:true}).click();await page.locator('#roll-dice').waitFor();
 check((await get(a,id)).rollerId===a.profile.id&&await page.locator('#wait-management').isHidden(),'Auch nach Weiter warten lässt sich der Wurf weitergeben; alte Optionen schließen sich');
 await serial(()=>forceDice(db,[2,3,4,5]));await page.locator('#roll-dice').click();await target(page,2).click();await page.locator('#game-board-svg [data-marked-cell="4"]').waitFor();
 check(await page.locator('#game-board-svg .room[data-id="4"]').getAttribute('visibility')!=='hidden','Betreten eines Portals macht den Ausgang sofort sichtbar');
 check(await page.locator('#game-board-svg .room[data-id="5"]').getAttribute('visibility')!=='hidden'&&await page.locator('#game-board-svg .room[data-id="7"]').getAttribute('visibility')==='hidden','Am Ausgang gelten normale Sichtweite und Monsterblockade');
 await refresh(guest);check(await guest.locator('#game-board-svg .room[data-id="4"]').getAttribute('visibility')==='hidden','Portalenthüllung gilt nur für den Spieler, der es betreten hat');
 await page.screenshot({path:out+'/Portal_Ausgang.png'});
 await page.goto(url+'/#/settings');await page.locator('.mark-option[data-style="waves"] .mark-price').waitFor();
 check((await page.locator('.mark-option[data-style="waves"] .mark-price').innerText()).trim()==='15','Shop zeigt den neuen Markierungspreis aus der Datenbank');
 check((await page.locator('[data-buy-cosmetic="cupStyle:runic"]').locator('..').locator('.mark-price').innerText()).trim()==='45','Würfelbecher sind ebenfalls um etwa 50 Prozent teurer');
 check(await page.locator('[data-shop-category="markStyle"] .mark-option.owned').count()===3&&await page.locator('[data-shop-category="campStyle"] .mark-option.owned').count()===2,'Drei Markierungen und zwei Hintergründe bleiben kostenlos');
 check(errors.length===0,'Keine JavaScript-Laufzeitfehler auf Desktop oder Handy');
 console.log('TOTAL '+checks+' Browserprüfungen bestanden.');
}catch(error){
 console.error(error.stack);process.exitCode=1;await page?.screenshot({path:out+'/Fehler.png',fullPage:true}).catch(()=>{});
}finally{await browser?.close();server.kill();await db?.close();}

