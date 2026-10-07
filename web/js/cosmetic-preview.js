import {h} from './dom.js';
import {diceFace} from './games/dice.js';
import {diceCup} from './games/dice-presentation.js';

export function cosmeticPreview(category,value){
 const preview=h('div',{class:`cosmetic-preview ${category}`,'data-preview-style':value,'aria-hidden':'true'});
 if(category==='diceStyle')preview.append(diceFace(5,false,0),diceFace(3,false,1),diceFace(4,true,2));
 if(category==='cupStyle')preview.append(diceCup(value));
 if(category==='campStyle')preview.append(h('img',{src:`./assets/${value==='forest'?'forest':`forest-${value}`}.svg`,alt:'',loading:'lazy'}));
 return preview;
}
