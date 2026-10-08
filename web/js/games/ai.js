import {ENEMY_TYPES} from './rules.js';
import {visibleCells} from './visibility.js';
import {adventurerCharacter,ADVENTURER_VERSION} from './adventurers.js';
import {createModel,cloneState,requirementsFor,remainingHits,rewardFor,freeRedAt,legalActions,applyAction,applyPowerup,availablePowerups,taskProgress,simulatedPoints,simulationFinished,sid,number} from './ai-simulation.js';
import {diceCombinations} from './rules.js';

// Begrenzte Erwartungswertsuche: aktueller Zug plus zwei Folgerunden. Alle
// aktuellen Kandidaten erhalten dieselben zufällig gezogenen Zukunftswürfe.
// Die zweite Runde ist beim Auswählen der ersten noch unbekannt: erst mitteln,
// dann den besten ersten Zug wählen (keine hellseherische Würfelfolge).
const probabilities=new Map(),outcomes=new Map();
export function requirementProbability(requirements,red=false){
 const req=[...new Set(requirements.map(String))].sort(),key=JSON.stringify([req,red]);if(probabilities.has(key))return probabilities.get(key);
 if(!outcomes.has(red)){const list=[];for(let a=1;a<=6;a++)for(let b=1;b<=6;b++)for(let c=1;c<=6;c++)for(let d=1;d<=(red?6:1);d++)list.push(diceCombinations([a,b,c,d],red,true));outcomes.set(red,list);}
 const list=outcomes.get(red),result=list.filter(values=>values.some(n=>req.includes(n))).length/list.length;probabilities.set(key,result);return result;
}
export function seededRandom(text){let h=2166136261;for(const c of String(text))h=Math.imul(h^c.charCodeAt(0),16777619);return ()=>{h+=0x6d2b79f5;let t=h;t=Math.imul(t^t>>>15,t|1);t^=t+Math.imul(t^t>>>7,t|61);return ((t^t>>>14)>>>0)/4294967296;};}
export const actionKey=a=>a?`${a.kind}:${a.cellId||''}:${a.middleCellId||''}:${Boolean(a.useRed)}:${Boolean(a.useAxe)}:${a.powerup||''}`:'';
const rounded=v=>Math.round(v*1000)/1000;
export function choosePowerup(context){
 const s=context.state,rooms=context.definition.document.rooms,remaining=rooms.filter(r=>ENEMY_TYPES.has(r.type)&&!s.reached?.map(sid).includes(sid(r.id))).reduce((n,r)=>n+remainingHits(r,s),0),w=adventurerCharacter(context.character).weights;
 const scores={extraLife:(5+Math.min(12,number(s.lostLives)*1.8))*w.safety,torch:(9+Math.min(3,rooms.filter(r=>!ENEMY_TYPES.has(r.type)).length/12))*w.exploration,axe:(remaining>3?10:4)*w.combat,redDice:(number(s.redUses)<2?10:7)*w.resources,binocular:context.fog?8*w.exploration:0,horn:context.fog?4*w.exploration:0};
 return [...(context.availablePowerups||[])].sort((a,b)=>(scores[b]||0)-(scores[a]||0)||a.localeCompare(b))[0]||null;
}
function resolveChests(model,state){let s=state;for(let i=0;i<8&&s.pendingChests.length;i++){const options=availablePowerups(model,s);if(!options.length){s={...s,pendingChests:[]};break;}s=applyPowerup(s,choosePowerup({...model.context,state:s,availablePowerups:options}));}return s;}
function evaluate(model,state,round,character){
 const w=character.weights,reached=new Set(state.reached),left=[...model.rooms.values()].filter(r=>!reached.has(sid(r.id))),enemies=left.filter(r=>['monster','boss','miniboss'].includes(r.type)),cache=model.evalCache;
 const key=JSON.stringify([state.reached,state.monsterHits,state.diamonds,state.goldPoints,state.lostLives,state.extraLives,state.redUses,state.torchUses,state.axeUses,state.powerups,state.firstKills,state.taskRewards,round]);if(cache.has(key))return cache.get(key);
 // Erwartete Wegkosten statt Luftlinie. Bereits erkundete Felder kosten null;
 // seltene Zahlen und mehrere Treffer machen eine Strecke langsamer.
 const dist=new Map(),pending=new Set(model.rooms.keys());for(const r of model.rooms.values())if(reached.has(sid(r.id))||r.start&&!['monster','boss','miniboss'].includes(r.type))dist.set(sid(r.id),reached.has(sid(r.id))?0:1);
 while(pending.size){let at=null,best=Infinity;for(const n of pending)if((dist.get(n)??Infinity)<best){at=n;best=dist.get(n);}if(at===null)break;pending.delete(at);
  for(const to of model.edges.get(at)||[]){if(!pending.has(to))continue;const room=model.rooms.get(to),req=room.type==='crazy'?room.requirements||[]:requirementsFor(model,room,state,model.context.roundRequirements);
   const probability=Math.max(.12,requirementProbability(req,freeRedAt(model,round+1))),cost=reached.has(to)?0:(ENEMY_TYPES.has(room.type)?Math.max(1,remainingHits(room,state)):1)/probability;
   if(best+cost<(dist.get(to)??Infinity))dist.set(to,best+cost);
  }
 }
 let combat=0,exploration=reached.size*.38,goals=0,contest=0;
 for(const room of model.rooms.values()){
  const id=sid(room.id);if(ENEMY_TYPES.has(room.type)){const progress=Math.min(number(room.hits),number(state.monsterHits[id]));combat+=(room.type==='bonus'?.65:1)*(progress*3+(reached.has(id)?13:0));}
 }
 if(enemies.length===0&&model.rooms.size&&!model.context.fog)combat+=16;
 for(const room of left){const id=sid(room.id),reward=ENEMY_TYPES.has(room.type)?8+3*rewardFor(model,room,round):({diamond:9,goldSack:6,goldCoin:3,chest:10,portal:6,rune:5})[room.type]||0;
  exploration+=reward*.8/(1+(dist.get(id)??1000));
 }
 const frontier=left.filter(r=>r.start||[...(model.edges.get(sid(r.id))||[])].some(n=>reached.has(n)));
 exploration+=Math.min(5,frontier.length)*.65;
 if(model.context.fog)exploration+=visibleCells(model.definition,state).length*.15;
 for(const [i,goal] of model.goals.entries()){const key=i?'custom':'special',t=taskProgress(model,state,goal,round);if(!t.total||t.blocked||Object.hasOwn(state.taskRewards,key))continue;
  goals+=(3+3*number(goal.reward?.first))*.6*Math.min(1,t.progress/t.total);
 }
 // Der Rivale erhält nur bei offenen Karten fremde Fortschritte. Eine
 // Erstbelohnung kann in derselben Runde geteilt werden, niemals gestohlen.
 for(const room of model.rooms.values())if(ENEMY_TYPES.has(room.type)){
  const id=sid(room.id),others=(model.context.opponents||[]).filter(o=>!o.state.reached?.map(sid).includes(id)),threat=others.reduce((n,o)=>Math.max(n,number(o.state.monsterHits?.[id])/Math.max(1,number(room.hits))),0);
  if(threat>0&&number(room.rewardFirst)>number(room.rewardLater)&&(!model.claims.has(id)||model.claims.get(id)>=round))contest+=threat*(reached.has(id)?5:Math.min(4,number(state.monsterHits[id])*1.1));
 }
 const lost=Math.max(0,number(state.lostLives)-number(state.extraLives)),alive=number(state.lostLives)<11+number(state.extraLives),safety=-number(state.lostLives)*.65-Math.max(0,lost-4)**2*.55+(alive?0:-180);
 const resources=number(state.redUses)*1.8+number(state.torchUses)*3.1+number(state.axeUses)*2.6+number(state.extraLives)*.7+(state.powerups.includes('binocular')&&model.context.fog?2:0);
 const parts={points:simulatedPoints(model,state)*w.points,combat:combat*w.combat,exploration:exploration*w.exploration,goals:goals*w.goals,safety:safety*w.safety,resources:resources*w.resources,contest:contest*w.contest};
 const value=Object.values(parts).reduce((n,v)=>n+v,0),answer={value,parts};cache.set(key,answer);return answer;
}
function rootActions(context,model){const s=context.state,candidates=[];
 for(const a of [...(context.actions||[]),...(context.torchActions||[])]){
  const room=model.rooms.get(sid(a.cellId));if(!room||s.reached?.map(sid).includes(sid(a.cellId))||a.middleCellId&&!model.rooms.has(sid(a.middleCellId)))continue;
  const base={kind:'cell',cellId:sid(a.cellId),middleCellId:a.middleCellId==null?null:sid(a.middleCellId),useRed:Boolean(a.redOnly),useAxe:false};candidates.push(base);
  if(!a.middleCellId&&ENEMY_TYPES.has(room.type)&&remainingHits(room,s)>1&&number(s.axeUses)>0)candidates.push({...base,useAxe:true});
 }
 if(context.canLoseLife&&!candidates.some(a=>!a.useRed&&!a.middleCellId))candidates.push({kind:'lose_life'});
 return [...new Map(candidates.map(a=>[actionKey(a),a])).values()];
}
function sampleFuture(model,random,round){const requirements={};for(const room of model.rooms.values())if(room.type==='crazy'&&room.requirements?.length)requirements[sid(room.id)]=room.requirements[Math.floor(random()*room.requirements.length)];return {dice:Array.from({length:4},()=>1+Math.floor(random()*6)),requirements,round};}
export function analyzeAiTurn(context,{depth=2,samples=null,beam=3}={}){
 const character=adventurerCharacter(context.character),base={version:ADVENTURER_VERSION,character:character.id,round:context.round,playerId:context.playerId,depth:0,candidates:[],selected:null,knownRooms:context.definition?.document.rooms.length||0};
 if(context.pendingChest){const action={kind:'powerup',powerup:choosePowerup(context)};return {...base,action,selected:actionKey(action)};}
 if(!context.canAct)return {...base,action:null};
 const model=createModel(context);model.evalCache=new Map();const state=cloneState(context.state),roots=rootActions(context,model);
 if(context.fog&&number(state.hornUses)>0&&!(Date.parse(state.hornUntil||'')>Date.now())&&![...model.rooms.values()].some(r=>['monster','boss','miniboss'].includes(r.type)&&!state.reached.includes(sid(r.id)))){const action={kind:'horn'};return {...base,action,selected:actionKey(action)};}
 if(!roots.length)return {...base,action:null};
 const round=number(context.round)||1,initial=evaluate(model,state,round,character),random=seededRandom(`${context.gameId||''}:${context.playerId}:${round}:v${ADVENTURER_VERSION}`),count=samples??Math.max(3,Math.min(8,Math.floor(96/roots.length))),secondCount=3;
 const future=Array.from({length:count},()=>({first:sampleFuture(model,random,round+1),second:Array.from({length:secondCount},()=>sampleFuture(model,random,round+2))}));
 depth=Math.max(0,Math.min(2,depth));beam=Math.max(1,Math.min(8,beam));let evaluated=0;
 const rank=(s,draw)=>simulationFinished(model,s)?[{state:s,value:evaluate(model,s,draw.round,character).value,key:'finished'}]:legalActions(model,s,draw.dice,draw.round,draw.requirements).map(action=>{const next=resolveChests(model,applyAction(model,s,action,draw.round));evaluated++;return {state:next,value:evaluate(model,next,draw.round,character).value,key:actionKey(action)};}).sort((a,b)=>b.value-a.value||a.key.localeCompare(b.key));
 const candidates=roots.map(action=>{
  const after=resolveChests(model,applyAction(model,state,action,round)),now=evaluate(model,after,round,character),parts=Object.fromEntries(Object.keys(initial.parts).map(k=>[k,rounded(now.parts[k]-initial.parts[k])]));
  let expected=now.value;
  if(depth>0&&!simulationFinished(model,after))expected=future.reduce((sum,scenario)=>{
   const first=rank(after,scenario.first).slice(0,beam);if(!first.length)return sum+evaluate(model,after,scenario.first.round,character).value;
   let best=-Infinity;for(const choice of first){let val=choice.value;if(depth===2)val=scenario.second.reduce((n,draw)=>{const options=rank(choice.state,draw);return n+(options[0]?.value??evaluate(model,choice.state,draw.round,character).value);},0)/secondCount;best=Math.max(best,val);}return sum+best;
  },0)/future.length;
  const room=model.rooms.get(action.cellId),rarity=room?1.4*(1-requirementProbability(requirementsFor(model,room,state,context.roundRequirements),context.freeRed)):0,noise=(seededRandom(`${context.playerId}:${round}:${actionKey(action)}:luck`)()-.5)*2*character.weights.noise;
  const immediate=now.value-initial.value,forecast=(expected-now.value)*.8,score=immediate+forecast+rarity+noise;
  return {...action,key:actionKey(action),score:rounded(score),immediate:rounded(immediate),forecast:rounded(forecast),opportunity:rounded(rarity),noise:rounded(noise),parts};
 }).sort((a,b)=>b.score-a.score||a.key.localeCompare(b.key));
 const selected=candidates[0],action=selected?{kind:selected.kind,cellId:selected.cellId,middleCellId:selected.middleCellId,useRed:selected.useRed,useAxe:selected.useAxe,score:selected.score}:null;
 return {...base,depth,samples:count,secondSamples:secondCount,beam,evaluated,candidates,selected:selected?.key||null,action,dice:context.dice||null,note:'Stichproben aus zwei Folgerunden; verdeckte Felder und verdeckte Gegnerfortschritte bleiben unbekannt.'};
}
export function chooseAiAction(context){return analyzeAiTurn(context).action;}
