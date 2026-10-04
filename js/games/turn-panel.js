import {assetUrl} from '../maps/model.js';
import {h,icon} from '../dom.js';
import {sortRequirements,requirementLabel,lifePenalty,pointsSoFar,gameWaitKind,elapsedWaitSeconds,diceHints,roomLabel} from './rules.js';
import {goalText} from '../maps/features.js';
import {fieldSymbolNode} from '../maps/field-symbols.js';
import {renderSection} from './render.js';
import {diceFace,serverRoll} from './dice.js';

export function redDiceDialog(uses) {
 return new Promise(resolve=>{
  let result=false,settled=false;
  function finish(value){if(settled)return;settled=true;result=value;dialog.close();dialog.remove();resolve(result);}
  const dialog=h('dialog',{class:'game-dialog red-dice-dialog','aria-labelledby':'red-question'},h('p',{class:'eyebrow'},'Sonderwürfel'),h('h2',{id:'red-question'},'Roten Würfel verwenden?'),h('p',{class:'muted'},`Dieser Zug ist nur mit dem roten Würfel möglich. Du hast noch ${uses} Verwendungen.`),h('div',{class:'button-row'},
   h('button',{id:'confirm-red',class:'button primary',onclick:()=>finish(true)},'Ja, verwenden'),h('button',{id:'cancel-red',class:'button secondary',onclick:()=>finish(false)},'Nein')));
  dialog.addEventListener('close',()=>finish(result),{once:true});document.body.append(dialog);dialog.showModal();
 });
}

export function turnPanel({profile,onRoll,onLoseLife,onResolveWait,onTorch,onAxe,onHorn,onChoosePowerup}) {
 let current=null,offset=0,closed=false,waitUntil=0,lastWait=null,detail=null;
 const timer=h('span',{id:'turn-hourglass',class:'turn-hourglass',hidden:true}),wait=h('div',{class:'wait-management',id:'wait-management',hidden:true,'aria-label':'Ausstehende Spieler'});
 const title=h('div',{class:'turn-title'}),diceTray=h('div',{class:'dice-tray',id:'game-dice'}),options=h('div',{class:'dice-options'}),diceArea=h('div',{class:'dice-and-options',hidden:true},diceTray,options),buttons=h('div',{class:'turn-buttons'});
 const element=h('section',{class:'turn-panel','aria-label':'Würfel und Zug'},title,diceArea,buttons,timer);
 const prompt=h('div',{class:'turn-prompt'}),overlay=h('div',{class:'turn-overlay'},prompt,wait);
 const lives=h('aside',{class:'game-lives','aria-label':'Lebensanzeige'}),tasks=h('aside',{class:'game-tasks','aria-label':'Bonusaufgaben'});
 const total=h('strong',{id:'own-points'}),diamonds=h('span',{class:'score-diamonds'}),penalty=h('span',{class:'score-penalty'}),gold=h('span',{class:'score-gold'}),resources=h('div',{class:'score-resources'});
 const score=h('section',{class:'game-score','aria-label':'Deine Punkte und Powerups'},h('div',{class:'score-total'},total,h('span',{},'Punkte')),h('div',{class:'score-details'},diamonds,gold,penalty),resources);
 function tick(){
  if(closed||!current)return;
  const {game}=current,kind=gameWaitKind(game),waiting=kind!==null&&['playing','paused'].includes(game.status),seconds=elapsedWaitSeconds(game,Date.now(),offset);
  timer.hidden=seconds<30||!waiting;
  const text=`⌛ ${seconds} s`;if(timer.textContent!==text)timer.textContent=text;
  timer.title=game.status==='paused'?'Pausiert':kind==='roll'?'Warten auf den Wurf':'Warten auf die offenen Züge';
  wait.hidden=game.status!=='playing'||!waiting||game.host.id!==profile.id||seconds<60||Date.now()<waitUntil;
 }
 function goalFor(game,key){return game.definition?.rules.goals?.[key==='special'?0:1];}
 function taskTitle(goal,t,key){
  if((goal?.type||t.type)==='allType')return ({normal:'Wegfelder',doubleSum:'Paschfelder',diamond:'Diamanten',chest:'Schatzkisten',rune:'Runenfelder',special:'Runenfelder',monster:'Monster',boss:'Bosse',bonus:'Bonusfelder',trap:'Fallenfelder',portal:'Portalfelder',crazy:'Zufallsfelder',goldSack:'Goldsäcke',goldCoin:'Goldmünzen'})[goal?.fieldType]||'Zielfelder';
  return ({reachFields:'Zielfelder',defeatEnemies:'Gegner besiegen',firstEnemies:'Erstbesieger',connect:'Weg verbinden',collectDiamonds:'Diamantenziel'})[goal?.type||t.type]||(key==='special'?'Alle Runen':'Bonusaufgabe');
 }
 function taskCell(game,t,id){
  const room=game.definition?.document.rooms.find(r=>String(r.id)===String(id)),done=(t.completedIds||game.ownState?.reached||[]).map(String).includes(String(id)),hidden=false;
  const value=room?.type==='crazy'?game.roundRequirements?.[String(id)]:room?.number;
  const symbols={rune:'✕',special:'✕',trap:'⚠',portal:'◎',crazy:'✦',diamond:'♦',chest:'▣',goldSack:'●',goldCoin:'●',bonus:'⚑',monster:'⚔',boss:'⚔',miniboss:'⚔'};
  const image=done&&room?.defeatedImage?room.defeatedImage:room?.image,enemy=['monster','boss','bonus','miniboss'].includes(room?.type);
  return h('span',{class:`task-cell ${enemy?'enemy-task':''} ${done?'checked':''} ${hidden?'unknown':''}`,'data-task-cell':String(id),'data-type':hidden?'unknown':room?.type||'normal',title:hidden?'Im Nebel':`${room?roomLabel(room):`Feld #${id}`}${done?' · erreicht':''}`,'aria-label':hidden?'Zielfeld im Nebel':`${room?roomLabel(room):`Feld #${id}`}${done?' · erreicht':''}`},
   enemy&&image?h('img',{src:image.src.startsWith('asset:')?assetUrl(image.src):image.src,alt:room.name||'Gegner'}):h('span',{class:'task-cell-symbol','aria-hidden':true},['rune','crazy','doubleSum'].includes(room?.type)?fieldSymbolNode(room.type,25,room.type==='doubleSum'?room.number/2:3):symbols[room?.type]||'·'),h('span',{class:'task-cell-value'},enemy?room.name||`#${id}`:value!=null?requirementLabel(value):`#${id}`),done?h('span',{class:'task-check','aria-hidden':true},'✓'):null);
 }
 function taskBody(game,key,expanded=false){
  const t=game.tasks?.[key];if(!t?.enabled)return null;
  const rooms=game.definition?.document.rooms||[],goal=goalFor(game,key),ids=t.cellIds||[],limit=expanded?ids.length:8;
  const description=goal?goalText(goal,rooms):key==='special'?'Alle X-Felder erreichen':'Spezialaufgabe';
  return [h('div',{class:'task-title'},h('strong',{},expanded?`Bonusaufgabe ${key==='special'?1:2}`:taskTitle(goal,t,key)),h('span',{class:'task-count'},t.completed?'✓':`${t.progress}/${t.total}`)),
   expanded?h('p',{class:'task-description'},description):null,
   h('p',{class:'task-reward'},t.completed?`${t.reward} ♦ erhalten`:t.blocked?'Nicht mehr erreichbar':h('span',{},h('span',{class:t.firstAvailable?'':'reward-unavailable'},`${t.rewardFirst??3} ♦`),' / ',`${t.rewardLater??1} ♦`)),
   ids.length?h('div',{class:'task-cells'},...ids.slice(0,limit).map(id=>taskCell(game,t,id)),ids.length>limit?h('span',{class:'task-more'},`+${ids.length-limit}`):null):null,
   t.type==='connect'&&t.progress===2&&!t.completed?h('small',{},'Weg noch offen'):null];
 }
 function showTask(key){
  if(detail)detail.dialog.close();
  const content=h('div'),dialog=h('dialog',{class:'game-dialog task-dialog','aria-label':`Bonusaufgabe ${key==='special'?1:2}`},content,h('button',{class:'button secondary',onclick:()=>dialog.close()},'Schließen'));
  content.append(...taskBody(current.game,key,true));detail={key,dialog,content};dialog.addEventListener('close',()=>{if(detail?.dialog===dialog)detail=null;dialog.remove();},{once:true});document.body.append(dialog);dialog.showModal();
 }
 function update(game,busy=false,mode={}) {
  current={game,busy};offset=Date.parse(game.serverNow||new Date().toISOString())-Date.now();
  const waitingKind=gameWaitKind(game),waitKey=JSON.stringify([game.id,game.round,waitingKind,waitingKind==='roll'?game.rollerId:game.choiceStartedAt]);
  if(waitKey!==lastWait){lastWait=waitKey;waitUntil=0;}
  const own=game.ownState||{},turn=game.turn||{},roller=game.participants.find(p=>p.id===game.rollerId),me=game.participants.find(p=>p.id===profile.id),ended=['finished','cancelled'].includes(game.status),sealed=game.phase==='round_complete';
  element.dataset.ownStatus=turn.canAct?'act':'wait';
  const text=mode.awaitingLoss?'Wurf wird ausgewertet …':ended?(game.status==='finished'?'Abgeschlossen':'Abgebrochen'):game.status==='paused'?'Pause':turn.pendingPowerup?'Truhe geöffnet':mode.torch?(mode.middleCellId?'Fackel · Zielfeld wählen':'Fackel · Zwischenraum wählen'):mode.axe?'Doppelhit aktiv':sealed?'Schlusswertung':me?.eliminated?'Ausgeschieden':game.phase==='waiting_roll'?(game.rollerId===profile.id?'Dein Wurf':`${roller?.displayName||'Nächster Spieler'} würfelt`):turn.done?'Warten auf Mitspieler':'Du bist am Zug';
  const completed=game.participants.filter(p=>p.active&&!p.eliminated&&p.turnDone).length,totalPlayers=game.participants.filter(p=>p.active&&!p.eliminated).length;
  renderSection(title,[text,completed,totalPlayers],()=>[h('span',{id:'turn-message',role:'status'},text),h('span',{class:'turn-completion',title:'Gespeicherte Züge'},`${completed}/${totalPlayers} ✓`)]);
  const showPrompt=turn.canRoll||game.status==='paused'||game.phase==='waiting_roll'&&!ended||sealed||mode.torch||mode.axe;
  prompt.hidden=!showPrompt;
  renderSection(prompt,[turn.canRoll,game.status,game.phase,text,busy],()=>turn.canRoll?h('button',{id:'roll-dice',class:'button primary roll-button',disabled:busy,onclick:onRoll},icon('dice'),busy?'Würfeln …':'Würfeln'):h('span',{class:`center-state ${game.status==='paused'?'paused-state':''}`},game.status==='paused'?icon('pause'):null,text));
  const roll=serverRoll(game);
  diceArea.hidden=!roll;
  if(roll){
   diceTray.setAttribute('aria-label',game.dice?'Aktueller Wurf':`Letzter Wurf · Runde ${roll.round}`);diceTray.title=game.dice?'Aktueller Wurf':`Letzter Wurf · Runde ${roll.round}`;
   renderSection(diceTray,[roll.key,roll.dice],()=>roll.dice.map((v,i)=>diceFace(v,i===3,i)));
   renderSection(options,[Boolean(game.dice),diceHints(game.settings),turn.options,turn.redOptions],()=>game.dice&&diceHints(game.settings)?h('div',{class:'combination-lists'},h('div',{class:'combination-list','aria-label':'Deine Kombinationen'},...sortRequirements(turn.options).map(n=>h('span',{class:'combination'},requirementLabel(n)))),
    turn.redOptions?.length?h('div',{class:'red-combinations','aria-label':'Zusätzlich mit rotem Würfel'},...sortRequirements(turn.redOptions).map(n=>h('span',{class:'combination red'},requirementLabel(n)))):null):null);
  }
  renderSection(buttons,[turn.pendingPowerup,turn.canAct,turn.canLoseLife,game.status,busy],()=>[
    turn.pendingPowerup&&game.status==='playing'?h('button',{id:'choose-powerup',class:'button primary',disabled:busy,onclick:onChoosePowerup},'Powerup wählen'):null,
    turn.canAct&&turn.canLoseLife?h('button',{id:'lose-life',class:'button secondary',disabled:busy,onclick:onLoseLife},icon('heart'),'Leben verlieren'):null]);
  const penalties=[...Array(own.extraLives||0).fill(0),0,0,-1,-2,-4,-6,-9,-12,-16,-20,'†'];
  renderSection(lives,[own.extraLives,own.lostLives],()=>[h('h3',{},icon('heart'),'Leben'),h('div',{class:'life-boxes',...(penalties.length>11?{'data-extra':true}:{})},...penalties.map((p,i)=>h('span',{class:`life-box ${i<(own.lostLives||0)?'lost':''}`,title:`${i+1}. Verlust: ${p==='†'?'ausgeschieden':`${p} Punkte`}`,'aria-label':`${i+1}. Lebensfeld${i<(own.lostLives||0)?' · verloren':''}`},p))),h('small',{},`${own.lostLives||0} / ${penalties.length}`)]);
  total.textContent=String(pointsSoFar(own));score.querySelector('.score-total').title=ended&&game.status==='finished'?'Punkte gesamt':'Punkte bisher';
  renderSection(diamonds,own.diamonds,()=>[icon('diamond'),h('strong',{},own.diamonds||0)]);diamonds.title=`${own.diamonds||0} Diamanten`;
  renderSection(penalty,[own.lostLives,own.extraLives],()=>`${lifePenalty(own)} Leben`);
  gold.hidden=!game.definition?.document.rooms.some(r=>['goldSack','goldCoin'].includes(r.type));renderSection(gold,own.goldPoints,()=>`● ${own.goldPoints||0}`);gold.title='Goldpunkte';
  renderSection(resources,[own.redUses,own.torchUses,own.axeUses,own.hornUses,own.powerups,mode.torch,mode.axe,busy,turn.canAct,game.settings.fog,game.status],()=>[
   h('span',{class:'score-red',title:'Verwendungen des roten Würfels'},icon('dice'),`${own.redUses||0}×`),
   onTorch&&(own.torchUses>0||own.powerups?.includes('torch'))?h('button',{id:'torch-mode',class:`resource-button ${mode.torch?'active':''}`,disabled:busy||!turn.canAct||!own.torchUses,'aria-label':`Fackel · ${own.torchUses||0} Verwendungen`,'aria-pressed':Boolean(mode.torch),title:'Fackel',onclick:onTorch},'🔥',h('span',{},own.torchUses||0)):null,
   onAxe&&(own.axeUses>0||own.powerups?.includes('axe'))?h('button',{id:'axe-mode',class:`resource-button ${mode.axe?'active':''}`,disabled:busy||!turn.canAct||!own.axeUses,'aria-label':`Doppelhit · ${own.axeUses||0} Verwendungen`,'aria-pressed':Boolean(mode.axe),title:'Doppelhit',onclick:onAxe},'🪓',h('span',{},own.axeUses||0)):null,
   onHorn&&own.powerups?.includes('horn')?h('button',{id:'use-horn',class:'resource-button',disabled:busy||!own.hornUses||game.status!=='playing','aria-label':`Horn des Tiefenrufs · ${own.hornUses||0} Verwendungen`,title:'Horn des Tiefenrufs · 10 Sekunden Monsterblick',onclick:onHorn},'📯',h('span',{},own.hornUses||0)):null,
   own.powerups?.includes('binocular')?h('span',{class:'score-vision',title:'Fernglas · dauerhaft drei Felder Sicht'},'🔭 3'):game.settings.fog?h('span',{class:'score-vision',title:'Zwei Felder Sicht'},'☁ 2'):null]);
  const taskKey=[game.tasks,own.reached,game.visibleCells,game.roundRequirements,game.status];
  tasks.hidden=!['special','custom'].some(key=>game.tasks?.[key]?.enabled);
  renderSection(tasks,taskKey,()=>['special','custom'].filter(key=>game.tasks?.[key]?.enabled).map(key=>{
   const t=game.tasks[key];return h('button',{type:'button',class:`task-progress ${t.completed?'complete':''} ${t.blocked?'blocked':''}`,'data-task':key,'aria-label':`Bonusaufgabe ${key==='special'?1:2} ansehen`,onclick:()=>showTask(key)},...taskBody(game,key));
  }));
  if(detail)renderSection(detail.content,taskKey,()=>taskBody(game,detail.key,true));
  const waitingPlayers=game.participants.filter(p=>p.active&&(waitingKind==='roll'?p.id===game.rollerId&&!p.eliminated:((!p.eliminated&&!p.turnDone)||p.hasPendingPowerup))),canTransfer=waitingKind!=='roll'||game.participants.some(p=>p.active&&!p.eliminated&&p.id!==game.rollerId);
  renderSection(wait,[waitingKind,waitingPlayers.map(p=>[p.id,p.displayName,p.hasPendingPowerup]),canTransfer,busy],()=>[
   h('p',{},waitingKind==='roll'?'Der Wurf lässt auf sich warten.':'Noch nicht alle haben gezogen.'),...waitingPlayers.map(p=>h('div',{class:'wait-player','data-player-id':p.id},h('strong',{},p.displayName+(p.hasPendingPowerup?' · Powerup offen':'')),h('div',{class:'button-row'},
    canTransfer?h('button',{class:'button secondary',disabled:busy,onclick:()=>onResolveWait(p.id,'skip')},waitingKind==='roll'?'Wurf weitergeben':'Zug überspringen'):null,p.id!==profile.id?h('button',{class:'text-button',disabled:busy,onclick:()=>onResolveWait(p.id,'remove')},'Entfernen'):null))),
   h('button',{class:'text-button',onclick:()=>{waitUntil=Date.now()+30000;tick();}},'Weiter warten')]);
  tick();
 }
 const clock=setInterval(tick,1000);
 return {element,overlay,lives,score,tasks,update,cleanup(){closed=true;clearInterval(clock);detail?.dialog.close();}};
}
