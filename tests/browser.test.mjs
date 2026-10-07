// Echte Web-Oberfläche + lokales PostgreSQL. Supabase-Gateway und Storage
// werden lokal nachgebildet; das entfernte Benutzerprojekt wird NICHT verändert.
import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {createDatabase,callRpc,TEST_ACCESS_CODE} from './helpers/database.mjs';
import {createHandler} from '../supabase/functions/avatar-upload/index.ts';
import {CONFIG} from '../web/js/config.js';

const require=createRequire(import.meta.url),root=fileURLToPath(new URL('../',import.meta.url));
const port=Number(process.env.TEST_PORT || 5189),address=`http://localhost:${port}`;
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:String(port)},stdio:'ignore'});
const db=await createDatabase(),objects=new Map(),errors=[];
let checks=0,browser,activePage,queue=Promise.resolve();
let offline=false,missingSchema=true;
const serial=fn=>{const promise=queue.then(fn);queue=promise.catch(()=>{});return promise;};
function check(value,label) {assert.ok(value,label);checks++;console.log(`PASS ${label}`);}
const uploadHandler=createHandler({
  env:name=>({SUPABASE_URL:CONFIG.supabaseUrl,SUPABASE_SECRET_KEYS:JSON.stringify({default:'sb_secret_local_test_only'})})[name],
  fetcher:async(url,options)=>{
    const parsed=new URL(url);
    if (parsed.pathname.startsWith('/rest/v1/rpc/')) {
      try {return Response.json(await serial(()=>callRpc(db,parsed.pathname.split('/').at(-1),JSON.parse(options.body),'service_role')));}
      catch (error) {return Response.json({message:error.message},{status:400});}
    }
    if (options.method==='DELETE') {
      for (const path of JSON.parse(options.body).prefixes) objects.delete(path);
      return Response.json({ok:true});
    }
    objects.set(parsed.pathname.replace('/storage/v1/object/avatars/',''),options.body);
    return Response.json({Key:parsed.pathname});
  },
});
async function routeApi(context) {
  context.on('page',page=>page.on('pageerror',error=>errors.push(error.message)));
  await context.route(`${CONFIG.supabaseUrl}/**`,async route=>{
    const request=route.request(),path=new URL(request.url()).pathname;
    if (offline) {await route.abort('failed');return;}
    const headers={'access-control-allow-origin':'*','access-control-allow-methods':'POST,GET,OPTIONS','access-control-allow-headers':'apikey,content-type,x-session-token','content-type':'application/json'};
    if (request.method()==='OPTIONS') {await route.fulfill({status:204,headers});return;}
    if (path.startsWith('/storage/v1/object/public/avatars/')) {
      const bytes=objects.get(path.replace('/storage/v1/object/public/avatars/',''));
      await route.fulfill({status:bytes ? 200 : 404,headers:{'content-type':'image/webp'},body:bytes ? Buffer.from(bytes) : Buffer.from('')});return;
    }
    if (path==='/functions/v1/avatar-upload') {
      const response=await uploadHandler(new Request(request.url(),{method:request.method(),headers:request.headers(),body:request.postDataBuffer()}));
      await route.fulfill({status:response.status,headers,body:await response.text()});return;
    }
    if (missingSchema) {await route.fulfill({status:404,headers,body:JSON.stringify({code:'PGRST202'})});return;}
    try {
      const result=await serial(()=>callRpc(db,path.split('/').at(-1),request.postDataJSON()));
      await route.fulfill({status:200,headers,body:JSON.stringify(result)});
    } catch (error) {await route.fulfill({status:400,headers,body:JSON.stringify({message:error.message,code:error.code})});}
  });
}
async function login(page) {
  await page.fill('#username','flo');await page.fill('#password','testing42');await page.click('#auth-submit');await page.locator('.home-view').waitFor();
}
try {
  await mkdir(root+'/test-results',{recursive:true});
  for (let i=0;i<100;i++) {
    try {if ((await fetch(address)).ok) break;} catch { /* Lokaler Server startet gerade. */ }
    await new Promise(resolve=>setTimeout(resolve,30));
  }
  let args=[];
  if (process.env.WUERFELDUNGEON_CHROMIUM_MODULE) {
    // Serverless-Vorgaben müssen für getrennte Geräte-Contexts angepasst werden.
    // Außerdem CORS wirklich prüfen, nicht mit deaktivierter Web-Sicherheit.
    args=require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(value=>!['--single-process','--disable-web-security'].includes(value));
  }
  browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH || undefined,args});
  const context=await browser.newContext({viewport:{width:1440,height:1000}});await routeApi(context);
  const page=await context.newPage();activePage=page;
  await page.goto(address);await page.locator('#retry-connection').waitFor();
  const installationFeedback=await page.locator('.feedback').innerText();
  assert.ok(installationFeedback.includes('SETUP.md'),installationFeedback);
  check(true,'Fehlende Datenbankinstallation ist verständlich sichtbar');
  missingSchema=false;await page.click('#retry-connection');await page.locator('#auth-form').waitFor();
  check(!/(^|\n)null(\n|$)/.test(await page.locator('body').innerText()),'Anmeldeseite enthält keine versehentlichen Platzhalter');
  await page.screenshot({path:root+'/test-results/anmeldung-desktop.png',fullPage:true});
  await page.click('#register-tab');
  await page.fill('#username','Flo');await page.fill('#display-name','Flo');await page.fill('#password','testing42');await page.fill('#password-confirm','testing42');await page.fill('#access-code','wrong');
  await page.click('#auth-submit');await page.locator('.feedback:not([hidden])').waitFor();
  check((await page.locator('.feedback').innerText()).includes('Registrierungscode'),'Falscher Registrierungscode wird abgewiesen');
  await page.fill('#access-code',TEST_ACCESS_CODE);await page.click('#auth-submit');await page.locator('.home-view').waitFor();
  check((await page.locator('.nav-profile').innerText()).includes('Flo'),'Registrierung führt zur persönlichen Startseite');
  check((await db.query('select count(*)::int as count from public.dungeon_players')).rows[0].count===1,'Genau ein Spieler angelegt');
  await page.click('.menu-card[href="#/profile"]');await page.locator('#profile-form').waitFor();
  await page.fill('#profile-display-name','<img src=x onerror=alert(1)>');await page.click('#save-profile');await page.locator('.feedback.success').waitFor();
  check(await page.locator('img[src="x"]').count()===0,'Anzeigename wird als Text statt HTML dargestellt');
  await page.fill('#profile-display-name','Flo');await page.click('#save-profile');await page.waitForFunction(()=>document.querySelector('#header-nav').textContent.includes('Flo'));
  const png=await page.evaluate(()=>{
    const c=document.createElement('canvas');c.width=128;c.height=96;const ctx=c.getContext('2d');ctx.fillStyle='#a2c896';ctx.fillRect(0,0,128,96);ctx.fillStyle='#2b5343';ctx.beginPath();ctx.arc(64,48,28,0,Math.PI*2);ctx.fill();return c.toDataURL('image/png').split(',')[1];
  });
  await page.setInputFiles('#avatar-file',{name:'avatar.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});
  await page.waitForFunction(()=>document.querySelector('#profile-form .feedback')?.textContent.includes('Profilbild wurde gespeichert'));
  check(await page.locator('.profile-portrait img').count()===1 && objects.size===1,'Echter PNG-Upload wird vorbereitet, gespeichert und dargestellt');
  await page.click('.nav-home');await page.locator('.home-view').waitFor();await page.click('.menu-card[href="#/settings"]');
  await page.check('#mark-waves');await page.click('#audio-preferences summary');await page.uncheck('#sound');await page.check('#music');await page.check('#reduceMotion');await page.click('#save-settings');await page.locator('.feedback.success').waitFor();
  check(await page.locator('body').evaluate(node=>node.classList.contains('reduce-motion')),'Bewegungen lassen sich unmittelbar abschalten');
  await page.reload();await page.locator('#settings-form').waitFor();
  check(await page.isChecked('#mark-waves') && await page.isChecked('#music') && !(await page.isChecked('#sound')),'Sitzung und Einstellungen überstehen das Neuladen');
  const savedToken=await page.evaluate(key=>JSON.parse(localStorage.getItem(key)).token,CONFIG.sessionStorageKey);
  check(!(await page.locator('body').innerText()).includes(savedToken),'Sitzungsschlüssel erscheint nirgends in der Oberfläche');
  offline=true;await page.reload();await page.locator('#retry-connection').waitFor();
  check(await page.evaluate(key=>Boolean(localStorage.getItem(key)),CONFIG.sessionStorageKey),'Verbindungsfehler löschen die Sitzung nicht');
  offline=false;await page.click('#retry-connection');await page.locator('#settings-form').waitFor();
  check(await page.isChecked('#mark-waves'),'Verbindung kann mit erhaltenem Profil wieder aufgenommen werden');
  await page.click('.nav-profile');await page.locator('#profile-form').waitFor();
  await serial(()=>db.exec("update public.dungeon_players set display_name='Flo auf Laptop',revision=revision+1 where username='flo'"));
  await page.fill('#profile-display-name','Veraltete Änderung');await page.click('#save-profile');
  await page.waitForFunction(()=>document.querySelector('#profile-form .feedback')?.textContent.includes('anderen Gerät'));
  check(true,'Gleichzeitige Profiländerung wird nicht überschrieben');
  await page.click('#reload-profile');await page.waitForFunction(()=>document.querySelector('#profile-display-name').value==='Flo auf Laptop');
  await page.fill('#profile-display-name','Flo');await page.click('#save-profile');await page.waitForFunction(()=>document.querySelector('#profile-form .feedback')?.textContent==='Dein Profil wurde gespeichert.');
  const secondContext=await browser.newContext();await routeApi(secondContext);const second=await secondContext.newPage();activePage=second;
  await second.goto(address);await second.locator('#auth-form').waitFor();await login(second);activePage=page;
  await page.click('.nav-home');await page.locator('.home-view').waitFor();await page.click('.menu-card[href="#/profile"]');await page.waitForFunction(()=>document.querySelectorAll('.session-row').length===2);
  check(true,'Zwei Geräte können gleichzeitig angemeldet sein');
  page.once('dialog',dialog=>dialog.accept());await page.click('#session-list button');await page.waitForFunction(()=>document.querySelectorAll('.session-row').length===1);
  await second.reload();await second.locator('#auth-form').waitFor();
  check((await second.locator('.feedback').innerText()).includes('abgelaufen'),'Eine fremde Gerätesitzung lässt sich widerrufen');
  await secondContext.close();
  await page.click('.nav-home');await page.locator('.home-view').waitFor();
  await page.locator('.toast').waitFor({state:'hidden'});
  await page.screenshot({path:root+'/test-results/lager-desktop.png',fullPage:true});
  await page.setViewportSize({width:390,height:844});await page.screenshot({path:root+'/test-results/lager-handy.png',fullPage:true});
  check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Startseite passt ohne horizontales Scrollen aufs Handy');
  await page.click('.menu-card[href="#/profile"]');await page.locator('#profile-form').waitFor();
  check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Profil ist auf dem Handy benutzbar');
  await page.setViewportSize({width:360,height:780});
  check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Auch bei 360 Pixeln kein seitliches Überlaufen');
  await page.click('#remove-avatar');await page.waitForFunction(()=>document.querySelector('#profile-form .feedback')?.textContent==='Dein Profilbild wurde entfernt.');
  check(objects.size===0 && await page.locator('.profile-portrait img').count()===0,'Profilbild entfernen räumt den Storage auf');
  const tab=await context.newPage();await tab.goto(address);await tab.locator('.home-view').waitFor();
  await page.fill('#profile-display-name','Nicht gespeicherter Name');
  await page.evaluate(()=>{window.__metadataEventSeen=false;window.addEventListener('storage',()=>{window.__metadataEventSeen=true;},{once:true});});
  await tab.evaluate(key=>{const session=JSON.parse(localStorage.getItem(key));session.expiresAt='2099-01-01T00:00:00Z';localStorage.setItem(key,JSON.stringify(session));},CONFIG.sessionStorageKey);
  await page.waitForFunction(()=>window.__metadataEventSeen);
  check(await page.inputValue('#profile-display-name')==='Nicht gespeicherter Name','Sitzungsverlängerung in anderem Tab verwirft keine ungespeicherten Änderungen');
  await page.fill('#profile-display-name','Flo');
  page.once('dialog',dialog=>dialog.accept());await page.click('#logout-button');await page.locator('#auth-form').waitFor();await tab.locator('#auth-form').waitFor();
  check((await tab.locator('.feedback').innerText()).includes('anderen Tab'),'Abmelden wird zwischen Browser-Tabs synchronisiert');
  check(!await page.evaluate(key=>localStorage.getItem(key),CONFIG.sessionStorageKey),'Lokaler Sitzungsschlüssel wird beim Logout entfernt');
  check(errors.length===0,`Keine JavaScript-Laufzeitfehler (${errors.length})`);
  console.log(`TOTAL ${checks} Browserprüfungen bestanden.`);
} catch (error) {
  console.error(error.message);process.exitCode=1;
  await activePage?.screenshot({path:root+'/test-results/failure.png',fullPage:true}).catch(()=>{});
}
finally {await browser?.close();server.kill();await db.close();}
