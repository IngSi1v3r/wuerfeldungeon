import {h} from '../dom.js';

// Bei einer vollständig automatischen Runde ist game.dice schon wieder leer.
// Das öffentliche Wurfereignis erhält Ergebnis, Runde und ursprünglichen Roller.
export function serverRoll(game) {
 const valid=dice=>Array.isArray(dice)&&dice.length===4&&dice.every(n=>Number.isInteger(n)&&n>=1&&n<=6);
 if(valid(game.dice))return {key:`${game.id}:${game.round}`,round:game.round,dice:game.dice,rollerId:game.rollerId};
 let latest=null;
 for(const event of game.events||[]){
  const p=event.payload;
  if(event.kind==='rolled'&&Number.isInteger(p?.round)&&p.round<=game.round&&valid(p.dice)&&(!latest||p.round>latest.round))latest=p;
 }
 return latest?{key:`${game.id}:${latest.round}`,round:latest.round,dice:latest.dice,rollerId:latest.rollerId}:null;
}

export function diceFace(value,red,index=0) {
 const ns='http://www.w3.org/2000/svg',face=document.createElementNS(ns,'svg');face.setAttribute('viewBox','0 0 60 60');face.setAttribute('aria-hidden','true');
 const positions={1:[[30,30]],2:[[17,17],[43,43]],3:[[17,17],[30,30],[43,43]],4:[[17,17],[43,17],[17,43],[43,43]],5:[[17,17],[43,17],[30,30],[17,43],[43,43]],6:[[17,17],[43,17],[17,30],[43,30],[17,43],[43,43]]};
 for(const [cx,cy] of positions[value]||[]){const pip=document.createElementNS(ns,'circle');pip.setAttribute('cx',cx);pip.setAttribute('cy',cy);pip.setAttribute('r','4.5');face.append(pip);}
 return h('span',{class:`dice-face ${red?'red':'white'}`,'aria-label':`${red?'Roter':'Weißer'} Würfel ${index+1}: ${value}`,title:`${red?'Rot':'Weiß'} · ${value}`},face);
}
