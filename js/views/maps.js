import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {MapRecovery} from '../maps/recovery.js';

export const pendingImports=new Map();
export function mapNameDialog({title='Neue Karte',value='',submitLabel='Karte erstellen',onSubmit,importFile=false}) {
  const name=h('input',{id:'map-name-input',type:'text',maxlength:80,required:true,value,autocomplete:'off'}),message=feedback();
  const file=importFile?h('input',{id:'map-import-file',type:'file',accept:'.json,application/json',required:true}):null;
  const submit=h('button',{class:'button primary',type:'submit'},submitLabel);
  const dialog=h('dialog',{class:'workshop-dialog','aria-label':title},h('form',{onsubmit:async event=>{
    event.preventDefault();submit.disabled=true;setFeedback(message,'');
    try {let document;if(file){const selected=file.files?.[0];if(!selected)throw Error('Bitte eine JSON-Datei auswählen.');if(selected.size>45000000)throw Error('Die Projektdatei ist zu groß.');document=JSON.parse(await selected.text());if(!Array.isArray(document.rooms))throw Error('Diese Datei enthält keine Dungeon-Karte.');}
      await onSubmit(name.value.trim(),document);dialog.close();
    } catch(error){setFeedback(message,error.message);}finally{submit.disabled=false;}
  }},h('p',{class:'eyebrow'},'Kartenwerkstatt'),h('h2',{},title),h('label',{class:'map-form-label'},'Eindeutiger Kartenname',name),file?h('label',{class:'map-form-label'},'Vorhandenes Offline-Projekt',file):null,message,
    h('div',{class:'button-row'},submit,h('button',{type:'button',class:'button secondary',onclick:()=>dialog.close()},'Abbrechen'))));
  dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();name.focus();return dialog;
}

export function miniature(rooms=[]) {
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('class','map-miniature');svg.setAttribute('aria-hidden','true');
  if(!rooms.length){svg.setAttribute('viewBox','0 0 160 96');const p=document.createElementNS(svg.namespaceURI,'path');p.setAttribute('d','M40 24h24v24H40z M64 36h24v24H64z M88 48h32v32H88z');p.setAttribute('fill','none');p.setAttribute('stroke','#749386');p.setAttribute('stroke-width','2');svg.append(p);return svg;}
  const x=Math.min(...rooms.map(r=>r.x)),y=Math.min(...rooms.map(r=>r.y)),right=Math.max(...rooms.map(r=>r.x+r.w)),bottom=Math.max(...rooms.map(r=>r.y+r.h));
  svg.setAttribute('viewBox',`${x-3} ${y-3} ${right-x+6} ${bottom-y+6}`);
  for(const r of rooms){const rect=document.createElementNS(svg.namespaceURI,'rect');for(const [key,val] of Object.entries({x:r.x,y:r.y,width:r.w,height:r.h,fill:r.start?'#9cbc78':({diamond:'#8bbed6',chest:'#d1b366',special:'#b29bcd',monster:'#ede3c7',miniboss:'#ede3c7',boss:'#cda563'})[r.type]||'#e5ece0',stroke:'#3c5449','stroke-width':.2,rx:.1}))rect.setAttribute(key,val);svg.append(rect);}return svg;
}
export function mapsView({api,profile,status,toast}) {
  let maps=[],closed=false;
  const message=feedback(),grid=h('div',{class:'map-grid',id:'map-grid'}),count=h('span',{class:'map-result-count'});
  const search=h('input',{id:'map-search',type:'search',placeholder:'Karte oder Ersteller suchen …','aria-label':'Karten durchsuchen',oninput:render});
  const filter=h('select',{id:'map-filter','aria-label':'Kartenstatus',onchange:render},h('option',{value:'active'},'Alle aktiven Karten'),h('option',{value:'draft'},'Entwürfe'),h('option',{value:'published'},'Veröffentlicht'),h('option',{value:'archived'},'Archiviert'));
  const element=h('section',{class:'map-library'},pageHeading('Kartenwerkstatt','Welten, die wir gemeinsam bauen.','Entwürfe bearbeiten, fertige Karten entdecken und neue Abenteuer zeichnen.'),
    h('div',{class:'library-toolbar'},h('div',{class:'button-row'},h('button',{id:'new-map',class:'button primary',onclick:()=>create(false)},icon('map'),'Neue Karte'),
      h('button',{id:'import-map',class:'button secondary',onclick:()=>create(true)},icon('upload'),'JSON importieren')),
      h('div',{class:'library-search'},search,filter,h('button',{class:'button secondary',title:'Kartenliste aktualisieren',onclick:load},'↻'))),message,
    h('div',{class:'library-meta'},h('span',{},'Eine gemeinsame Bibliothek für euren Abenteuertrupp.'),count),grid);
  function create(importFile) {
    mapNameDialog({title:importFile?'Offline-Karte importieren':'Eine neue Welt beginnen',importFile,onSubmit:async(name,document)=>{
      const result=await api.authRpc('create_map',{p_name:name});
      if(document){pendingImports.set(result.map.id,document);await new MapRecovery(profile.id,result.map.id).write({name,document,baseRevision:result.map.revision,imported:true,savedAt:Date.now()}).catch(()=>{});}
      if(!closed)location.hash=`#/editor?id=${result.map.id}`;
    }});
  }
  function render() {
    const query=search.value.trim().toLocaleLowerCase('de'),selected=maps.filter(m=>(filter.value==='active'?m.status!=='archived':m.status===filter.value)&&`${m.name} ${m.creator}`.toLocaleLowerCase('de').includes(query));
    count.textContent=`${selected.length} ${selected.length===1?'Karte':'Karten'}`;
    grid.replaceChildren(...selected.map(m=>{
      const published=m.status==='published',archived=m.status==='archived',badge=published?'Veröffentlicht':archived?'Archiviert':'Entwurf';
      return h('article',{class:'map-card','data-map-id':m.id},h('a',{class:'map-card-preview',href:`#/editor?id=${m.id}`},miniature(m.preview),h('span',{class:`map-state ${m.status}`},published?icon('lock'):icon('map'),badge)),
        h('div',{class:'map-card-body'},h('h2',{},m.name),h('p',{class:'map-author'},'Erstellt von ',m.creator),h('div',{class:'map-card-counts'},h('span',{},`${m.fields} Felder`),h('span',{},`${m.enemies} Gegner · ${m.bosses} Bosse`)),
          m.lock?h('p',{class:'map-lock-note'},icon('lock'),`${m.lock.holder} bearbeitet gerade`):h('p',{class:'map-lock-note muted'},published?'Für neue Spiele bereit':archived?'Bestehende Spielstände bleiben erhalten':'Für alle im Trupp bearbeitbar'),
          h('div',{class:'map-card-actions'},h('a',{class:'button primary',href:`#/editor?id=${m.id}`},published||archived||m.lock?'Ansehen':'Bearbeiten'),h('button',{class:'button secondary',onclick:()=>copy(m)},'Kopie'),
            archived?null:h('button',{class:'text-button map-delete',onclick:()=>remove(m)},published?'Archivieren':'Löschen')),
          h('small',{class:'map-date'},`Zuletzt geändert ${new Date(m.updatedAt).toLocaleDateString('de-AT')}`)));
    }));
    if(!selected.length)grid.append(h('div',{class:'library-empty panel'},icon('map'),h('h2',{},maps.length?'Keine passende Karte.':'Die erste Welt wartet auf euch.'),h('p',{class:'muted'},maps.length?'Suchbegriff oder Filter anpassen.':'Erstelle eine neue Karte oder importiere dein fertiges Layout als JSON.')));
  }
  function copy(m){mapNameDialog({title:'Als neuen Entwurf kopieren',value:`${m.name.slice(0,65)} – Kopie`,submitLabel:'Kopie erstellen',onSubmit:async name=>{const result=await api.authRpc('copy_map',{p_map_id:m.id,p_name:name});if(!closed)location.hash=`#/editor?id=${result.map.id}`;}});}
  async function remove(m){if(!confirm(m.status==='published'?`„${m.name}“ archivieren? Bestehende Spiele und die Veröffentlichung bleiben erhalten.`:`Entwurf „${m.name}“ löschen?`))return;try{const result=await api.authRpc('delete_map',{p_map_id:m.id,p_expected_revision:m.revision});toast(result.archived?'Karte archiviert.':'Entwurf gelöscht.');await load();}catch(error){if(!closed)setFeedback(message,error.message);}}
  async function load(){setFeedback(message,'');try{if(status?.editorSchemaVersion!==CONFIG.editorSchemaVersion)throw new AppError('EDITOR_NOT_INSTALLED');const result=await api.authRpc('list_maps');if(closed)return;maps=result.maps;render();}catch(error){if(!closed){setFeedback(message,error.message);grid.replaceChildren(h('button',{class:'button secondary',onclick:load},'Erneut laden'));}}}
  load();return {element,cleanup:()=>{closed=true;for(const d of document.querySelectorAll('.workshop-dialog'))d.close();}};
}
