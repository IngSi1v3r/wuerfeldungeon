import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {emptyDocument,connections} from '../web/js/maps/model.js';
import {upgradeDocument,compileDocument,goalDefault} from '../web/js/maps/features.js';
const root=fileURLToPath(new URL('../',import.meta.url)),url='http://localhost:5212',out=root+'test-artifacts/0_10_2';
const server=spawn(process.execPath,['scripts/serve.mjs'],{cwd:root,env:{...process.env,PORT:'5212'},stdio:'ignore'});
let browser;const errors=[];let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;console.log('PASS',label);};
const field=(id,type,x,y,number,extra={})=>({id,type,x,y,w:4,h:4,number,start:false,dimmed:false,...extra});
const d=upgradeDocument(emptyDocument());
d.rooms=[field(1,'normal',0,0,5,{start:true}),field(2,'rune',4,0,4),field(3,'doubleSum',8,0,6),field(4,'crazy',12,0,null,{requirements:[3,4,5,6,8,9,10,11,'doubles']}),
 field(5,'boss',4,4,null,{w:16,h:8,name:'Testboss',hits:12,attacks:[{number:7,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}),
 field(6,'rune',0,12,8),field(7,'rune',4,12,10),field(8,'crazy',0,4,null,{requirements:[3,7,9]}),field(9,'normal',0,8,9)];
d.printLayout.name='Pasch, Runen und Würfelfelder';d.rules.goals=[{...goalDefault(),type:'allType',fieldType:'rune',requiredCount:2},goalDefault()];
const doc=compileDocument(d);doc.nextId=10;
try{
 for(let i=0;i<100;i++){try{if((await fetch(url+'/editor/')).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
 await mkdir(out,{recursive:true});
 browser=await chromium.launch({headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined});
 const context=await browser.newContext({viewport:{width:1280,height:900}});await context.route('https://uqbpjsgffxoibvibfvgg.supabase.co/**',r=>r.abort());
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(12000);
 await page.goto(url+'/editor/');await page.waitForFunction(()=>!!window.DungeonEditor);
 await page.evaluate(async doc=>{window.DungeonEditor.setReadOnly(false);await window.DungeonEditor.load(doc);},doc);
 check(await page.locator('.room.rune [data-rune-icon]').count()>0,'Runen haben ein eigenständiges Vektorsymbol');
 check(await page.locator('.room.crazy [data-crazy-icon]').count()>0,'Zufallsfelder haben einen großen Würfel mit Wechselpfeilen');
 await page.locator('.room[data-id="3"] .room-body').click({button:'right'});
 check(await page.locator('#numbers button[data-number="5"]').isHidden()&&await page.locator('#numbers button[data-number="doubles"]').isHidden(),'Paschmenü bietet nur gerade Summen');
 await page.locator('#numbers button[data-number="8"]').click();check((await page.evaluate(()=>window.DungeonEditor.getDocument())).rooms[2].number===8,'Paschsumme im Kontextmenü geändert');
 await page.locator('.room[data-id="2"] .room-body').click({button:'right'});await page.locator('#fieldType').selectOption('normal');await page.locator('#dimmedField').check();await page.locator('#closeMenu').click();
 const changed=await page.evaluate(()=>window.DungeonEditor.getDocument()),converted=changed.rooms.find(r=>r.id===2);
 check(converted.type==='normal'&&converted.dimmed&&converted.x===4&&converted.y===0,'Rune kann unter gleicher ID und Position in ein graues Wegfeld umgewandelt werden');
 check(changed.rules.unlocks.some(u=>u.sourceCellId===2&&u.targetCellId===5&&u.number===4),'Graues Feld schaltet angrenzenden Boss frei');
 await page.locator('#undo').click();await page.locator('#undo').click();check((await page.evaluate(()=>window.DungeonEditor.getDocument())).rooms[1].type==='rune','Umwandlung und Graumarkierung können rückgängig gemacht werden');
 await page.evaluate(async()=>{const p=await window.DungeonEditor.exportPreview();window.__preview=p.src;});
 await writeFile(out+'/Spielfeld_Vorschau.png',Buffer.from((await page.evaluate(()=>window.__preview)).split(',')[1],'base64'));
 await page.locator('#exportImage').click();await page.locator('#pngPreview').waitFor();const png=await page.locator('#pngPreview').getAttribute('src');
 check(png?.startsWith('data:image/png;base64,'),'Spielfeld als PNG exportiert');await writeFile(out+'/Spielfeld.png',Buffer.from(png.split(',')[1],'base64'));await page.locator('#closeFile').click();
 await page.locator('#openLayout').click();await page.locator('#layoutPNG').click();await page.waitForFunction(()=>document.querySelector('#fileDialog')?.open);
 const print=await page.locator('#pngPreview').getAttribute('src');check(print?.startsWith('data:image/png;base64,'),'Drucklayout mit Teilziel und neuen Symbolen exportiert');await writeFile(out+'/Drucklayout.png',Buffer.from(print.split(',')[1],'base64'));await page.locator('#closeFile').click();await page.locator('#closeLayout').click();
 await page.screenshot({path:out+'/Editor.png'});

 // Regeln im selben Browser, mit dem tatsächlichen App-Stil.
 const links=(await readFile(root+'web/index.html','utf8')).match(/<link[^>]+rel="stylesheet"[^>]*>/g)||[];
 await page.route(url+'/rules-test.html',r=>r.fulfill({contentType:'text/html',body:`<!doctype html><html lang="de"><head>${links.join('').replaceAll('href="./','href="/')}</head><body></body></html>`}));
 await page.goto(url+'/rules-test.html');
 await page.evaluate(async doc=>{const {rulesDialog}=await import('/js/maps/rules-view.js');window.__doc=doc;rulesDialog({document:doc,readOnly:false,onSave:(rules,powers)=>{window.__saved={rules,powers};}});},doc);
 check(!await page.locator('#goal-1-all-required').isChecked(),'Gespeicherte Teilzielzahl wird angezeigt');
 await page.locator('#goal-1-required-count').fill('1');await page.locator('#save-map-rules').click();
 check((await page.evaluate(()=>window.__saved)).rules.goals[0].requiredCount===1,'Benötigte Anzahl wird gespeichert');
 await page.evaluate(async()=>{const {rulesDialog}=await import('/js/maps/rules-view.js');rulesDialog({document:window.__doc,readOnly:false,onSave:rules=>{window.__saved={rules};}});});
 await page.locator('#goal-1-required-count').fill('4');await page.locator('#save-map-rules').click();
 check(await page.locator('.rules-dialog').count()===1,'Mehr Ziele als verfügbar werden im Menü abgelehnt');
 await page.locator('#goal-1-all-required').check();await page.locator('#goal-2-type').selectOption('defeatEnemies');
 check(await page.locator('.rules-dialog p:not([hidden])').filter({hasText:'Die Erstbelohnung gilt für die gesamte Kombination.'}).isVisible(),'Gegnerkombination klar von einzelnen Erstbesiegern erklärt');
 await page.screenshot({path:out+'/Regeln.png'});
 await page.locator('.rules-dialog button').filter({hasText:'Abbrechen'}).click();

 // Echte Spielgrafik: Würfelzeichen bleibt beim Zahlenwechsel stehen, auch Pasch-SVGs haben ihre Transformation.
 await page.route(url+'/board-test.html',r=>r.fulfill({contentType:'text/html',body:`<!doctype html><html><head>${links.join('').replaceAll('href="./','href="/')}</head><body></body></html>`}));
 await page.goto(url+'/board-test.html');
 await page.evaluate(async doc=>{const {boardPreview}=await import('/js/games/board-preview.js');const graph=(await import('/js/maps/model.js')).connections(doc);
  window.__board=boardPreview({}, {document:doc,rules:doc.rules,graph});document.body.append(window.__board.element);window.__board.update({state:{reached:[]},interactive:false,roundRequirements:{4:'doubles',8:7}});},doc);
 await page.waitForFunction(()=>!!document.querySelector('.room[data-id="4"] [data-crazy-value][data-number="doubles"]'));
 check(await page.locator('.room[data-id="4"] [data-crazy-icon]').count()>0,'Wechselwürfel bleibt in der Spielansicht sichtbar');
 check((await page.locator('.room[data-id="4"] [data-crazy-value] rect').first().getAttribute('transform'))?.startsWith('matrix('),'Paschdarstellung im Zufallsfeld bleibt korrekt positioniert');
 await page.screenshot({path:out+'/Spielansicht.png'});
 await page.evaluate(()=>window.__board.cleanup());
 check(errors.length===0,`Keine Browserfehler: ${errors.join(', ')}`);
 console.log(`${checks} Browserprüfungen bestanden.`);
}finally{await browser?.close();server.kill();}
