import {audio} from '../audio.js';
import {h} from '../dom.js';
import {diceFace,serverRoll} from './dice.js';

export function diceCup(style=document.body.dataset.cupStyle||'leather'){
 const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');
 svg.setAttribute('viewBox','0 0 150 170');svg.setAttribute('class','dice-cup');svg.setAttribute('data-cup-style',style);svg.setAttribute('aria-hidden','true');
 const colors=({leather:['#7c4c30','#deb878','#a96f44','#573b29'],wood:['#b28047','#edce94','#c99860','#79522e'],runic:['#264f4b','#bcd7ab','#3f7068','#193b38']})[style]||['#7c4c30','#deb878','#a96f44','#573b29'];
 const paths=[
  ['M30 33 Q75 10 120 33 L111 133 Q75 154 39 133Z',colors[0],colors[1]],
  ['M39 40 Q75 55 111 40 L104 128 Q75 142 46 128Z',colors[2],'none'],
  ['M46 53 52 124 M103 53 98 124','none','#d2a46f'],
  ['M38 112 Q75 130 112 112 L111 130 Q75 151 39 130Z',colors[3],colors[1]],
  ['M56 77 75 65 94 77 75 99Z','#d5b570','#5e442b'],
  ['M62 77H88 M75 70V92','none','#6e492a']
 ];
 for(const [d,fill,stroke] of paths){const p=document.createElementNS(ns,'path');for(const [k,v] of Object.entries({d,fill,stroke,'stroke-width':2.5,'stroke-linecap':'round','stroke-linejoin':'round'}))p.setAttribute(k,v);svg.append(p);}
 if(style==='wood')for(const x of [51,63,87,99]){const p=document.createElementNS(ns,'path');p.setAttribute('d',`M ${x} 51 Q ${x-5} 86 ${x} 127`);p.setAttribute('fill','none');p.setAttribute('stroke','#5e422b');p.setAttribute('stroke-width','1.7');svg.append(p);}
 if(style==='runic')for(const x of [54,96]){const p=document.createElementNS(ns,'path');p.setAttribute('d',`M ${x} 64 V 108 M ${x-6} 74 L ${x} 66 L ${x+6} 74 M ${x-5} 94 L ${x+5} 85`);p.setAttribute('fill','none');p.setAttribute('stroke','#d4ebe5');p.setAttribute('stroke-width','2.5');svg.append(p);}
 const lip=document.createElementNS(ns,'ellipse');for(const [k,v] of Object.entries({cx:75,cy:33,rx:45,ry:16,fill:'#352b24',stroke:colors[1],'stroke-width':4}))lip.setAttribute(k,v);svg.append(lip);return svg;
}

// Die Animation folgt ausschließlich einem neu eingetroffenen Serverwurf.
// Reload/Polling spielen den vorhandenen Wurf nicht erneut ab. Die Animation
// verändert weder Würfelergebnis noch Zugfreigabe und stiehlt keinen Fokus.
export function dicePresentation({getPreferences=()=>({})}={}){
 let initialized=false,lastRoll=null,timer=null,closed=false,end=0,waiters=[];
 const faces=h('div',{class:'roll-reveal','aria-hidden':true}),label=h('p',{class:'roll-caption','aria-hidden':true}),cup=diceCup();
 const element=h('div',{class:'dice-presentation',hidden:true,'aria-label':'Würfelanimation'},h('div',{class:'roll-scene'},cup,faces,label,h('button',{type:'button',class:'text-button roll-skip',onclick:stop},'Animation überspringen')));
 function stop(){clearTimeout(timer);timer=null;end=0;element.hidden=true;for(const done of waiters)done();waiters=[];}
 function update(game){
  if(closed)return;
  const roll=serverRoll(game),wasInitialized=initialized;initialized=true;
  if(['paused','cancelled'].includes(game.status))stop();
  if(!roll||roll.key===lastRoll)return;
  lastRoll=roll.key;
  if(!wasInitialized||!['playing','finished'].includes(game.status))return;
  const prefs=getPreferences(),duration=({none:0,short:2000,normal:4000,long:6000})[prefs.diceAnimation||'normal']??4000;audio.effect('dice');if(!duration)return;
  stop();
  const reduced=document.body.classList.contains('reduce-motion')||matchMedia('(prefers-reduced-motion: reduce)').matches;
  faces.replaceChildren(...roll.dice.map((n,i)=>diceFace(n,i===3,i)));
  label.textContent=`${game.participants.find(p=>p.id===roll.rollerId)?.displayName||'Der Trupp'} würfelt`;
  element.classList.toggle('still-roll',reduced);element.hidden=false;
  element.dataset.round=String(roll.round);
  const ms=reduced?Math.min(1000,duration):duration;element.style.setProperty('--roll-duration',`${ms/1000}s`);end=Date.now()+ms;timer=setTimeout(stop,ms);
 }
 return {element,update,stop,remaining:()=>Math.max(0,end-Date.now()),idle:()=>end> Date.now()?new Promise(resolve=>waiters.push(resolve)):Promise.resolve(),cleanup(){closed=true;stop();}};
}
