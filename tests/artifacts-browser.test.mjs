// Isolierte Browserprüfung: kein Zugriff auf die produktive Datenbank.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {readFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {createAdventurerDatabase} from './helpers/adventurers.mjs';
import {soloFixture} from './helpers/solo-ai.mjs';
import {register,userRpc,publishFixture} from './helpers/games.mjs';
import {installTestDice,forceDice,seedState} from './helpers/turns.mjs';
import {callRpc} from './helpers/database.mjs';
import {browserOptions} from './helpers/browser.mjs';
import {CONFIG} from '../web/js/config.js';
const root=fileURLToPath(new URL('../',import.meta.url)),url='http://localhost:5220',out=root+'test-artifacts/1_3_0';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5220'},stdio:'ignore'});
let db,browser,page,queue=Promise.resolve();const errors=[];
const serial=fn=>{const next=queue.then(fn);queue=next.catch(()=>{});return next;};
try{
 db=await createAdventurerDatabase();await db.exec(await readFile(new URL('../supabase/migrations/036_artifacts_mobile.sql',import.meta.url),'utf8'));
 await installTestDice(db);const user=await register(db,'HandyFlo');const doc=soloFixture();doc.allowedPowerups=['magicDie','numberFlask','binocular'];const map=await publishFixture(db,user,'Handykarte',doc);
 await db.exec("update dungeon_players set preferences=preferences||'{\"diceAnimation\":\"none\",\"sound\":false}'::jsonb");
 const create=await userRpc(db,user,'create_solo_game',{p_map_version_id:map.versionId,p_name:'Mobiltest',p_settings:{cards:'open',hints:true,fog:true,fogRange:1,allowedPowerups:doc.allowedPowerups},p_bot_count:0,p_red_every:1,p_ai_only:false,p_request_id:randomUUID()});const id=create.gameId;
 for(let i=0;i<100;i++){try{if((await fetch(url)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 await mkdir(out,{recursive:true});browser=await chromium.launch(browserOptions());const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
 await context.route(CONFIG.supabaseUrl+'/**',async route=>{const request=route.request(),path=new URL(request.url()).pathname;if(!path.startsWith('/rest/v1/rpc/'))return route.abort();try{let result=await serial(()=>callRpc(db,path.split('/').at(-1),request.postDataJSON()||{}));if(path.endsWith('/app_status'))result={...result,realtimeAvailable:false};await route.fulfill({contentType:'application/json',body:JSON.stringify(result)});}catch(error){await route.fulfill({status:400,contentType:'application/json',body:JSON.stringify({message:error.message})});}});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));await page.goto(url);await page.locator('#username').fill('handyflo');await page.locator('#password').fill('testing42');await page.locator('#auth-submit').click();await page.locator('.home-view').waitFor();
 await page.goto(url+'/#/game?id='+id);await page.locator('#game-board-svg').waitFor();
 const layout=async()=>page.evaluate(()=>{const box=selector=>{const r=document.querySelector(selector).getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};};return {board:box('.game-board-wrap'),dock:box('.game-dock'),side:box('.game-side'),screen:{w:innerWidth,h:innerHeight},overflow:document.documentElement.scrollWidth>innerWidth};});
 let b=await layout();assert.ok(b.board.w>b.screen.w*.85,JSON.stringify(b));assert.ok(b.board.y<b.dock.y&&b.dock.y<b.side.y,JSON.stringify(b));assert.ok(!b.overflow);await page.screenshot({path:out+'/Hochformat.png'});
 await page.setViewportSize({width:844,height:390});await page.waitForTimeout(100);b=await layout();assert.ok(b.dock.x<b.board.x&&b.board.x<b.side.x,JSON.stringify(b));assert.ok(b.board.h>230,JSON.stringify(b));assert.ok(!b.overflow);await page.screenshot({path:out+'/Querformat.png'});
 await serial(()=>seedState(db,id,user,{powerups:['magicDie','numberFlask'],magicUses:2,flaskUses:1,reached:['1','2','3']}));await serial(()=>forceDice(db,[3,5,1,1]));await page.locator('#refresh-game').click();await page.locator('#roll-dice').click();await page.locator('#use-magic-die').waitFor();assert.ok(await page.locator('#use-number-flask').isVisible());
 const monster=page.locator('#gameTargets [data-cell-id="4"]');await monster.click();await page.waitForFunction(()=>document.querySelector('#gameTargets [data-cell-id="4"]')?.getAttribute('aria-disabled')==='true');assert.ok(!await monster.evaluate(n=>n.classList.contains('legal-cell')||n.classList.contains('red-cell')),'Monsterrahmen verschwindet nach dem Zug');
 await serial(()=>forceDice(db,[1,1,1,1]));await page.locator('#roll-dice').click();assert.ok(!await monster.evaluate(n=>n.classList.contains('legal-cell')||n.classList.contains('red-cell')),'Kein alter Rahmen in der Folgerunde');
 assert.deepEqual(errors,[]);console.log('Mobile Anordnung, Powerups und Monsterrahmen im Browser geprüft.');
}finally{await browser?.close();server.kill();await queue;await db?.close();}
