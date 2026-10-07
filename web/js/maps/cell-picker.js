import {h,feedback,setFeedback} from '../dom.js';
import {connections} from './model.js';
import {boardPreview} from '../games/board-preview.js';
import {cellLabel} from './features.js';
// Eigener Ansichtsmodus, keine Änderungen an Feldern oder am Dokument.
export function cellPicker({api,document:doc,selected=[],count=2,allowed=()=>true,onDone,onCancel}){
 const chosen=new Set(selected.map(String)),message=feedback(),status=h('p',{role:'status'}),definition={document:doc,rules:doc.rules,graph:connections(doc)};let complete=false;
 const preview=boardPreview(api,definition,{prefix:'picker',title:'Zielfelder auswählen',onCell:id=>{
  const room=doc.rooms.find(r=>String(r.id)===id);if(!allowed(room)){setFeedback(message,'Für diese Aufgabe bitte ein Monster oder einen Boss auswählen.');return;}
  setFeedback(message,'');chosen.has(id)?chosen.delete(id):chosen.add(id);paint();if(chosen.size===count)finish();
 }});
 function paint(){status.textContent=`${chosen.size} / ${count} Felder ausgewählt`;preview.update({state:{reached:[...chosen]},interactive:true,hints:false,markStyle:'runes'});}
 function finish(){if(complete)return;complete=true;onDone([...chosen].map(Number));dialog.close();}
 const dialog=h('dialog',{class:'workshop-dialog cell-picker-dialog','aria-label':'Felder auf Karte auswählen'},h('h2',{},'Felder auf der Karte auswählen'),status,preview.element,message,h('div',{class:'picker-selected'}),h('div',{class:'button-row'},h('button',{class:'button secondary',onclick:()=>dialog.close()},'Abbrechen')));
 dialog.addEventListener('close',()=>{preview.cleanup();dialog.remove();if(!complete)onCancel?.();},{once:true});document.body.append(dialog);paint();dialog.showModal();return dialog;
}
