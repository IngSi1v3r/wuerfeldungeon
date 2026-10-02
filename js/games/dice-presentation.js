import {h} from '../dom.js';
import {diceFace,serverRoll} from './dice.js';

function diceCup(){
 const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');
 svg.setAttribute('viewBox','0 0 150 170');svg.setAttribute('class','dice-cup');svg.setAttribute('aria-hidden','true');
 const paths=[
  ['M30 33 Q75 10 120 33 L111 133 Q75 154 39 133Z','#7c4c30','#deb878'],
  ['M39 40 Q75 55 111 40 L104 128 Q75 142 46 128Z','#a96f44','none'],
  ['M46 53 52 124 M103 53 98 124','none','#d2a46f'],
  ['M38 112 Q75 130 112 112 L111 130 Q75 151 39 130Z','#573b29','#cda977'],
  ['M56 77 75 65 94 77 75 99Z','#d5b570','#5e442b'],
  ['M62 77H88 M75 70V92','none','#6e492a']
 ];
 for(const [d,fill,stroke] of paths){const p=document.createElementNS(ns,'path');for(const [k,v] of Object.entries({d,fill,stroke,'stroke-width':2.5,'stroke-linecap':'round','stroke-linejoin':'round'}))p.setAttribute(k,v);svg.append(p);}
 const lip=document.createElementNS(ns,'ellipse');for(const [k,v] of Object.entries({cx:75,cy:33,rx:45,ry:16,fill:'#352b24',stroke:'#deb878','stroke-width':4}))lip.setAttribute(k,v);svg.append(lip);return svg;
}

// Die Animation folgt ausschließlich einem neu eingetroffenen Serverwurf.
// Reload/Polling spielen den vorhandenen Wurf nicht erneut ab. Die Animation
// verändert weder Würfelergebnis noch Zugfreigabe und stiehlt keinen Fokus.
export function dicePresentation(){
 let initialized=false,lastRoll=null,timer=null,closed=false;
 const faces=h('div',{class:'roll-reveal','aria-hidden':true}),label=h('p',{class:'roll-caption','aria-hidden':true}),cup=diceCup();
 const element=h('div',{class:'dice-presentation',hidden:true,'aria-label':'Würfelanimation'},h('div',{class:'roll-scene'},cup,faces,label,h('button',{type:'button',class:'text-button roll-skip',onclick:stop},'Animation überspringen')));
 function stop(){clearTimeout(timer);timer=null;element.hidden=true;}
 function update(game){
  if(closed)return;
  const roll=serverRoll(game),wasInitialized=initialized;initialized=true;
  if(game.status!=='playing')stop();
  if(!roll||roll.key===lastRoll)return;
  lastRoll=roll.key;
  if(!wasInitialized||game.status!=='playing')return;
  stop();
  const reduced=document.body.classList.contains('reduce-motion')||matchMedia('(prefers-reduced-motion: reduce)').matches;
  faces.replaceChildren(...roll.dice.map((n,i)=>diceFace(n,i===3,i)));
  label.textContent=`${game.participants.find(p=>p.id===roll.rollerId)?.displayName||'Der Trupp'} würfelt`;
  element.classList.toggle('still-roll',reduced);element.hidden=false;
  element.dataset.round=String(roll.round);
  timer=setTimeout(stop,reduced?1000:2100);
 }
 return {element,update,stop,cleanup(){closed=true;stop();}};
}
