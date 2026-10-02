import {h,feedback,setFeedback} from '../dom.js';
export const POWERUP_INFO=Object.freeze({
 extraLife:{symbol:'♡',name:'Extraleben',description:'Drei zusätzliche Lebensfelder ohne Minuspunkte und ein Diamant.'},
 redDice:{symbol:'⚄',name:'Roter Würfel',description:'Drei zusätzliche Verwendungen des roten Würfels.'},
 torch:{symbol:'🔥',name:'Fackel',description:'Zwei Verwendungen: einen Raum ohne passende Zahl ausleuchten und anschließend sein Nachbarfeld spielen. Gegner können nur das Ziel sein.'},
 axe:{symbol:'🪓',name:'Doppelhit',description:'Zwei Verwendungen: ein Angriff zählt als zwei Treffer. Mit dem roten Würfel kombinierbar.'},
 binocular:{symbol:'🔭',name:'Fernglas',description:'Im Nebel dauerhaft drei statt zwei Felder weit sehen. Wirkt sofort für den Rest der Partie.'},
});
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
