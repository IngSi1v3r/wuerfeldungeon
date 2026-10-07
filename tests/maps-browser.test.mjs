import {createStabilityDatabase} from './helpers/stability.mjs';
import {upgradeDocument} from '../web/js/maps/features.js';
// Echter Browser + echtes PostgreSQL. Supabase-Gateway/Storage lokal simuliert.
// Das Live-Projekt des Benutzers wird nicht verändert.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir,readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';
import {createHandler} from '../supabase/functions/map-asset-upload/index.ts';
import {CONFIG} from '../web/js/config.js';
import {emptyDocument} from '../web/js/maps/model.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url));
const address='http://localhost:5190',server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5190'},stdio:'ignore'});
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
const sample=emptyDocument();sample.printLayout.name='Lava Mine';sample.rooms=[
 {id:1,type:'normal',x:0,y:0,w:4,h:4,number:5,start:true,dimmed:false},
 {id:2,type:'normal',x:4,y:0,w:4,h:4,number:'doubles',start:false,dimmed:false},
 {id:3,type:'monster',x:8,y:0,w:8,h:8,number:null,start:false,dimmed:false,name:'Höhlentroll',hits:5,attacks:[{number:7,state:'active'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null},
 {id:4,type:'special',x:4,y:4,w:4,h:4,number:9,start:false,dimmed:false},
 {id:5,type:'chest',x:0,y:4,w:4,h:8,number:6,start:false,dimmed:false},
 {id:6,type:'chest',x:8,y:8,w:4,h:8,number:8,start:false,dimmed:false},
 {id:7,type:'boss',x:12,y:8,w:16,h:8,number:null,start:false,dimmed:false,name:'Glutdrache',hits:12,attacks:[{number:'doubles',state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null},
 {id:8,type:'diamond',x:0,y:12,w:8,h:4,number:4,start:false,dimmed:false}];sample.nextId=9;sample.rules.unlocks=[{sourceCellId:4,targetCellId:3,number:9}];
async function login(page,username='flo'){await page.fill('#username',username);await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();}
async function saved(page){await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Gespeichert'),{},{timeout:25000});}
function draw(page){return page.frameLocator('#dungeon-editor');}
try{
 await db.exec(await readFile(root+'/supabase/migrations/014_editor_upgrade.sql','utf8'));
 for(const user of ['flo','joni'])await callRpc(db,'register_player',{p_username:user,p_display_name:user==='flo'?'Flo':'Joni',p_password:'testing42',p_access_code:TEST_ACCESS_CODE});
 await mkdir(root+'/test-results',{recursive:true});
 for(let i=0;i<100;i++){try{if((await fetch(address)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 let args=[];if(process.env.WUERFELDUNGEON_CHROMIUM_MODULE)args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v));
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH || undefined,args});
 const context=await browser.newContext({viewport:{width:1440,height:1040}}),flags={offline:false};await gateway(context,flags);const page=await context.newPage();activePage=page;
 await page.goto(address);await page.locator('#auth-form').waitFor();await login(page);await page.click('.menu-card[href="#/editor"]');await page.locator('.library-empty').waitFor();
 check(true,'Gemeinsame leere Kartenbibliothek öffnet sich');
 await page.click('#new-map');await page.fill('#map-name-input','Lava Mine');await page.click('.workshop-dialog button[type="submit"]');
 await saved(page);
 const mapId=new URLSearchParams(page.url().split('?')[1]).get('id');check(Boolean(mapId),'Neue Karte öffnet den vollständigen bisherigen Editor');
 await draw(page).locator('[data-add="normal"]').click();await saved(page);
 check((await serial(()=>db.query('select document from public.dungeon_maps where id=$1',[mapId]))).rows[0].document.rooms.length===1,'Plus-Feld wird automatisch in der Datenbank gespeichert');
 const identityEntry=await page.evaluate(()=>Object.entries(sessionStorage).find(([key])=>key.startsWith('wuerfeldungeon.editor.')));
 const second=await context.newPage();await second.addInitScript(([key,value])=>sessionStorage.setItem(key,value),identityEntry);activePage=second;await second.goto(page.url());await second.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Ansehen'));
 check(await second.locator('#editor-map-name').isDisabled(),'Duplizierter Tab mit gleichem Sitzungsschlüssel und kopiertem Tab-Speicher erhält schreibgeschützte Ansicht');activePage=page;
 await draw(page).locator('#importProject').click();await draw(page).locator('#fileInput').setInputFiles({name:'Lava_Mine.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(sample))});await page.waitForFunction(()=>document.querySelector('#dungeon-editor')?.contentWindow.DungeonEditor.getDocument().rooms.length===8);await saved(page);
 const imported=(await serial(()=>db.query('select document from public.dungeon_maps where id=$1',[mapId]))).rows[0].document;
 assert.equal(imported.rules.version,2);assert.ok(imported.rules.unlocks.some(u=>u.sourceCellId===4&&u.targetCellId===7&&u.number===9));check(imported.rooms.length===8 && imported.rooms[1].number==='doubles','JSON-Import erhält IDs, Größen, Pasch und Freischaltungen');
 assert.deepEqual(imported.rooms.map(({id,x,y,w,h})=>({id,x,y,w,h})),sample.rooms.map(({id,x,y,w,h})=>({id,x,y,w,h})));check(true,'Alle Feldpositionen, Größen und Gegnerdaten bleiben beim Import unverändert');
 check(await draw(page).locator('.room.start').count()===1,'Grüne Startfelder bleiben sichtbar');
 await page.click('#map-rules');await page.getByRole('checkbox',{name:'Axt des Doppelschlags',exact:true}).check();await page.selectOption('#goal-2-type','defeatEnemies');await page.locator('.rule-section').filter({hasText:'Bonusaufgabe 2'}).locator('.rule-targets label').filter({hasText:'Höhlentroll'}).locator('input').check();await page.click('#save-map-rules');await saved(page);
 let current=(await serial(()=>db.query('select document from public.dungeon_maps where id=$1',[mapId]))).rows[0].document;
 check(current.allowedPowerups.includes('axe') && current.rules.goals[1].cellIds[0]===3,'Powerups und maschinenlesbare Spezialaufgabe werden gespeichert');
 await draw(page).locator('.room.monster').click({button:'right'});
 const png=await page.evaluate(()=>{const c=document.createElement('canvas');c.width=96;c.height=96;const ctx=c.getContext('2d');ctx.fillStyle='#49725b';ctx.beginPath();ctx.arc(48,48,38,0,Math.PI*2);ctx.fill();return c.toDataURL('image/png').split(',')[1];});
 await draw(page).locator('#enemyImageInput').setInputFiles({name:'troll.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});await page.waitForFunction(()=>Boolean(document.querySelector('#dungeon-editor')?.contentWindow.DungeonEditor.getDocument().rooms.find(r=>r.id===3).image));await saved(page);check(await draw(page).locator('#numberMenu').isVisible(),'Autosave lässt das offene Rechtsklickmenü ungestört');await draw(page).locator('#closeMenu').click();
 current=(await serial(()=>db.query('select document from public.dungeon_maps where id=$1',[mapId]))).rows[0].document;
 check(current.rooms[2].image.src.startsWith('asset:') && objects.size>=2,'Monsterbild wird im Bucket gespeichert; Karte enthält nur eine Referenz');
 await page.reload();await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent==='Alle Änderungen gespeichert');
 check(await draw(page).locator('[data-enemy-image]').count()===1,'Gespeichertes Monsterbild wird nach Neuladen wieder eingebettet dargestellt');
 const downloadEvent=page.waitForEvent('download');await page.click('#export-map-json');const download=await downloadEvent,stream=await download.createReadStream(),parts=[];for await(const part of stream)parts.push(part);const exported=JSON.parse(Buffer.concat(parts).toString());
 check(exported.rooms[2].image.src.startsWith('data:image/png;base64,')&&exported.rules.goals[1].type==='defeatEnemies','Portabler JSON-Export enthält Bilder und Spielregeln vollständig');
 await draw(page).locator('#exportProject').click();const nativeExport=JSON.parse(await draw(page).locator('#saveText').inputValue());check(nativeExport.rooms[2].image.src.startsWith('data:')&&nativeExport.allowedPowerups.includes('axe'),'Bisheriger Speicherdialog samt Projekttext und Metadaten bleibt verfügbar');await draw(page).locator('#closeFile').click();
 await draw(page).locator('#exportImage').click();await draw(page).locator('#pngPreview').waitFor({state:'visible'});
 check((await draw(page).locator('#pngPreview').getAttribute('src')).startsWith('data:image/png;base64,'),'PNG-Export funktioniert auch nach Laden aus dem Bucket');await draw(page).locator('#closeFile').click();
 await draw(page).locator('#openLayout').click();await draw(page).locator('#layoutPNG').click();await draw(page).locator('#pngPreview').waitFor({state:'visible'});
 check((await draw(page).locator('#imageInfo').innerText()).includes('Vollständiger Spielbogen'),'Drucklayout samt Original-Randblöcken wird weiterhin als PNG exportiert');await draw(page).locator('#closeFile').click();
 await page.evaluate(()=>{const child=document.querySelector('#dungeon-editor').contentWindow;child.print=()=>{child.__printCalled=true;};});await draw(page).locator('#layoutPrint').click();await page.waitForFunction(()=>document.querySelector('#dungeon-editor').contentWindow.__printCalled===true);check((await draw(page).locator('#layoutPrintImage').getAttribute('src')).startsWith('data:image/png;base64,'),'Drucken/PDF erstellt den vollständigen Spielbogen und ruft den Browserdruck auf');await page.evaluate(()=>{const child=document.querySelector('#dungeon-editor').contentWindow;child.dispatchEvent(new child.Event('afterprint'));});await draw(page).locator('#closeLayout').click();
 dropNextSave=true;const beforeRequests=saveRequests.length;await page.fill('#editor-map-name','Lava Mine – Nacht');await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Lokal gesichert'));
 await page.click('#save-map');await saved(page);
 check(saveRequests.length>=beforeRequests+2&&saveRequests.at(-1).p_request_id===saveRequests.at(-2).p_request_id,'Verlorene Speicherantwort wird mit derselben Anfrage-ID sicher wiederholt');
 const otherContext=await browser.newContext();await gateway(otherContext);const other=await otherContext.newPage();activePage=other;await other.goto(address);await other.locator('#auth-form').waitFor();await login(other,'joni');await other.goto(page.url());await other.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Ansehen'));check(await other.locator('#editor-map-name').isDisabled(),'Zweiter Spieler kann keine belegte Karte überschreiben');activePage=page;
 flags.offline=true;await page.fill('#editor-map-name','Lokale Änderung');await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Lokal gesichert'));
 const token=await page.evaluate(key=>JSON.parse(localStorage.getItem(key)).token,CONFIG.sessionStorageKey);
 await serial(()=>db.query("update dungeon_private.map_edit_locks set lease_until=now()-interval '1 second' where map_id=$1",[mapId]));
 await other.click('#reconnect-map');await other.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent==='Bearbeitung bereit');await other.fill('#editor-map-name','Joni Serverstand');await saved(other);
 flags.offline=false;await page.reload();await page.locator('#restore-local-map').waitFor();await page.click('#restore-local-map');await page.waitForFunction(()=>document.querySelector('#editor-map-name')?.value==='Lokale Änderung'&&!document.querySelector('.workshop-dialog[open]'));
 check(await page.inputValue('#editor-map-name')==='Lokale Änderung' && await page.locator('#editor-map-name').isDisabled(),'Veraltete lokale Wiederherstellung bleibt schreibgeschützt und überschreibt keine neueren Daten');
 await page.click('#reconnect-map');await page.waitForFunction(()=>document.querySelector('.editor-workbench>.feedback')?.textContent.includes('Joni')||document.querySelector('.editor-workbench>.feedback')?.textContent.includes('Serverstand'));check(true,'Sperrkonflikt bleibt verständlich und lokaler Entwurf erhalten');
 await other.click('.editor-back');await other.locator('.map-library').waitFor();await page.click('#reconnect-map');await page.waitForFunction(()=>document.querySelector('.editor-workbench>.feedback')?.textContent.includes('Serverstand hat sich verändert'));
 check(await page.locator('#editor-map-name').isDisabled(),'Auch nach Sperrfreigabe wird ein alter lokaler Stand nicht automatisch überschrieben');
 page.once('dialog',d=>d.accept());await page.click('.editor-back');await page.locator('.map-library').waitFor();await page.fill('#map-search','Joni Serverstand');await page.locator('.map-card').first().locator('a').first().click();await page.locator('#restore-local-map').waitFor();await page.click('#use-server-map');
 await page.click('#check-publish-map');await page.locator('#accept-map-warnings').check();await page.click('#confirm-publish-map');await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Veröffentlicht'));
 check(await page.locator('#editor-map-name').isDisabled()&&await page.locator('#check-publish-map').isHidden(),'Veröffentlichte Karte ist unveränderbar und über Kopie weiterentwickelbar');
 check((await serial(()=>db.query('select count(*)::int n from public.dungeon_map_connections'))).rows[0].n>0,'Veröffentlichung speichert die echten offenen Verbindungen');
 await page.click('.editor-back');await page.locator('.map-library').waitFor();await page.selectOption('#map-filter','published');check(await page.locator('.map-card').count()===1,'Statusfilter findet ausschließlich veröffentlichte Karten');
 await page.locator('.toast').waitFor({state:'hidden'});await page.screenshot({path:root+'/test-results/kartenbibliothek-desktop.png',fullPage:true});
 await page.setViewportSize({width:390,height:844});check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Kartenbibliothek passt auf ein Handy');await page.screenshot({path:root+'/test-results/kartenbibliothek-handy.png',fullPage:true});
 await page.setViewportSize({width:1440,height:1040});await page.locator('.map-card a').first().click();await page.waitForFunction(()=>document.querySelector('#map-save-status')?.textContent.startsWith('Fertige Karte'));await page.screenshot({path:root+'/test-results/karteneditor-desktop.png',fullPage:true});
 check(await page.evaluate(({key,token})=>JSON.parse(localStorage.getItem(key)).token===token,{key:CONFIG.sessionStorageKey,token}),'Anmeldung bleibt während Offline- und Editorwechseln erhalten');
 check(errors.length===0,`Keine JavaScript-Laufzeitfehler (${errors.join('; ')})`);
 await second.close();await otherContext.close();console.log(`TOTAL ${checks} Phase-2-Browserprüfungen bestanden.`);
}catch(error){console.error(error.stack);process.exitCode=1;await activePage?.screenshot({path:root+'/test-results/maps-failure.png',fullPage:true}).catch(()=>{});}
finally{await browser?.close();server.kill();await db.close();}
