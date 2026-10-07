import {createHandler} from '../supabase/functions/map-asset-upload/index.ts';
// Browserprüfung mit echter isolierter SQL-Datenbank. Kein Zugriff auf Live-Daten.
import {chromium} from 'playwright';import assert from 'node:assert/strict';import {spawn} from 'node:child_process';import {createRequire} from 'node:module';import {readFile,mkdir,writeFile} from 'node:fs/promises';import {fileURLToPath} from 'node:url';import {randomUUID} from 'node:crypto';
import {createShopDatabase} from './helpers/shop.mjs';import {modernFixture} from './helpers/game-upgrade.mjs';import {register,userRpc,publishFixture} from './helpers/games.mjs';import {newPlayGame,installTestDice,forceDice} from './helpers/turns.mjs';import {callRpc} from './helpers/database.mjs';import {CONFIG} from '../web/js/config.js';import {compileDocument} from '../web/js/maps/features.js';
const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url)),url='http://localhost:5202';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5202'},stdio:'ignore'});let browser,db,page,queue=Promise.resolve(),checks=0,phase='setup';const errors=[],requests=[],images=new Map();
const watchdog=setTimeout(()=>{console.error(`WATCHDOG: ${phase}`);server.kill();process.exit(1);},240000);
const serial=fn=>{const job=queue.then(fn);queue=job.catch(()=>{});return job;},check=(v,label)=>{assert.ok(v,label);checks++;console.log('PASS',label);};
const rpc=(u,name,args={})=>serial(()=>userRpc(db,u,name,args));
async function refresh(){await page.locator('#refresh-game').click();await page.waitForTimeout(150);}
const upload=createHandler({env:name=>({SUPABASE_URL:CONFIG.supabaseUrl,SUPABASE_SECRET_KEYS:JSON.stringify({default:'sb_secret_local_test_only'})})[name],fetcher:async(url,opts)=>{
 const path=new URL(url).pathname;
 if(path.startsWith('/rest/')){try{return Response.json(await serial(()=>callRpc(db,path.split('/').at(-1),JSON.parse(opts.body),'service_role')));}catch(e){return Response.json({message:e.message},{status:400});}}
 if(opts.method==='DELETE'){for(const p of JSON.parse(opts.body).prefixes)images.delete(p);return Response.json({ok:true});}
 images.set(path.replace('/storage/v1/object/map-assets/',''),Buffer.from(opts.body));return Response.json({ok:true});
}});
async function gateway(context){context.on('page',p=>p.on('pageerror',e=>errors.push(e.message)));await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
 const req=route.request(),path=new URL(req.url()).pathname,headers={'access-control-allow-origin':'*','access-control-allow-methods':'GET,POST,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
 if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
 if(path.includes('/storage/v1/object/public/map-assets/')){const img=images.get(path.split('/map-assets/')[1]);await route.fulfill({status:img?200:404,headers:{...headers,'content-type':'image/png'},body:img||''});return;}
 if(path==='/functions/v1/map-asset-upload'){const r=await upload(new Request(req.url(),{method:req.method(),headers:req.headers(),body:req.postDataBuffer()}));await route.fulfill({status:r.status,headers,body:await r.text()});return;}
 const method=path.split('/').at(-1),args=req.postDataJSON();requests.push(method);try{const result=await serial(()=>callRpc(db,method,args));if(method==='app_status')result.realtimeAvailable=false;await route.fulfill({status:200,headers,body:JSON.stringify(result)});}catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
});}
async function login(user){await page.goto(url);await page.getByRole('tab',{name:'Anmelden'}).click();await page.locator('#username').fill(user.profile.username);await page.locator('#password').fill('testing42');await page.locator('#auth-submit').click();await page.waitForURL('**/#/home');}
async function image(user,name,first,second){const data=await page.evaluate(({first,second})=>{const c=document.createElement('canvas');c.width=640;c.height=320;const x=c.getContext('2d'),g=x.createLinearGradient(0,0,640,320);g.addColorStop(0,first);g.addColorStop(1,second);x.fillStyle=g;x.fillRect(0,0,640,320);return c.toDataURL('image/png');},{first,second});const path=`${randomUUID()}/${randomUUID()}.png`,bytes=Buffer.from(data.split(',')[1],'base64');images.set(path,bytes);await db.query("insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values($1,'map',$2,'image/png',$3)",[path,user.profile.id,bytes.length]);return {src:`asset:${path}`,name,width:640,height:320};}
try{
 db=await createShopDatabase();await db.exec(await readFile(root+'/supabase/migrations/020_round_two.sql','utf8'));
 const a=await register(db,'PolishBrowser'),b=await register(db,'PolishGuest');
 await db.exec(await readFile(root+'/supabase/migrations/022_print_and_cosmetics.sql','utf8'));
 for(let i=0;i<100;i++){try{if((await fetch(url)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args});
 const context=await browser.newContext({viewport:{width:1366,height:900},acceptDownloads:true});await gateway(context);page=await context.newPage();page.setDefaultTimeout(15000);await login(a);
 const d=compileDocument(modernFixture());d.allowedPowerups=['extraLife','redDice','torch'];d.background={x:-8,y:-8,w:84,h:32,image:await image(a,'Mine','#294537','#bd8048')};
 const map=await publishFixture(db,a,'Saubere Druckmine',d);
 phase='new-game';await page.goto(url+'/#/new-game');await page.locator('#game-map-selection button').first().click();
 check(await page.locator('#game-powerups-extraLife').isChecked()&&!await page.locator('#game-powerups-horn').isChecked(),'Powerupauswahl beginnt mit den Kartenvorgaben');
 check(await page.locator('#game-powerups-horn').isDisabled(),'Nebelartefakte sind ohne Fog inaktiv');
 await page.locator('#game-fog').check();await page.locator('#game-powerups-horn').check();await page.locator('#game-powerups-extraLife').uncheck();await page.locator('#create-game').click();await page.locator('#start-game').waitFor();
 const gameId=new URLSearchParams(page.url().split('?')[1]).get('id');let g=(await rpc(a,'get_game',{p_game_id:gameId,p_include_definition:true})).game;
 check(g.settings.allowedPowerups.includes('horn')&&!g.settings.allowedPowerups.includes('extraLife'),'Auswahl wird für diese Partie gespeichert');
 check((await rpc(a,'list_game_maps')).maps[0].allowedPowerups.includes('extraLife'),'Veröffentlichte Kartenvorgabe bleibt erhalten');
 phase='lobby';await page.locator('#edit-lobby-powerups').click();await page.locator('#lobby-powerups-axe').check();await page.locator('#save-lobby-powerups').click();await page.locator('.lobby-powerup-dialog').waitFor({state:'detached'});
 g=(await rpc(a,'get_game',{p_game_id:gameId})).game;check(g.powerupPool.includes('axe'),'Host kann die Partieauswahl im Warteraum ändern');
 await db.query('insert into dungeon_private.marking_credits(player_id,game_id,amount) values($1,$2,200)',[a.profile.id,gameId]);
 phase='shop';await page.goto(url+'/#/settings');await page.locator('[data-buy-cosmetic="diceStyle:midnight"]').waitFor();await page.waitForFunction(()=>!document.querySelector('[data-buy-cosmetic="diceStyle:midnight"]').disabled);
 check(await page.locator('[data-shop-category="diceStyle"] .cosmetic-preview .dice-face').count()===12,'Würfelkarten zeigen echte Würfelvorschauen');
 check(await page.locator('[data-shop-category="cupStyle"] .dice-cup').count()===3,'Becherkarten zeigen alle drei illustrierten Varianten');
 check(await page.locator('[data-shop-category="campStyle"] img').count()===4,'Lagerhintergründe haben vier Bildvorschauen');
 check(await page.locator('#settings-form select').count()===0,'Kosmetik und Animation benötigen keine Dropdownlisten');
 page.on('dialog',dialog=>dialog.accept());await page.locator('#music').check();await page.locator('#sound').uncheck();await page.locator('#diceAnimation').fill('3');await page.locator('#diceAnimation').dispatchEvent('input');
 await page.locator('[data-buy-cosmetic="diceStyle:midnight"]').click();await page.waitForFunction(()=>!document.querySelector('#diceStyle-midnight').disabled&&document.querySelector('#diceStyle-midnight').checked);
 check(await page.locator('#shop-balance').textContent()==='160','Kosmetikkauf verwendet Diamanten aus dem gemeinsamen Shopkonto');
 check(await page.locator('#music').isChecked()&&!await page.locator('#sound').isChecked(),'Ungespeicherte Soundschalter bleiben beim Kauf erhalten');
 check(await page.locator('#dice-animation-value').textContent()==='Lang · 6 s','Animationsregler zeigt die gewählte Dauer');
 await page.locator('#save-settings').click();await page.waitForFunction(()=>document.querySelector('.feedback.success')?.textContent.includes('gespeichert'));
 const prefs=(await rpc(a,'get_player_profile')).profile.preferences;check(prefs.diceStyle==='midnight'&&prefs.diceAnimation==='long'&&prefs.music&&!prefs.sound,'Shopauswahl, Slider und Audio werden gespeichert');
 await mkdir(root+'/test-results',{recursive:true});await page.screenshot({path:root+'/test-results/polish-shop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});await page.waitForTimeout(100);check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Shop passt auch auf ein schmales Handy');await page.screenshot({path:root+'/test-results/polish-shop-mobile.png',fullPage:true});await page.setViewportSize({width:1366,height:900});
 phase='print';const created=await rpc(a,'create_map',{p_name:'Druckleisten Test'}),id=created.map.id,editorId=randomUUID();const lock=await rpc(a,'acquire_map_lock',{p_map_id:id,p_editor_id:editorId});
 d.allowedPowerups=['extraLife','redDice','torch','axe','binocular','horn'];
 await rpc(a,'save_map',{p_map_id:id,p_editor_id:editorId,p_expected_revision:lock.map.revision,p_name:'Druckleisten Test',p_document:d,p_request_id:randomUUID()});await rpc(a,'release_map_lock',{p_map_id:id,p_editor_id:editorId});
 await page.goto(url+`/#/editor?id=${id}`);await page.waitForFunction(()=>!document.querySelector('#map-rules').disabled);const frame=page.frameLocator('#dungeon-editor');
 await frame.locator('#openLayout').click();await frame.locator('#layoutDialog[open]').waitFor();await frame.locator('#layoutPNG').click();await frame.locator('#fileDialog[open] #pngPreview').waitFor();
 const data=await frame.locator('#pngPreview').getAttribute('src');check(data?.startsWith('data:image/png;base64,'),'Drucklayout wird erfolgreich als PNG exportiert');await writeFile(root+'/test-results/polish-print.png',Buffer.from(data.split(',')[1],'base64'));
 const dimensions=await frame.locator('#pngPreview').evaluate(n=>({width:n.naturalWidth,height:n.naturalHeight}));check(dimensions.width>=1600&&dimensions.height>=1000,'Druckexport enthält den vollständigen Spielbogen in hoher Auflösung');
 const stats=await page.locator('#dungeon-editor').evaluate(async frame=>{const d=frame.contentWindow.DungeonEditor.getDocument(),{printScorePlan}=await import('./editor/print-tracks.js');return printScorePlan(d.rooms,d.rules,d.allowedPowerups);});
 check(stats.tracks.find(t=>t.type==='goldSack').count===1&&stats.tracks.find(t=>t.type==='goldCoin').count===1,'Druckpunkte werden aus den tatsächlichen Goldfeldern berechnet');
 check(errors.length===0,`Keine JavaScript-Fehler: ${errors.join('; ')}`);console.log(`TOTAL ${checks} neue Browserprüfungen bestanden.`);
}catch(error){console.error('TESTPHASE',phase);if(page){console.error(await page.locator('.feedback,#map-save-status').allTextContents().catch(()=>[]));await mkdir(root+'/test-results',{recursive:true});await page.screenshot({path:root+'/test-results/polish-failure.png',fullPage:true}).catch(()=>{});}throw error;}
finally{clearTimeout(watchdog);await browser?.close();await db?.close();server.kill();}
