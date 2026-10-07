import {publishFixture} from './helpers/games.mjs';
import {randomUUID} from 'node:crypto';
import {createStabilityDatabase} from './helpers/stability.mjs';
import {upgradeDocument} from '../web/js/maps/features.js';
// Echter Browser + echtes PostgreSQL. Supabase-Gateway/Storage lokal simuliert.
// Das Live-Projekt des Benutzers wird nicht verändert.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';
import {createHandler} from '../supabase/functions/map-asset-upload/index.ts';
import {CONFIG} from '../web/js/config.js';
import {emptyDocument} from '../web/js/maps/model.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url));
const address='http://localhost:5195',server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5195'},stdio:'ignore'});
const db=await createStabilityDatabase(),objects=new Map(),errors=[],saveRequests=[];let browser,activePage,checks=0,queue=Promise.resolve(),dropNextSave=false;
const serial=fn=>{const p=queue.then(fn);queue=p.catch(()=>{});return p;};
function check(value,label){assert.ok(value,label);checks++;console.log(`PASS ${label}`);}
const upload=createHandler({env:name=>({SUPABASE_URL:CONFIG.supabaseUrl,SUPABASE_SECRET_KEYS:JSON.stringify({default:'sb_secret_local_test_only'})})[name],fetcher:async(url,opts)=>{
  const path=new URL(url).pathname;
  if(path.startsWith('/rest/')){try{return Response.json(await serial(()=>callRpc(db,path.split('/').at(-1),JSON.parse(opts.body),'service_role')));}catch(e){return Response.json({message:e.message},{status:400});}}
  if(opts.method==='DELETE'){for(const p of JSON.parse(opts.body).prefixes)objects.delete(p);return Response.json({ok:true});}
  objects.set(path.replace('/storage/v1/object/map-assets/',''),{bytes:opts.body,type:opts.headers['Content-Type']});return Response.json({ok:true});
}});
async function gateway(context,flags={offline:false}){
 context.on('page',page=>page.on('pageerror',e=>errors.push(e.message)));
 await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
  const req=route.request(),path=new URL(req.url()).pathname,headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,GET,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token'};
  if(flags.offline){await route.abort('failed');return;}
  if(req.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
  if(path.startsWith('/storage/v1/object/public/map-assets/')){const asset=objects.get(path.replace('/storage/v1/object/public/map-assets/',''));await route.fulfill({status:asset?200:404,headers:{...headers,'content-type':asset?.type || 'text/plain'},body:asset?Buffer.from(asset.bytes):''});return;}
  if(path==='/functions/v1/map-asset-upload'){const r=await upload(new Request(req.url(),{method:req.method(),headers:req.headers(),body:req.postDataBuffer()}));await route.fulfill({status:r.status,headers,body:await r.text()});return;}
  try{const args=req.postDataJSON(),method=path.split('/').at(-1),result=await serial(()=>callRpc(db,method,args));if(method==='save_map'){saveRequests.push(args);if(dropNextSave){dropNextSave=false;await route.abort('failed');return;}}await route.fulfill({status:200,headers,body:JSON.stringify(result)});}catch(error){await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message})});}
 });
}

async function saved(page){await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Gespeichert'),{},{timeout:25000});}
const draw=page=>page.frameLocator('#dungeon-editor');
try {
 await db.exec(await readFile(root+'/supabase/migrations/014_editor_upgrade.sql','utf8'));
 const user=await callRpc(db,'register_player',{p_username:'flo',p_display_name:'Flo',p_password:'testing42',p_access_code:TEST_ACCESS_CODE});
 await mkdir(root+'/test-results',{recursive:true});
 for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH || undefined,args});
 const context=await browser.newContext({viewport:{width:1500,height:1100}});await gateway(context);const page=await context.newPage();activePage=page;
 await page.goto(address);await page.fill('#username','flo');await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();await page.click('.menu-card[href="#/editor"]');await page.click('#new-map');await page.fill('#map-name-input','Runen und Portale');await page.click('.workshop-dialog button[type="submit"]');await saved(page);
 const mapId=new URLSearchParams(page.url().split('?')[1]).get('id'),frame=draw(page);
 for(const type of ['normal','rune','bonus','trap','portal','crazy','goldSack','goldCoin','monster','boss']){await frame.locator(`[data-add="${type}"]`).click();check(await frame.locator(`.room.${type}`).count()>0,`${type} lässt sich über die Werkzeugleiste erstellen`);}
 await frame.locator('.room.crazy').click({button:'right'});await frame.locator('[data-number="3"]').click();await frame.locator('[data-number="8"]').click();await frame.locator('[data-number="doubles"]').click();await frame.locator('#closeMenu').click();await saved(page);
 check(await page.evaluate(()=>JSON.stringify(document.querySelector('#dungeon-editor').contentWindow.DungeonEditor.getDocument().rooms.find(r=>r.type==='crazy').requirements))==='[3,8,"doubles"]','Verrücktes Feld erlaubt mehrere Zahlen einschließlich Pasch');
 await frame.locator('.room.trap').click({button:'right'});await frame.locator('#trapKind').selectOption('life');await frame.locator('#trapCost').fill('2');await frame.locator('#trapCost').dispatchEvent('change');await frame.locator('[data-number="5"]').click();await saved(page);
 let data=(await serial(()=>db.query('select document from dungeon_maps where id=$1',[mapId]))).rows[0].document;check(data.rooms.find(r=>r.type==='trap').trapKind==='life'&&data.rooms.find(r=>r.type==='trap').trapCost===2,'Fallenkosten werden gespeichert');
 const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=64;c.height=64;const ctx=c.getContext('2d');ctx.fillStyle='#6ab778';ctx.fillRect(5,5,54,54);return c.toDataURL('image/png').split(',')[1];});
 const defeatedPng=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=64;c.height=64;const ctx=c.getContext('2d');ctx.fillStyle='#95504d';ctx.beginPath();ctx.arc(32,32,25,0,Math.PI*2);ctx.fill();return c.toDataURL('image/png').split(',')[1];});
 await frame.locator('.room.monster').click({button:'right'});await frame.locator('#enemyName').fill('Höhlentroll');await frame.locator('#enemyName').dispatchEvent('change');await frame.locator('#enemyImageInput').setInputFiles({name:'troll.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});await page.waitForFunction(()=>document.querySelector('#dungeon-editor').contentWindow.DungeonEditor.getDocument().rooms.find(r=>r.type==='monster').image);await frame.locator('#defeatedImageInput').setInputFiles({name:'troll-besiegt.png',mimeType:'image/png',buffer:Buffer.from(defeatedPng,'base64')});await page.waitForFunction(()=>document.querySelector('#dungeon-editor').contentWindow.DungeonEditor.getDocument().rooms.find(r=>r.type==='monster').defeatedImage);await frame.locator('#defeatedPreview').check();await frame.locator('#editEnemyImage').click();
 assert.equal(await frame.locator('[data-enemy-image]').getAttribute('href'),'data:image/png;base64,'+defeatedPng);check(await frame.locator('[data-enemy-image]').count()===1,'Besiegtes Bild lässt sich auf der Zeichenfläche anzeigen');
 // Move using its selection box, then verify the independent layout was written.
 const imageBox=await frame.locator('[data-enemy-image]').boundingBox();await page.mouse.move(imageBox.x+imageBox.width/2,imageBox.y+imageBox.height/2);await page.mouse.down();await page.mouse.move(imageBox.x+imageBox.width/2+20,imageBox.y+imageBox.height/2+20,{steps:5});await page.mouse.up();await saved(page);
 data=(await serial(()=>db.query('select document from dungeon_maps where id=$1',[mapId]))).rows[0].document;check(data.rooms.find(r=>r.type==='monster').defeatedImage.src.startsWith('asset:'),'Besiegtes Bild wird als Bucket-Referenz gespeichert');check(Boolean(data.rooms.find(r=>r.type==='monster').defeatedImageLayout),'Besiegtes Bild erhält seine eigene verschiebbare Position');
 await frame.locator('#board').press('Escape');await page.click('#map-rules');await page.getByRole('checkbox',{name:'Fernglas',exact:true}).check();await page.selectOption('#goal-1-type','allType');await page.selectOption('#goal-1-field-type','trap');await page.fill('#goal-1-first','5');await page.fill('#goal-1-later','2');await page.selectOption('#goal-2-type','connect');const targetChecks=page.locator('.rule-section').filter({hasText:'Bonusaufgabe 2'}).locator('.rule-targets input');await targetChecks.nth(0).check();await targetChecks.nth(1).check();await page.click('#save-map-rules');await saved(page);
 check(await frame.locator('[stroke="#d2a137"]').count()===2,'Verbindungsaufgabe markiert beide Endpunkte auf dem Plan');
 data=(await serial(()=>db.query('select document from dungeon_maps where id=$1',[mapId]))).rows[0].document;check(data.rules.goals[0].reward.first===5&&data.allowedPowerups.includes('binocular'),'Aufgabenbelohnungen und Fernglas sind gespeichert');
 // Preview contains the drawn map instead of only room geometry.
 check(data.previewImage.src.startsWith('asset:')&&data.previewImage.width<=640,'Echte Kartenvorschau wird automatisch erzeugt und gespeichert');
 await page.reload();await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent==='Alle Änderungen gespeichert');check(await frame.locator('.room.crazy').count()===1&&await frame.locator('.room.goldCoin').count()===1,'Neue Feldtypen überstehen Speichern und Neuladen');
 const event=page.waitForEvent('download');await page.click('#export-map-json');const download=await event,stream=await download.createReadStream(),chunks=[];for await(const chunk of stream)chunks.push(chunk);const exported=JSON.parse(Buffer.concat(chunks));check(exported.rooms.find(r=>r.type==='monster').defeatedImage.src.startsWith('data:'),'JSON-Export bettet auch das besiegte Bild ein');
 await frame.locator('#openLayout').click();await frame.locator('#layoutPNG').click();await frame.locator('#pngPreview').waitFor({state:'visible'});check((await frame.locator('#pngPreview').getAttribute('src')).startsWith('data:image/png'),'Automatische Bonusaufgaben erscheinen im druckbaren PNG');await writeFile(root+'/test-results/editor-upgrade-print.png',Buffer.from((await frame.locator('#pngPreview').getAttribute('src')).split(',')[1],'base64'));await frame.locator('#closeFile').click();await frame.locator('#closeLayout').click();
 await page.click('#editor-fullscreen');await page.waitForFunction(()=>Boolean(document.fullscreenElement)||Boolean(document.querySelector('.editor-maximized')));check(await page.evaluate(()=>Boolean(document.fullscreenElement)||document.querySelector('.editor-maximized')),'Editor-Vollbild funktioniert');await page.click('#editor-fullscreen');
 await page.screenshot({path:root+'/test-results/editor-upgrade-desktop.png',fullPage:true});await page.click('.editor-back');await page.locator('.map-preview-image').waitFor();check(await page.locator('.map-preview-image').count()===1,'Kartenliste zeigt die gerenderte Bildvorschau');
 await page.screenshot({path:root+'/test-results/editor-upgrade-library.png',fullPage:true});// A pre-update published version gets a real background preview without a write.
 const path=`${randomUUID()}/${randomUUID()}.png`;await serial(()=>db.query("insert into dungeon_private.assets(path,kind,owner_id,mime_type,bytes) values($1,'map',$2,'image/png',500)",[path,user.profile.id]));objects.set(path,{bytes:Buffer.from(png,'base64'),type:'image/png'});
 const legacy=emptyDocument();legacy.rooms=[{id:1,type:'normal',x:0,y:0,w:4,h:4,number:7,start:true,dimmed:false},{id:2,type:'monster',x:4,y:0,w:8,h:8,number:null,start:false,dimmed:false,name:'Alte Mine',hits:2,attacks:[{number:7,state:'active'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}];legacy.background={x:-4,y:-4,w:20,h:16,image:{src:`asset:${path}`,width:64,height:64,name:'Hintergrund'}};
 const published=await serial(()=>publishFixture(db,user,'Bestehende Karte',legacy)),before=(await serial(()=>db.query('select document,revision from dungeon_maps where id=$1',[published.id]))).rows[0];
 await page.goto(address+'/#/new-game');await page.locator('.game-map-choice .map-preview-image').waitFor();check(await page.locator('.game-map-choice .map-preview-image').count()===1,'Spielauswahl zeigt auch für alte veröffentlichte Karten eine echte Vorschau');
 const after=(await serial(()=>db.query('select document,revision from dungeon_maps where id=$1',[published.id]))).rows[0];check(JSON.stringify(before)===JSON.stringify(after),'Vorschauerzeugung verändert keine veröffentlichte Kartenversion');
 check(errors.length===0,`Keine Browserfehler: ${errors.join('; ')}`);console.log(`TOTAL ${checks} Editor-Browserprüfungen bestanden.`);
}catch(error){console.error(error.stack);process.exitCode=1;await activePage?.screenshot({path:root+'/test-results/editor-upgrade-failure.png',fullPage:true}).catch(()=>{});}finally{await browser?.close();server.kill();await db.close();}
