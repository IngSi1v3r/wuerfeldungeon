import {h,feedback,setFeedback} from '../dom.js';
import {diceFace} from './dice.js';
import {diceCombinations} from './rules.js';

export function effectiveDice(game){
 const state=game.ownState||{};
 return state.magicRound===game.round&&Array.isArray(state.magicDice)?state.magicDice:game.dice;
}

function openDialog(title,body){
 const dialog=h('dialog',{class:'game-dialog artifact-dialog','aria-label':title},h('h2',{},title),body);
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}

export function magicDiceDialog({dice,onChoose}){
 let selected=null,busy=false;
 const message=feedback(),row=h('div',{class:'artifact-dice-row'}),preview=h('p',{class:'muted'}),apply=h('button',{class:'button primary',disabled:true,onclick:async()=>{
  if(!selected||busy)return;busy=true;apply.disabled=true;try{await onChoose(selected.index,selected.delta);dialog.close();}catch(error){setFeedback(message,error.message);busy=false;apply.disabled=false;}
 }},'Änderung anwenden');
 dice.forEach((n,index)=>{
  const face=h('div',{class:'artifact-die'},diceFace(n,index===3,index)),controls=h('div',{class:'artifact-directions'});
  for(const delta of [-1,1]){
   const button=h('button',{type:'button',class:'button secondary',disabled:n+delta<1||n+delta>6,'aria-label':`Würfel ${index+1} von ${n} auf ${n+delta} ändern`,onclick:()=>{
    selected={index,delta};row.querySelectorAll('button').forEach(b=>b.classList.remove('chosen'));button.classList.add('chosen');
    preview.replaceChildren('Würfel ',String(index+1),': ',diceFace(n,index===3,index),' → ',diceFace(n+delta,index===3,index));apply.disabled=false;
   }},delta<0?'−1':'+1');controls.append(button);
  }face.append(controls);row.append(face);
 });
 const dialog=openDialog('Magischer Würfel',h('div',{},h('p',{},'Wähle einen Würfel. Sein Ergebnis verändert sich nur für deinen Zug um genau eins.'),row,preview,message,h('div',{class:'button-row'},apply,h('button',{class:'button secondary',onclick:()=>dialog.close()},'Abbrechen'))));return dialog;
}

export function flaskOptions({dice,freeRed,redUses,includeExact=false}){
 const numeric=value=>/^([2-9]|10|11|12)$/.test(value);
 const normal=new Set(diceCombinations(dice,freeRed,includeExact).filter(numeric));
 const all=redUses>0?diceCombinations(dice,true,includeExact):[];
 return [...new Set([...normal,...all.filter(numeric)])].sort((a,b)=>Number(a)-Number(b)).map(number=>({number,useRed:!normal.has(number)}));
}

export function numberFlaskDialog({options,onChoose}){
 let busy=false;const message=feedback(),choices=h('div',{class:'flask-choices'});
 const dialog=openDialog('Zahlenbüchse',h('div',{},h('p',{},'Bewahre eine Zahl aus diesem Wurf auf. Das Einpacken ersetzt deinen Zug. In einer späteren Runde kannst du sie einmal statt des aktuellen Wurfs einsetzen.'),choices,message,h('button',{class:'button secondary',onclick:()=>dialog.close()},'Abbrechen')));
 for(const {number,useRed} of options)choices.append(h('button',{class:'button secondary',disabled:false,'data-number':number,onclick:async()=>{
  if(busy)return;if(useRed&&!confirm(`Für die ${number} eine Verwendung des roten Würfels ausgeben und sie einpacken?`))return;
  busy=true;choices.querySelectorAll('button').forEach(button=>button.disabled=true);
  try{await onChoose(number,useRed);dialog.close();}catch(error){busy=false;choices.querySelectorAll('button').forEach(button=>button.disabled=false);setFeedback(message,error.message);}
 }},number,useRed?' · Rot':''));
 if(!options.length)choices.append(h('p',{class:'muted'},'In diesem Wurf ist keine Zahl verfügbar.'));
 return dialog;
}
