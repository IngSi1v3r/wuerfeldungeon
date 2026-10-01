import {h,icon} from '../dom.js';
import {sortRequirements,requirementLabel,lifePenalty,pointsSoFar,elapsedChoiceSeconds} from './rules.js';

function die(value,red,index) {
 const ns='http://www.w3.org/2000/svg',face=document.createElementNS(ns,'svg');face.setAttribute('viewBox','0 0 60 60');face.setAttribute('aria-hidden','true');
 const positions={1:[[30,30]],2:[[17,17],[43,43]],3:[[17,17],[30,30],[43,43]],4:[[17,17],[43,17],[17,43],[43,43]],5:[[17,17],[43,17],[30,30],[17,43],[43,43]],6:[[17,17],[43,17],[17,30],[43,30],[17,43],[43,43]]};
 for(const [cx,cy] of positions[value]||[]){const pip=document.createElementNS(ns,'circle');pip.setAttribute('cx',cx);pip.setAttribute('cy',cy);pip.setAttribute('r','4.5');face.append(pip);}
 return h('span',{class:`dice-face ${red?'red':'white'}`,'aria-label':`${red?'Roter':'Weißer'} Würfel ${index+1}: ${value}`,title:`${red?'Rot':'Weiß'} · ${value}`},face);
}
export function redDiceDialog(uses) {
 return new Promise(resolve=>{
  let result=false,settled=false;
  function finish(value){if(settled)return;settled=true;result=value;dialog.close();dialog.remove();resolve(result);}
  const dialog=h('dialog',{class:'game-dialog red-dice-dialog','aria-labelledby':'red-question'},h('p',{class:'eyebrow'},'Sonderwürfel'),h('h2',{id:'red-question'},'Roten Würfel verwenden?'),h('p',{class:'muted'},`Dieser Zug ist nur mit dem roten Würfel möglich. Du hast noch ${uses} Verwendungen.`),h('div',{class:'button-row'},
   h('button',{id:'confirm-red',class:'button primary',onclick:()=>finish(true)},'Ja, verwenden'),h('button',{id:'cancel-red',class:'button secondary',onclick:()=>finish(false)},'Nein')));
  dialog.addEventListener('close',()=>finish(result),{once:true});document.body.append(dialog);dialog.showModal();
 });
}
export function turnPanel({profile,onRoll,onLoseLife,onResolveWait,onTorch,onAxe,onChoosePowerup}) {
 let current=null,offset=0,closed=false,waitUntil=0,lastRoll=null;
 const replace=(node,...children)=>node.replaceChildren(...children.filter(child=>child!==null&&child!==undefined&&child!==false));
 const timer=h('span',{id:'turn-hourglass',class:'turn-hourglass',hidden:true}),wait=h('div',{class:'wait-management',id:'wait-management',hidden:true}),content=h('div',{class:'turn-content'});
 const element=h('section',{class:'turn-panel panel','aria-label':'Würfel und Zug'},content,timer,wait);
 const lives=h('aside',{class:'game-lives panel','aria-label':'Lebensanzeige'}),score=h('div',{class:'game-score panel'});
 function tick(){if(closed||!current)return;const {game}=current,waiting=game.phase==='choosing'||game.participants.some(p=>p.hasPendingPowerup),seconds=elapsedChoiceSeconds(game,Date.now(),offset);
  timer.hidden=seconds<30||!waiting;timer.textContent=`⌛ ${seconds} s · ${game.status==='paused'?'pausiert':'Wir warten auf die noch offenen Züge.'}`;
  wait.hidden=game.status!=='playing'||!waiting||game.host.id!==profile.id||seconds<60||Date.now()<waitUntil;
 }
 function update(game,busy=false,mode={}) {
  current={game,busy};offset=Date.parse(game.serverNow||new Date().toISOString())-Date.now();
  const own=game.ownState||{},turn=game.turn||{},roller=game.participants.find(p=>p.id===game.rollerId),me=game.participants.find(p=>p.id===profile.id),ended=['finished','cancelled'].includes(game.status),sealed=game.phase==='round_complete';
  const text=ended?'Dieses Spiel ist beendet.':game.status==='paused'?'Das Spiel ist für alle pausiert.':turn.pendingPowerup?'Deine Truhe wartet: Wähle ein Powerup.':mode.torch?'Fackel: '+(mode.middleCellId?'Jetzt das passende Nachbarfeld wählen.':'Zuerst einen freien Zwischenraum wählen.'):mode.axe?'Doppelhit aktiv: Wähle einen erreichbaren Gegner.':sealed?'Endrunde abgeschlossen. Die Schlusswertung folgt in Phase 5.':me?.eliminated?'Du bist ausgeschieden und kannst weiter zuschauen.':game.phase==='waiting_roll'?(game.rollerId===profile.id?'Du bist mit Würfeln dran.':`${roller?.displayName||'Der nächste Spieler'} ist mit Würfeln dran.`):turn.done?'Dein Zug ist gespeichert. Wir warten auf die anderen.':turn.standardPossible?'Wähle ein passendes Feld oder greife einen erreichbaren Gegner an.':turn.torchPossible?'Du kannst eine Fackel verwenden oder ein Leben verlieren.':turn.redPossible?'Du kannst den roten Würfel verwenden oder ein Leben verlieren.':'Für diesen Wurf ist kein Feld spielbar.';
  const rollKey=game.dice?`${game.id}:${game.round}`:null,animate=rollKey!==null&&rollKey!==lastRoll;if(rollKey)lastRoll=rollKey;
  replace(content,h('div',{class:'turn-title'},h('div',{},h('p',{class:'eyebrow'},`Runde ${game.round}${game.finalRound===game.round?' · letzte Runde':''}`),h('h2',{id:'turn-message',role:'status'},text)),
   h('span',{class:'turn-completion'},`${game.participants.filter(p=>p.active&&!p.eliminated&&p.turnDone).length} / ${game.participants.filter(p=>p.active&&!p.eliminated).length} Züge`)),
   game.dice?h('div',{class:'dice-and-options'},h('div',{class:`dice-tray ${animate?'dice-rolling':''}`,id:'game-dice'},...game.dice.map((v,i)=>die(v,i===3,i))),
    game.settings.hints?h('div',{class:'combination-lists'},h('div',{class:'combination-list','aria-label':'Deine Kombinationen'},...sortRequirements(turn.options).map(n=>h('span',{class:'combination'},requirementLabel(n)))),
     turn.redOptions?.length?h('div',{class:'red-combinations'},h('small',{},'Zusätzlich mit Rot:'),...sortRequirements(turn.redOptions).map(n=>h('span',{class:'combination red'},requirementLabel(n)))):null):h('p',{class:'muted no-hints'},'Kombiniere zwei Würfel. Pasch zählt bei gleichen Augen.')):null,
   h('div',{class:'turn-buttons'},turn.canRoll?h('button',{id:'roll-dice',class:'button primary roll-button',disabled:busy,onclick:onRoll},icon('dice'),busy?'Wurf wird gespeichert …':'Würfeln'):null,
    turn.pendingPowerup&&game.status==='playing'?h('button',{id:'choose-powerup',class:'button primary',disabled:busy,onclick:onChoosePowerup},'Powerup wählen'):null,
    turn.canAct&&turn.canLoseLife?h('button',{id:'lose-life',class:'button secondary',disabled:busy,onclick:onLoseLife},'Ein Leben verlieren'):null),
   game.dice?h('p',{class:'dice-explanation'},game.rollerId===profile.id?'Du darfst alle vier Würfel kombinieren.':`Drei weiße Würfel sind frei. Rot kostet eine Verwendung (${own.redUses||0} übrig).`):null);
  const penalties=[...Array(own.extraLives||0).fill(0),0,0,-1,-2,-4,-6,-9,-12,-16,-20,'†'];
  lives.replaceChildren(h('h3',{},'Leben'),h('div',{class:'life-boxes'},...penalties.map((p,i)=>h('span',{class:`life-box ${i<(own.lostLives||0)?'lost':''}`,title:`${i+1}. Verlust: ${p==='†'?'ausgeschieden':`${p} Punkte`}`,'aria-label':`${i+1}. Lebensfeld${i<(own.lostLives||0)?' · verloren':''}`},p))),h('small',{},`${own.lostLives||0} verloren`));
  replace(score,h('div',{class:'score-total'},h('strong',{id:'own-points'},pointsSoFar(own)),h('span',{},ended&&game.status==='finished'?'Punkte gesamt':'Punkte bisher')),
   h('span',{class:'score-diamonds'},icon('diamond'),`${own.diamonds||0} Diamanten`),h('span',{class:'score-penalty'},`Leben: ${lifePenalty(own)}`),h('span',{class:'score-red'},icon('dice'),`${own.redUses||0} × Rot`),
   onTorch&&own.torchUses>0?h('button',{id:'torch-mode',class:`button secondary resource-button ${mode.torch?'active':''}`,disabled:busy||!turn.canAct,'aria-pressed':Boolean(mode.torch),onclick:onTorch},`🔥 ${own.torchUses} × Fackel`):null,
   onAxe&&own.axeUses>0?h('button',{id:'axe-mode',class:`button secondary resource-button ${mode.axe?'active':''}`,disabled:busy||!turn.canAct,'aria-pressed':Boolean(mode.axe),onclick:onAxe},`🪓 ${own.axeUses} × Doppelhit`):null,
   own.pendingChests?.length?h('small',{class:'pending-chests'},`${own.pendingChests.length} Truhe${own.pendingChests.length===1?'':'n'} geöffnet · ${onChoosePowerup?'bitte ein Powerup wählen':'Powerup-Auswahl folgt in Phase 5'}`):null);
  if(game.tasks)score.append(h('div',{class:'game-tasks'},...Object.entries(game.tasks).filter(([,t])=>t.enabled).map(([key,t])=>h('span',{class:`task-progress ${t.completed?'complete':''}`,'data-task':key},`${key==='special'?'X-Felder':'Spezialaufgabe'}: ${t.progress} / ${t.total} · ${t.completed?`${t.reward} ♦ erhalten`:t.firstAvailable?'3 ♦ / 1 ♦':'1 ♦ verfügbar'}`))));
  wait.replaceChildren(h('p',{},'Seit einer Minute sind noch Züge offen. Du entscheidest, ob ihr weiter wartet.'),...game.participants.filter(p=>p.active&&((!p.eliminated&&!p.turnDone)||p.hasPendingPowerup)).map(p=>h('div',{class:'wait-player'},h('strong',{},p.displayName+(p.hasPendingPowerup?' · Powerup offen':'')),h('div',{class:'button-row'},
   h('button',{class:'button secondary',disabled:busy,onclick:()=>onResolveWait(p.id,'skip')},'Zug überspringen'),p.id!==profile.id?h('button',{class:'text-button',disabled:busy,onclick:()=>onResolveWait(p.id,'remove')},'Entfernen'):null))),
   h('button',{class:'text-button',onclick:()=>{waitUntil=Date.now()+30000;tick();}},'Weiter warten'));
  tick();
 }
 const clock=setInterval(tick,1000);
 return {element,lives,score,update,cleanup:()=>{closed=true;clearInterval(clock);}};
}
