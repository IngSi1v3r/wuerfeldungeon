import {h,feedback,setFeedback} from '../dom.js';
export const POWERUP_INFO=Object.freeze({
 extraLife:{symbol:'♡',name:'Extraleben',description:'Drei zusätzliche Lebensfelder ohne Minuspunkte und ein Diamant.'},
 redDice:{symbol:'⚄',name:'Roter Würfel',description:'Drei zusätzliche Verwendungen des roten Würfels.'},
 torch:{symbol:'🔥',name:'Fackel',description:'Zwei Verwendungen: einen Raum ohne passende Zahl ausleuchten und anschließend sein Nachbarfeld spielen. Gegner können nur das Ziel sein.'},
 axe:{symbol:'🪓',name:'Doppelhit',description:'Zwei Verwendungen: ein Angriff zählt als zwei Treffer. Mit dem roten Würfel kombinierbar.'},
 horn:{symbol:'📯',name:'Horn des Tiefenrufs',description:'Eine Verwendung: enthüllt zehn Sekunden lang die Position aller Monster und Bosse, ohne ihre Wege zu zeigen.'},
 binocular:{symbol:'🔭',name:'Fernglas',description:'Im Nebel dauerhaft drei statt zwei Felder weit sehen. Wirkt sofort für den Rest der Partie.'},
});
export function powerupSelection({selected=[],fog=false,id='game-powerups'}={}) {
 const controls=new Map(),element=h('fieldset',{class:'powerup-selection',id},h('legend',{},'Powerups aus Schatzkisten'));
 for(const [key,info] of Object.entries(POWERUP_INFO)){
  const input=h('input',{id:`${id}-${key}`,type:'checkbox',checked:selected.includes(key),value:key});
  controls.set(key,input);element.append(h('label',{class:'powerup-select-item',for:input.id,title:info.description},input,h('span',{'aria-hidden':'true'},info.symbol),h('span',{},h('strong',{},info.name),['horn','binocular'].includes(key)?h('small',{},'Bei Fog of War'):null)));
 }
 function setFog(enabled){for(const key of ['horn','binocular']){const input=controls.get(key);input.disabled=!enabled;input.closest('label').classList.toggle('unavailable',!enabled);}}
 function set(values){for(const [key,input] of controls)input.checked=values.includes(key);}
 setFog(fog);return {element,set,setFog,values:()=>[...controls].filter(([,input])=>input.checked&&!input.disabled).map(([key])=>key)};
}

export function lobbyPowerupDialog({selected,fog,onSave,onClose}){
 let busy=false;const selection=powerupSelection({selected,fog,id:'lobby-powerups'}),message=feedback();
 const save=h('button',{type:'button',class:'button primary',id:'save-lobby-powerups',onclick:async()=>{
  if(busy)return;busy=true;save.disabled=true;setFeedback(message,'');
  try{await onSave(selection.values());dialog.close();}catch(error){setFeedback(message,error.message);}finally{busy=false;save.disabled=false;}
 }},'Für diese Partie übernehmen');
 const dialog=h('dialog',{class:'game-dialog lobby-powerup-dialog','aria-label':'Powerups der Partie'},h('h2',{},'Powerups dieser Partie'),selection.element,message,h('div',{class:'button-row'},save,h('button',{type:'button',class:'button secondary',onclick:()=>dialog.close()},'Abbrechen')));
 dialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});dialog.addEventListener('close',()=>{dialog.remove();onClose?.();},{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
export function powerupDialog({available,onChoose,onClose}){
 let busy=false;const message=feedback();
 const dialog=h('dialog',{class:'game-dialog powerup-dialog','aria-label':'Powerup auswählen'},h('p',{class:'eyebrow'},'Schatz gefunden'),h('h2',{},'Wähle dein Powerup'),
  h('p',{class:'muted'},'Jede Sorte kannst du pro Partie einmal aus einer Truhe erhalten. Danach geht die Runde weiter.'),
  h('div',{class:'powerup-choices'},...available.map(type=>{const info=POWERUP_INFO[type];return h('button',{class:'powerup-choice',type:'button','data-powerup':type,onclick:async()=>{
   if(busy)return;busy=true;for(const b of dialog.querySelectorAll('button'))b.disabled=true;setFeedback(message,'');
   try{if(await onChoose(type))dialog.close();}catch(error){setFeedback(message,error.message);}
   finally{busy=false;for(const b of dialog.querySelectorAll('button'))b.disabled=false;}
  }},h('span',{class:'powerup-symbol','aria-hidden':'true'},info.symbol),h('strong',{},info.name),h('span',{},info.description));})),message,
  h('button',{class:'text-button',onclick:()=>dialog.close()},'Später auswählen'));
 dialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
 dialog.addEventListener('close',()=>{dialog.remove();onClose?.();},{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
