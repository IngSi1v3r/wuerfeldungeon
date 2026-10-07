// Echte Oberfläche + isoliertes PostgreSQL. Kein Zugriff auf das Live-Projekt.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createSoloDatabase,soloFixture} from './helpers/solo-ai.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,seedState} from './helpers/turns.mjs';
import {callRpc} from './helpers/database.mjs';
import {browserOptions} from './helpers/browser.mjs';
import {CONFIG} from '../web/js/config.js';

const root=fileURLToPath(new URL('../',import.meta.url)),url='http://localhost:5216',out=root+'test-artifacts/1_1_0';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5216'},stdio:'ignore'});
let browser,db,page,queue=Promise.resolve(),checks=0;const errors=[];
const serial=fn=>{const p=queue.then(fn);queue=p.catch(()=>{});return p;};
const check=(v,label)=>{assert.ok(v,label);checks++;console.log('PASS',label);};
try{
 db=await createSoloDatabase();await installTestDice(db);await forceDice(db,[2,3,4,5]);
 const a=await register(db,'KIFlo'),map=await publishFixture(db,a,'Testmine',soloFixture());
 await db.exec("update dungeon_players set preferences=preferences||'{\"diceAnimation\":\"none\",\"sound\":false}'::jsonb");
 for(let i=0;i<100;i++){try{if((await fetch(url)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 await mkdir(out,{recursive:true});browser=await chromium.launch(browserOptions());const context=await browser.newContext({viewport:{width:1366,height:900}});
 await context.route(CONFIG.supabaseUrl+'/**',async route=>{
  const req=route.request(),path=new URL(req.url()).pathname;if(!path.startsWith('/rest/v1/rpc/'))return route.abort();
  try{const name=path.split('/').at(-1);let result=await serial(()=>callRpc(db,name,req.postDataJSON()||{}));if(name==='app_status')result={...result,realtimeAvailable:false};await route.fulfill({contentType:'application/json',body:JSON.stringify(result)});}
  catch(e){await route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:e.message})});}
 });
 page=await context.newPage();page.setDefaultTimeout(20000);page.on('pageerror',e=>errors.push(e.message));
 const rpc=(name,args={})=>serial(()=>userRpc(db,a,name,args));
 await page.goto(url);await page.locator('#username').fill('kiflo');await page.locator('#password').fill('testing42');await page.locator('#auth-submit').click();await page.locator('.home-view').waitFor();
 check(await page.getByRole('link',{name:/Bestenlisten/}).count()===1,'Lager enthält Bestenlisten');
 await page.goto(url+'/#/play');check(await page.locator('#new-solo').count()===1,'Eigener Einzelspiel-Startknopf');
 await page.locator('#new-solo').click();await page.locator('#game-map-selection button').click();
 check(await page.locator('#game-password').count()===0&&await page.locator('#game-max-players').count()===0,'Einzelspiele haben weder Lobby-Passwort noch öffentliche Plätze');
 await page.locator('#solo-bots').selectOption('1');await page.locator('#solo-red-every').selectOption('0');await page.locator('#create-game').click();await page.locator('#game-board-svg').waitFor();
 const humanId=new URLSearchParams(new URL(page.url()).hash.split('?')[1]).get('id');
 check((await rpc('get_game',{p_game_id:humanId})).game.status==='playing','Einzelspiel startet unmittelbar ohne Warteraum');
 check(await page.locator('.opponent-seat.is-ai').count()===1,'KI-Sitz ist experimentell markiert');
 await page.locator('#roll-dice').click();await page.locator('#gameTargets [data-cell-id="1"]').click();
 await page.waitForFunction(()=>document.querySelector('#game-round')?.textContent.includes('Runde 2'));
 await page.waitForFunction(()=>document.querySelector('#game-dice')?.querySelectorAll('.die').length===4||document.querySelector('#turn-message')?.textContent==='Du bist am Zug');
 const turn=(await rpc('get_game',{p_game_id:humanId})).game;
 check(turn.round===2&&turn.phase==='choosing','KI würfelt ihren nächsten Zug automatisch');
 check(turn.ownState.redUses===3,'Menschlicher Zug verbraucht keinen unnötigen Sonderwürfel');
 await page.goto(url+'/#/solo');await page.locator('#game-map-selection button').click();await page.locator('#solo-ai-only').check();await page.locator('#solo-test-runs').selectOption('3');
 check(await page.locator('#solo-bots').inputValue()==='2','KI-only-Modus stellt mindestens zwei KI-Plätze ein');
 await page.locator('#create-game').click();await page.locator('.ai-lab-view').waitFor();
 await page.waitForFunction(()=>document.querySelector('#ai-lab-status')?.textContent.includes('Testreihe abgeschlossen'),{},{timeout:40000});
 check(await page.locator('.ai-series-row').count()===3,'Drei KI-Partien laufen selbstständig hintereinander bis zum Ende');
 const experiments=(await rpc('list_ai_experiments')).games;check(experiments.filter(g=>g.status==='finished').length===3,'Alle KI-Testpartien haben vollständige Ergebnisse');
 check((await rpc('list_highscores',{p_map_version_id:map.versionId})).total===0,'KI-Testreihen erscheinen nicht in menschlicher Bestenliste');
 await page.screenshot({path:out+'/KI_Testreihe.png',fullPage:true});
 await page.locator('.ai-series-row').first().getByRole('button',{name:'Ergebnis & Replay'}).click();await page.locator('#watch-replay').click();await page.locator('#replay-player option').first().waitFor({state:'attached'});
 check(JSON.stringify(await page.locator('#replay-speed option').allTextContents())===JSON.stringify(['Normal','Schnell','Sehr schnell']),'Replay-Geschwindigkeit ist sinnvoll geordnet');
 await page.locator('#replay-fullscreen').click();check(await page.evaluate(()=>Boolean(document.fullscreenElement)),'Replay unterstützt Vollbild');
 await page.locator('#replay-player').selectOption({index:1});await page.locator('#replay-position').evaluate(n=>{n.value=n.max;n.dispatchEvent(new Event('input',{bubbles:true}));});
 await page.locator('#replay-board-svg .played-mark.pencil').first().waitFor();check(true,'Replay verwendet den Markierungsstil des gewählten KI-Spielers');
 await page.locator('.replay-dialog').getByRole('button',{name:'Schließen',exact:true}).click();await page.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();
 // Vorhandene menschliche Partie abschließen, damit Bestenlisten wirklich Daten zeigen.
 const participants=(await rpc('get_game',{p_game_id:humanId})).game.participants;
 for(const p of participants)await serial(()=>seedState(db,humanId,{profile:{id:p.id}},{reached:['1','2','3','4','5'],monsterHits:{4:2,5:3},diamonds:12,firstKills:['4','5']}));
 await serial(()=>db.query('select dungeon_private.finalize_game($1)',[humanId]));
 await page.goto(url+'/#/game?id='+humanId);await page.locator('.result-dialog .highscore-row').waitFor();
 check(await page.locator('.result-dialog .personal-rank').isVisible(),'Abschluss zeigt Bestenliste und persönliche Position');
 await page.locator('.result-dialog').getByRole('button',{name:'Schließen',exact:true}).click();await page.goto(url+'/#/highscores');await page.locator('.highscore-row').waitFor();await page.locator('.highscore-row summary').click();
 check(await page.locator('.highscore-details').innerText().then(t=>t.includes('Punkte')&&t.includes('Runden')&&t.includes('KI (experimentell)')),'Details zeigen Punkte, Runden und KI-Gegner');
 await page.screenshot({path:out+'/Bestenliste.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Bestenliste passt auf ein Handy');
 await page.screenshot({path:out+'/Bestenliste_Handy.png',fullPage:true});
 check(errors.length===0,`Keine JavaScript-Fehler (${errors.join('; ')})`);console.log(`${checks} Einzelspiel-/KI-Browserprüfungen erfolgreich.`);
}catch(error){if(page)await page.screenshot({path:out+'/Fehler.png',fullPage:true}).catch(()=>{});throw error;}
finally{await browser?.close();server.kill();await queue;await db?.close();}
