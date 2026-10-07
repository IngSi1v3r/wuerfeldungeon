import {h,feedback,setFeedback,icon} from '../dom.js';
import {connections} from '../maps/model.js';
import {boardPreview} from './board-preview.js';
import {TestGame} from './test-engine.js';
import {POWERUP_INFO,powerupDialog} from './powerups.js';
import {diceFace} from './dice.js';
import {requirementLabel} from './rules.js';
import {hornIsActive} from './visibility.js';
import {audio} from '../audio.js';

export function testMode({api,document:doc,profile}){
 const engine=new TestGame({document:doc,rules:doc.rules,allowedPowerups:doc.allowedPowerups,graph:connections(doc)});
 let closed=false,middle=null,torch=false,axe=false,powerDialog=null,lastHorn=false;
 const message=feedback(),status=h('strong',{id:'test-status',role:'status'}),score=h('span',{id:'test-score'}),tray=h('div',{class:'dice-tray'}),combos=h('div',{class:'combination-list'}),powers=h('div',{class:'test-power-controls'}),tools=h('div',{class:'test-resource-controls'});
 function toggle(id,label,checked){const input=h('input',{id,type:'checkbox',checked});input.addEventListener('change',render);return {input,node:h('label',{class:'rule-check'},input,label)};}
 const fog=toggle('test-fog','Nebel',false),sums=toggle('test-sums','Würfelsummen',true),hints=toggle('test-hints','Feldtipps',true);
 const roll=h('button',{id:'test-roll',class:'button primary',onclick:()=>act(()=>{const result=engine.roll();audio.effect('dice');if(result.automatic)setFeedback(message,'Kein legaler Zug: ein Leben verloren.','info');})},icon('dice'),'Würfeln');
 const lose=h('button',{id:'test-lose-life',class:'button secondary',onclick:()=>act(()=>engine.loseLife())},'Leben verlieren');
 const preview=boardPreview(api,engine.definition,{prefix:'test',title:'Lokales Testspiel',onCell:id=>{
  if(torch&&!middle){if(!engine.reachable(id)||['monster','boss','miniboss','bonus'].includes(engine.room(id)?.type)){setFeedback(message,'Als Zwischenraum einen freien angrenzenden Raum auswählen.');return;}middle=id;render();return;}
  act(()=>{const result=engine.play(id,{middle:torch?middle:null,axe});audio.effect(result.defeated?'victory':engine.room(id)&&['monster','boss','bonus'].includes(engine.room(id).type)?'attack':'pencil');middle=null;torch=false;axe=false;});
 },onContextCell:id=>act(()=>{const result=engine.play(id,{cheat:true});audio.effect(result.defeated?'victory':'pencil');})});
 function act(fn){try{setFeedback(message,'');fn();render();chooseChest();}catch(error){setFeedback(message,error.message);}}
 function chooseChest(){if(closed||powerDialog||!engine.state.pendingChests.length)return;const available=engine.availablePowers(fog.input.checked);if(!available.length){engine.state.pendingChests=[];render();return;}
 powerDialog=powerupDialog({available,onChoose:async type=>{engine.choosePower(type);render();return true;},onClose:()=>{powerDialog=null;}});}
 const reset=h('button',{id:'test-reset',class:'button secondary',onclick:()=>{powerDialog?.close();setFeedback(message,'');engine.reset();middle=null;torch=false;axe=false;render();}},'Neu beginnen');
 const dialog=h('dialog',{class:'game-dialog test-mode-dialog','aria-label':'Lokaler Kartentest'},h('header',{class:'test-mode-header'},h('h2',{},'Testmodus'),h('span',{},'Nur auf diesem Gerät · ohne Speicherung'),h('button',{class:'button secondary',onclick:()=>dialog.close()},'Test schließen')),h('div',{class:'test-controls'},fog.node,sums.node,hints.node,reset),h('div',{class:'test-board-area'},preview.element),h('div',{class:'test-dock'},status,score,roll,lose,tray,combos,tools),h('details',{},h('summary',{},'Powerups frei ausprobieren'),powers),message,h('small',{},'Linksklick: normaler Zug. Rechtsklick: Feld freischalten oder einen beliebigen Gegner einmal angreifen.'));
 for(const [type,info] of Object.entries(POWERUP_INFO)){
  const input=h('input',{type:'checkbox','data-test-power':type,onchange:()=>act(()=>engine.enablePower(type,input.checked))}),refill=h('button',{class:'text-button',type:'button',onclick:()=>act(()=>{engine.enablePower(type);input.checked=true;})},'Auffüllen');powers.append(h('div',{},h('label',{},input,`${info.symbol} ${info.name}`),refill));
 }
 function render(){if(closed)return;const state=engine.state;status.textContent=engine.eliminated?'Ausgeschieden · Rechtsklick bleibt frei':engine.finished?'Test beendet · Rechtsklick bleibt frei':state.pendingChests.length?'Powerup auswählen':engine.phase==='waiting_roll'?`Runde ${engine.round+1} · dein Wurf`:torch?(middle?'Fackel: Zielfeld wählen':'Fackel: Zwischenraum wählen'):`Runde ${engine.round} · dein Zug`;
 score.textContent=`${engine.score().points} Punkte · ${state.diamonds} ♦ · ${state.lostLives} Leben verloren`;
 roll.disabled=engine.phase!=='waiting_roll'||engine.finished||engine.eliminated||state.pendingChests.length>0;lose.hidden=engine.phase!=='choosing'||engine.actions().length>0||state.pendingChests.length>0;
 tray.replaceChildren(...(engine.dice||[]).map((n,i)=>diceFace(n,i===3,i)));combos.hidden=!sums.input.checked;combos.replaceChildren(...engine.options().map(n=>h('span',{class:'combination'},requirementLabel(n))));
 tools.replaceChildren(state.torchUses>0?h('button',{id:'test-torch',class:`resource-button ${torch?'active':''}`,onclick:()=>{torch=!torch;axe=false;middle=null;render();}},`🔥 ${state.torchUses}`):null,state.axeUses>0?h('button',{id:'test-axe',class:`resource-button ${axe?'active':''}`,onclick:()=>{axe=!axe;torch=false;middle=null;render();}},`🪓 ${state.axeUses}`):null,state.hornUses>0?h('button',{id:'test-horn',class:'resource-button',onclick:()=>act(()=>{engine.horn();audio.effect('horn');})},'📯 Horn'):null,state.pendingChests.length?h('button',{class:'button secondary',onclick:chooseChest},'Powerup wählen'):null);
 for(const input of powers.querySelectorAll('input'))input.checked=state.powerups.includes(input.dataset.testPower);
 const actions=torch?(middle?engine.actions(middle):engine.torchActions().map(a=>({...a,cellId:a.middleCellId}))):engine.actions();
 preview.update({...engine.view(fog.input.checked),actions,middleCellId:middle,interactive:!engine.finished&&!engine.eliminated&&engine.phase==='choosing'&&!state.pendingChests.length,contextInteractive:true,hints:hints.input.checked,markStyle:profile?.preferences?.markStyle||'cross'});lastHorn=hornIsActive(state);
 }
 const clock=setInterval(()=>{if(lastHorn!==hornIsActive(engine.state))render();},250);
 dialog.addEventListener('close',()=>{closed=true;clearInterval(clock);powerDialog?.close();preview.cleanup();dialog.remove();},{once:true});document.body.append(dialog);dialog.showModal();render();return dialog;
}
