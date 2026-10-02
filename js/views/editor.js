import {upgradeDocument,compileDocument} from '../maps/features.js';
import {h,icon,feedback,setFeedback} from '../dom.js';
import {CONFIG} from '../config.js';
import {AppError} from '../api.js';
import {MapAssets,defaultRules,downloadJson} from '../maps/model.js';
import {MapRecovery} from '../maps/recovery.js';
import {rulesDialog} from '../maps/rules-view.js';
import {mapNameDialog,pendingImports} from './maps.js';
import {editorIdentity} from '../maps/editor-identity.js';

export function editorView({api,profile,status,toast,mapId}) {
  const recovery=new MapRecovery(profile.id,mapId);let editorId,identity,assets;
  let map=null,editor=null,document=null,closed=false,acquired=false,dirty=false,generation=0,saveTimer,backupTimer,heartbeatTimer,leaseUntil=0,savePromise=null,pendingSave=null,reviewing=false,workingRevision=0,localBackupAvailable=false;
  const message=feedback(),saveStatus=h('span',{id:'map-save-status',class:'map-save-status',role:'status'},'Karte wird geladen …'),state=h('span',{class:'map-state draft'});
  const name=h('input',{id:'editor-map-name',class:'editor-map-name',maxlength:80,'aria-label':'Kartenname',disabled:true,oninput:()=>changed()}),savedDetails=h('span',{class:'editor-save-detail'});
  const saveButton=h('button',{id:'save-map',class:'button secondary',onclick:()=>flush().catch(()=>{})},icon('check'),'Jetzt speichern');
  const reconnect=h('button',{id:'reconnect-map',class:'button secondary',hidden:true,onclick:()=>map&&editor?reconnectEditor():location.reload()},'Neu verbinden');
  const publish=h('button',{id:'check-publish-map',class:'button primary',onclick:()=>checkPublish()},icon('shield'),'Prüfen & veröffentlichen');
  const rules=h('button',{id:'map-rules',class:'button secondary',disabled:true,onclick:()=>rulesDialog({document:currentDocument(),readOnly:!acquired,onSave:(next,powers)=>{editor.setRules(next,powers);}})},'Spielregeln');
  const exportButton=h('button',{id:'export-map-json',class:'button secondary',disabled:true,onclick:()=>exportLocal()},'JSON exportieren');
  const fullscreen=h('button',{id:'editor-fullscreen',class:'button secondary',onclick:async()=>{try{if(element.classList.contains('editor-maximized')){element.classList.remove('editor-maximized');fullscreen.textContent='Vollbild';return;}if(documentGlobal().fullscreenElement)await documentGlobal().exitFullscreen();else await element.requestFullscreen();}catch{element.classList.toggle('editor-maximized');}fullscreen.textContent=documentGlobal().fullscreenElement||element.classList.contains('editor-maximized')?'Vollbild verlassen':'Vollbild';}},'Vollbild');
  const copy=h('button',{id:'copy-current-map',class:'button secondary',disabled:true,onclick:()=>copyCurrent()},'Als Kopie');
  const frame=h('iframe',{id:'dungeon-editor',class:'dungeon-editor',src:'./editor/index.html',title:'Dungeon-Karteneditor'}),overlay=h('div',{class:'editor-loading',role:'status'},h('span',{class:'loader'}),'Die Zeichenfläche öffnet sich …');
  const element=h('section',{class:'editor-workbench'},h('div',{class:'editor-heading'},h('a',{class:'button secondary editor-back',href:'#/editor'},icon('back'),'Karten'),h('div',{class:'editor-title'},name,h('div',{class:'editor-title-meta'},state,savedDetails)),h('div',{class:'editor-save'},saveStatus,saveButton)),
    h('div',{class:'editor-actions'},h('div',{class:'button-row'},rules,exportButton,copy,fullscreen,reconnect),publish),message,h('div',{class:'editor-frame-wrap'},frame,overlay));
  const fullscreenChanged=()=>{fullscreen.textContent=documentGlobal().fullscreenElement===element||element.classList.contains('editor-maximized')?'Vollbild verlassen':'Vollbild';};documentGlobal().addEventListener('fullscreenchange',fullscreenChanged);
  documentGlobal().body.classList.add('workshop-open');
  const ready=new Promise((resolve,reject)=>{let attempts=0;const timer=setInterval(()=>{if(closed){clearInterval(timer);reject(Error('Editor geschlossen.'));return;}if(frame.contentWindow?.DungeonEditor && frame.contentDocument?.documentElement.dataset.ready==='true'){clearInterval(timer);resolve(frame.contentWindow.DungeonEditor);}else if(++attempts>250){clearInterval(timer);reject(Error('Die Zeichenfläche konnte nicht geladen werden. Bitte neu laden.'));}},40);});
  ready.catch(()=>{});
  function documentGlobal(){return globalThis.document;}
  function currentDocument(){return compileDocument(editor?.getDocument() || document);}
  function statusText(text,kind=''){saveStatus.textContent=text;saveStatus.className=`map-save-status ${kind}`;}
  function applyMode(){
    if(!map||!editor)return;
    editor.setReadOnly(!acquired||reviewing);name.disabled=!acquired||reviewing;saveButton.hidden=!acquired;saveButton.disabled=reviewing;
    publish.hidden=!acquired;publish.disabled=reviewing;rules.disabled=reviewing;exportButton.disabled=false;copy.disabled=false;
    reconnect.hidden=map.status!=='draft'||acquired;state.className=`map-state ${map.status}`;state.textContent=map.status==='draft'?'Entwurf':map.status==='published'?'Veröffentlicht':'Archiviert';
    savedDetails.textContent=`${map.fields} Felder · ${map.enemies} Gegner · von ${map.creator}`;
  }
  function backupNow(){if(!dirty||!document)return;return recovery.write({name:name.value,document:currentDocument(),baseRevision:workingRevision,savedAt:Date.now(),imported:false}).then(()=>{localBackupAvailable=true;}).catch(()=>{localBackupAvailable=false;if(!closed)setFeedback(message,'Die lokale Wiederherstellung ist in diesem Browser nicht verfügbar. Bitte bei Verbindungsproblemen zusätzlich JSON exportieren.','info');});}
  function changed(){
    if(closed||!editor||!acquired||reviewing)return;
    document=currentDocument();dirty=true;generation++;statusText('Änderungen noch nicht gespeichert','pending');
    clearTimeout(saveTimer);saveTimer=setTimeout(()=>flush().catch(()=>{}),1200);
    clearTimeout(backupTimer);backupTimer=setTimeout(backupNow,250);
  }
  async function flush(){
    clearTimeout(saveTimer);
    if(savePromise){await savePromise;if(dirty&&!closed)return flush();return;}
    if(!dirty||closed)return;
    if(!acquired)throw new AppError('MAP_LOCK_LOST');
    savePromise=(async()=>{
      statusText('Bilder und Karte werden gespeichert …','pending');await backupNow();
      if(!pendingSave){const doc=currentDocument();pendingSave={generation,name:name.value.trim(),document:doc,revision:workingRevision,requestId:crypto.randomUUID(),stored:null};}
      const attempt=pendingSave;
      if(!attempt.stored){if(attempt.generation===generation){const preview=await editor.exportPreview();if(attempt.generation===generation)attempt.document.previewImage=preview;}attempt.stored=await assets.store(attempt.document);}
      const result=await api.authRpc('save_map',{p_map_id:mapId,p_editor_id:editorId,p_expected_revision:attempt.revision,p_name:attempt.name,p_document:attempt.stored,p_request_id:attempt.requestId});
      map={...map,...result.map};workingRevision=map.revision;pendingSave=null;
      if(attempt.generation===generation){dirty=false;await recovery.clear().catch(()=>{});}else await backupNow();
      if(!closed){statusText(dirty?'Weitere Änderungen werden gespeichert …':`Gespeichert · ${new Date().toLocaleTimeString('de-AT',{hour:'2-digit',minute:'2-digit'})}`,dirty?'pending':'saved');setFeedback(message,'');applyMode();}
    })();
    try {await savePromise;}
    catch(error){
      if(!['NETWORK','TIMEOUT'].includes(error.code))pendingSave=null;
      if(!closed){statusText(localBackupAvailable?'Lokal gesichert · Speichern ausstehend':'Nicht gespeichert · JSON sichern','error');setFeedback(message,error.message);if(['MAP_LOCK_LOST','MAP_CHANGED','MAP_READ_ONLY','MAP_NOT_FOUND'].includes(error.code)){acquired=false;applyMode();}
        else if(['NETWORK','TIMEOUT'].includes(error.code))saveTimer=setTimeout(()=>{if(navigator.onLine)flush().catch(()=>{});},8000);}
      throw error;
    } finally{savePromise=null;}
    if(dirty&&!closed&&acquired)return flush();
  }
  async function heartbeat(){
    if(closed||!acquired)return;
    if(Date.now()>=leaseUntil){acquired=false;applyMode();statusText('Bearbeitung pausiert','error');setFeedback(message,'Die Bearbeitungssperre ist abgelaufen. Bitte neu verbinden; offene Änderungen bleiben lokal erhalten.');return;}
    try{const result=await api.authRpc('heartbeat_map_lock',{p_map_id:mapId,p_editor_id:editorId});if(!closed)leaseUntil=Date.parse(result.leaseUntil);}
    catch(error){if(closed)return;if(error.code==='MAP_LOCK_LOST'||error.code==='SESSION_INVALID'){acquired=false;applyMode();}setFeedback(message,error.message);}
  }
  async function installDocument(raw){
    const hydrated=await assets.hydrate(map.status==='draft'?upgradeDocument(raw):raw);await editor.load(hydrated);
    document=editor.getDocument();
  }
  function exportLocal(){if(!document)return;downloadJson(currentDocument(),name.value);toast('JSON mit eingebetteten Bildern exportiert.');}
  function copyCurrent(){mapNameDialog({title:dirty?'Lokalen Stand als neuen Entwurf sichern':'Karte als neuen Entwurf kopieren',value:`${name.value.slice(0,65)} – Kopie`,submitLabel:'Kopie erstellen',onSubmit:async newName=>{
    if(!dirty){const result=await api.authRpc('copy_map',{p_map_id:mapId,p_name:newName});if(!closed)location.hash=`#/editor?id=${result.map.id}`;return;}
    const raw=currentDocument(),result=await api.authRpc('create_map',{p_name:newName});pendingImports.set(result.map.id,raw);
    await new MapRecovery(profile.id,result.map.id).write({name:newName,document:raw,baseRevision:result.map.revision,imported:true,savedAt:Date.now()});
    // Erst nach dem gesicherten lokalen Transfer den alten Entwurf verlassen.
    dirty=false;await recovery.clear().catch(()=>{});if(!closed)location.hash=`#/editor?id=${result.map.id}`;
  }});}
  async function reconnectEditor(){
    reconnect.disabled=true;setFeedback(message,'');
    try{
      await savePromise?.catch(()=>{});
      const result=await api.authRpc('acquire_map_lock',{p_map_id:mapId,p_editor_id:editorId});if(closed)return;
      if(!result.acquired){map=result.map;setFeedback(message,map.lock?`${map.lock.holder} bearbeitet diese Karte gerade. Du kannst deinen Stand als Kopie oder JSON sichern.`:'Diese Karte ist bereits veröffentlicht. Änderungen können als Kopie gesichert werden.','info');acquired=false;applyMode();return;}
      leaseUntil=Date.parse(result.leaseUntil);acquired=true;
      if(dirty&&result.map.revision!==workingRevision){
        acquired=false;await api.authRpc('release_map_lock',{p_map_id:mapId,p_editor_id:editorId});applyMode();
        setFeedback(message,'Der Serverstand hat sich verändert. Dein lokaler Stand bleibt auf der Zeichenfläche. Bitte „Als Kopie“ oder „JSON exportieren“ wählen, um ihn zu behalten.');return;
      }
      map=result.map;
      if(!dirty){await installDocument(map.document);name.value=map.name;workingRevision=map.revision;}
      applyMode();if(dirty)await flush();else statusText('Bearbeitung bereit','saved');
    }catch(error){if(!closed)setFeedback(message,error.message);}finally{if(!closed)reconnect.disabled=false;}
  }
  async function checkPublish(){
    publish.disabled=true;
    try{
      await flush();if(closed)return;reviewing=true;applyMode();
      const result=await api.authRpc('check_map',{p_map_id:mapId});if(closed)return;
      const report=result.report,issues=report.errors,warnings=report.warnings,accepted=h('input',{id:'accept-map-warnings',type:'checkbox'}),feedbackNode=feedback();
      const confirmButton=h('button',{id:'confirm-publish-map',class:'button primary',disabled:issues.length>0||warnings.length>0,onclick:async()=>{
        confirmButton.disabled=true;
        try{const result=await api.authRpc('publish_map',{p_map_id:mapId,p_editor_id:editorId,p_expected_revision:map.revision,p_accept_warnings:warnings.length?accepted.checked:false});if(closed)return;map=result.map;acquired=false;dirty=false;pendingSave=null;await recovery.clear().catch(()=>{});applyMode();statusText('Veröffentlicht · unveränderbar','saved');dialog.close();toast('Karte veröffentlicht. Änderungen sind über eine Kopie möglich.');}
        catch(error){setFeedback(feedbackNode,error.message);confirmButton.disabled=false;}
      }},'Karte veröffentlichen');
      accepted.addEventListener('change',()=>confirmButton.disabled=!accepted.checked);
      const dialog=h('dialog',{class:'workshop-dialog publish-dialog','aria-label':'Karte prüfen'},h('p',{class:'eyebrow'},'Veröffentlichung'),h('h2',{},issues.length?'Noch nicht bereit.':'Deine Welt ist bereit.'),
        h('p',{class:'muted'},`${report.stats.fields ?? 0} Felder · ${report.stats.enemies ?? 0} Gegner · ${report.stats.connections ?? 0} offene Durchgänge`),
        issues.length?h('section',{},h('h3',{},'Bitte zuerst korrigieren'),h('ul',{class:'validation-errors'},...issues.map(i=>h('li',{},i.message)))):h('p',{class:'feedback success'},'Alle benötigten Zahlen, Gegnerdaten und Spielregeln sind definiert.'),
        warnings.length?h('section',{},h('h3',{},'Hinweise'),h('ul',{class:'validation-warnings'},...warnings.map(i=>h('li',{},i.message)))):null,
        !issues.length?h('p',{},'Die Veröffentlichung friert Karte, Bilder, Regeln und Durchgänge ein. Danach bleibt sie über eine Kopie weiterentwickelbar.'):null,
        !issues.length&&warnings.length?h('label',{class:'rule-check'},accepted,'Ich habe die Hinweise geprüft und möchte diese Version veröffentlichen.'):null,feedbackNode,
        h('div',{class:'button-row'},issues.length?null:confirmButton,h('button',{class:'button secondary',onclick:()=>dialog.close()},issues.length?'Weiter bearbeiten':'Zurück')));
      dialog.addEventListener('close',()=>{dialog.remove();reviewing=false;if(!closed)applyMode();},{once:true});documentGlobal().body.append(dialog);dialog.showModal();
    }catch(error){reviewing=false;if(!closed){setFeedback(message,error.message);applyMode();}}finally{if(!closed)publish.disabled=reviewing;}
  }
  function recoveryDialog(local){
    return new Promise(resolve=>{
      let answered=false;const finish=async use=>{if(answered)return;answered=true;if(use){await installDocument(local.document);name.value=local.name;workingRevision=local.baseRevision;dirty=true;generation++;await backupNow();statusText('Lokalen Stand wiederhergestellt','pending');if(conflict)setFeedback(message,'Dies ist dein lokaler Entwurf. Der neuere Serverstand bleibt erhalten. Bitte „Als Kopie“ oder „JSON exportieren“ wählen, um deine Änderungen zu sichern.','info');}else await recovery.clear().catch(()=>{});dialog.close();resolve();};
      const conflict=local.baseRevision!==map.revision;
      const dialog=h('dialog',{class:'workshop-dialog','aria-label':'Lokalen Entwurf wiederherstellen'},h('p',{class:'eyebrow'},'Wiederherstellung'),h('h2',{},'Ein lokaler Entwurf wartet.'),h('p',{},`Auf diesem Gerät gibt es ungespeicherte Änderungen vom ${new Date(local.savedAt).toLocaleString('de-AT')}.`),
        conflict?h('p',{class:'feedback info'},'Der Server hat einen neueren Stand. Der lokale Entwurf wird nur zum Ansehen und als Kopie geöffnet; er überschreibt keine fremden Änderungen.'):null,
        h('div',{class:'button-row'},h('button',{id:'restore-local-map',class:'button primary',onclick:async()=>{if(conflict){acquired=false;await api.authRpc('release_map_lock',{p_map_id:mapId,p_editor_id:editorId}).catch(()=>{});applyMode();}finish(true).catch(error=>{setFeedback(message,error.message);dialog.close();resolve();});}},'Lokalen Entwurf öffnen'),h('button',{id:'use-server-map',class:'button secondary',onclick:()=>finish(false)},'Serverstand verwenden')));
      dialog.addEventListener('cancel',event=>event.preventDefault());dialog.addEventListener('close',()=>{dialog.remove();if(!answered)resolve();},{once:true});documentGlobal().body.append(dialog);dialog.showModal();
    });
  }
  async function initialize(){
    try{
      if(status?.editorSchemaVersion!==CONFIG.editorSchemaVersion||status?.editorFeaturesVersion!==CONFIG.editorFeaturesVersion)throw new AppError('EDITOR_NOT_INSTALLED');
      identity=await editorIdentity(profile.id,mapId);editorId=identity.id;assets=new MapAssets(api,mapId,editorId);
      if(closed){identity.release();return;}
      const mapPromise=api.authRpc('acquire_map_lock',{p_map_id:mapId,p_editor_id:editorId}).then(result=>{if(closed&&result.acquired)api.releaseMapLock(mapId,editorId).catch(()=>{});return result;});
      const [initialResult,interfaceReady]=await Promise.all([mapPromise,ready]);
      let result=initialResult;
      // Ein Pagehide-Release der vorherigen Seite kann beim Reload noch unterwegs
      // sein. Kurz erneut prüfen, ohne eine fremde aktive Sperre zu übernehmen.
      for(let i=0;!closed&&!result.acquired&&result.map.status==='draft'&&i<3;i++){
        await new Promise(resolve=>setTimeout(resolve,250));result=await api.authRpc('acquire_map_lock',{p_map_id:mapId,p_editor_id:editorId});
      }
      if(closed){if(result.acquired)api.authRpc('release_map_lock',{p_map_id:mapId,p_editor_id:editorId}).catch(()=>{});return;}
      editor=interfaceReady;map=result.map;workingRevision=map.revision;acquired=result.acquired;leaseUntil=Date.parse(result.leaseUntil || 0);name.value=map.name;
      await installDocument(map.document);if(closed)return;
      editor.onChange(()=>changed());editor.onExport(currentDocument);editor.onSave(()=>flush().catch(()=>{}));editor.onImport(()=>{});
      applyMode();overlay.hidden=true;
      const local=await recovery.read().catch(()=>null),imported=pendingImports.get(mapId);pendingImports.delete(mapId);
      if(acquired&&(imported||local?.imported)){try{await installDocument(imported || local.document);changed();}catch(error){await recovery.clear().catch(()=>{});setFeedback(message,`Import fehlgeschlagen: ${error.message}. Die leere Karte bleibt bearbeitbar.`);}}
      else if(local)await recoveryDialog(local);
      if(!acquired)statusText(dirty?'Lokaler Entwurf · schreibgeschützt':map.status!=='draft'?'Fertige Karte · schreibgeschützt':`Ansehen · ${map.lock?.holder || 'anderer Spieler'} bearbeitet`,dirty?'pending':'saved');
      else if(!dirty){if(acquired&&map.document.format!=='dungeon-layout-v7')changed();else statusText('Alle Änderungen gespeichert','saved');}
      heartbeatTimer=setInterval(()=>heartbeat(),25000);
      if(dirty&&acquired)saveTimer=setTimeout(()=>flush().catch(()=>{}),1200);
    }catch(error){if(!closed){overlay.hidden=true;setFeedback(message,error.message);statusText('Karte konnte nicht geöffnet werden','error');reconnect.hidden=false;}}
  }
  const resume=()=>{if(!closed){if(acquired){heartbeat().then(()=>{if(dirty&&acquired)flush().catch(()=>{});});}else if(map?.status==='draft')reconnect.hidden=false;}};
  const visibility=()=>{if(!documentGlobal().hidden)resume();};window.addEventListener('online',resume);documentGlobal().addEventListener('visibilitychange',visibility);
  const pageHide=()=>{backupNow();if(editorId&&!identity?.persistent)api.releaseMapLock(mapId,editorId).catch(()=>{});};
  const pageShow=event=>{if(event.persisted){acquired=false;applyMode();reconnectEditor();}};
  window.addEventListener('pagehide',pageHide);window.addEventListener('pageshow',pageShow);
  initialize();
  return {element,hasUnsavedChanges:()=>dirty||Boolean(savePromise),prepareLeave:async()=>{if(dirty&&acquired)await flush().catch(()=>{});},cleanup:()=>{
    if(closed)return;if(documentGlobal().fullscreenElement===element)documentGlobal().exitFullscreen().catch(()=>{});backupNow();closed=true;clearTimeout(saveTimer);clearTimeout(backupTimer);clearInterval(heartbeatTimer);editor?.onChange(null);
    identity?.release();
    documentGlobal().removeEventListener('fullscreenchange',fullscreenChanged);window.removeEventListener('online',resume);documentGlobal().removeEventListener('visibilitychange',visibility);documentGlobal().body.classList.remove('workshop-open');
    window.removeEventListener('pagehide',pageHide);window.removeEventListener('pageshow',pageShow);
    for(const d of documentGlobal().querySelectorAll('.workshop-dialog'))d.close();
    if(editorId)Promise.resolve(savePromise).catch(()=>{}).then(()=>api.authRpc('release_map_lock',{p_map_id:mapId,p_editor_id:editorId})).catch(()=>{});
  }};
}
