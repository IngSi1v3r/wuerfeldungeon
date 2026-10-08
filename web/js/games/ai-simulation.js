import {ENEMY_TYPES,activeAttacks,diceCombinations,lifePenalty} from './rules.js';
import {visibleCells} from './visibility.js';
export const sid=String;
export const number=v=>Number(v)||0;
export function createModel(context){
 const definition=context.definition,rooms=new Map(definition.document.rooms.map(r=>[sid(r.id),r])),edges=new Map(),portals=new Map();
 const links=Array.isArray(definition.graph)?definition.graph:definition.graph?.edges||[];
 for(const [a,b] of links){for(const [x,y] of [[sid(a),sid(b)],[sid(b),sid(a)]]){if(!rooms.has(x)||!rooms.has(y))continue;if(!edges.has(x))edges.set(x,new Set());edges.get(x).add(y);}}
 for(const [a,b] of definition.rules?.portalPairs||[]){portals.set(sid(a),sid(b));portals.set(sid(b),sid(a));if(rooms.has(sid(a))&&rooms.has(sid(b)))for(const [x,y] of [[sid(a),sid(b)],[sid(b),sid(a)]]){if(!edges.has(x))edges.set(x,new Set());edges.get(x).add(y);}}
 return {context,definition,rooms,edges,portals,claims:new Map((context.claims||[]).map(c=>[sid(c.cellId),number(c.claimedInRound)])),traps:new Map((context.traps||[]).map(c=>[sid(c.cellId),c.activatedInRound??(c.armed?context.round-1:context.round)])),goals:definition.rules?.goals||[]};
}
export function cloneState(s={}){return {...s,reached:[...(s.reached||[])].map(sid),monsterHits:{...s.monsterHits},powerups:[...(s.powerups||[])],pendingChests:[...(s.pendingChests||[])],firstKills:[...(s.firstKills||[])].map(sid),taskRewards:{...s.taskRewards},taskCompletionRounds:{...s.taskCompletionRounds},enemyCompletionRounds:{...s.enemyCompletionRounds},_trapRounds:{...s._trapRounds}};}
export function remainingHits(room,state){return Math.max(0,number(room.hits)-number(state.monsterHits?.[sid(room.id)]));}
export function simulationFinished(model,state){
 const enemies=[...model.rooms.values()].filter(r=>['monster','boss','miniboss'].includes(r.type)),count=model.context.mandatoryCount??(model.context.fog?Infinity:enemies.length);
 return count>0&&enemies.length>=count&&enemies.every(r=>state.reached.includes(sid(r.id)));
}
export function rewardFor(model,room,round){return number(room[model.claims.has(sid(room.id))&&model.claims.get(sid(room.id))<round?'rewardLater':'rewardFirst']);}
export function freeRedAt(model,round){const c=model.context;if(!c.redEvery)return Boolean(c.freeRed);return (round-1)%c.redEvery===number(c.seat)%c.redEvery;}
export function requirementsFor(model,room,state,requirements={}){
 if(ENEMY_TYPES.has(room.type))return activeAttacks(room,model.definition.rules,state);
 if(room.type==='crazy')return requirements[sid(room.id)]==null?[]:[sid(requirements[sid(room.id)])];
 return room.number==null?[]:[room.type==='doubleSum'?`doubles:${room.number}`:sid(room.number)];
}
export function reachable(model,state,cellId){const reached=new Set(state.reached),room=model.rooms.get(sid(cellId));return Boolean(room&&!reached.has(sid(cellId))&&(room.start&&!['monster','boss','miniboss'].includes(room.type)||[...(model.edges.get(sid(cellId))||[])].some(n=>reached.has(n))));}
function previewReach(model,state,id){const s=cloneState(state);id=sid(id);if(!s.reached.includes(id))s.reached.push(id);const other=model.portals.get(id);if(other&&!s.reached.includes(other))s.reached.push(other);return s;}
export function legalActions(model,state,dice,round,requirements={}){
 if(number(state.lostLives)>=11+number(state.extraLives))return [];
 const normal=new Set(diceCombinations(dice,freeRedAt(model,round),true)),red=new Set(number(state.redUses)>0?diceCombinations(dice,true,true):[]),result=[];
 const seen=model.context.fog?new Set(visibleCells(model.definition,state)):null;
 function add(room,s,middle=null){if(seen&&!seen.has(sid(room.id)))return;const req=requirementsFor(model,room,s,requirements),regular=req.some(n=>normal.has(n)),special=req.some(n=>red.has(n));if(!regular&&!special)return;
  const a={kind:'cell',cellId:sid(room.id),middleCellId:middle,useRed:!regular,useAxe:false};result.push(a);
  if(!middle&&ENEMY_TYPES.has(room.type)&&remainingHits(room,state)>1&&number(state.axeUses)>0)result.push({...a,useAxe:true});
 }
 for(const room of model.rooms.values())if(reachable(model,state,room.id))add(room,state);
 if(number(state.torchUses)>0)for(const middle of model.rooms.values())if(!ENEMY_TYPES.has(middle.type)&&reachable(model,state,middle.id)){
  const temporary=previewReach(model,state,middle.id),fresh=temporary.reached.filter(n=>!state.reached.includes(n));
  for(const room of model.rooms.values())if(!temporary.reached.includes(sid(room.id))&&fresh.some(n=>model.edges.get(n)?.has(sid(room.id))))add(room,temporary,sid(middle.id));
 }
 // Rote Würfel und Fackeln sind freiwillig. Nur ein kostenloser direkter Zug
 // verhindert die Alternative, ein Leben zu verlieren.
 if(!result.some(a=>!a.useRed&&!a.middleCellId))result.push({kind:'lose_life'});
 return result;
}
export function applyPowerup(state,powerup){const s=cloneState(state);if(!powerup||s.powerups.includes(powerup))return s;s.powerups.push(powerup);s.pendingChests.shift();
 if(powerup==='extraLife'){s.extraLives=number(s.extraLives)+3;s.diamonds=number(s.diamonds)+1;}
 if(powerup==='redDice')s.redUses=number(s.redUses)+3;if(powerup==='torch')s.torchUses=number(s.torchUses)+2;if(powerup==='axe')s.axeUses=number(s.axeUses)+2;if(powerup==='horn')s.hornUses=number(s.hornUses)+1;return s;}
export function availablePowerups(model,state){return (model.context.availablePool||model.definition.allowedPowerups||['extraLife','redDice','torch']).filter(p=>!state.powerups.includes(p)&&(!['binocular','horn'].includes(p)||model.context.fog));}
export function taskProgress(model,state,goal,round){
 const ids=(goal.cellIds||[]).map(sid),need=goal.requiredCount??ids.length,reached=new Set(state.reached),key=goal===model.goals[0]?'special':'custom';
 if(goal.type==='none'||!goal.type)return {progress:0,total:0,completed:false,blocked:false};
 if(goal.type==='collectDiamonds'){const total=number(goal.diamonds);return {progress:Math.max(0,number(state.diamonds)),total,completed:number(state.diamonds)>=total,blocked:false};}
 const completed=ids.filter(id=>reached.has(id)&&(goal.type!=='firstEnemies'||state.firstKills.includes(id))),blocked=goal.type==='firstEnemies'&&ids.filter(id=>state.firstKills.includes(id)||!model.claims.has(id)||model.claims.get(id)>=round).length<need;
 if(goal.type==='connect'){
  const queue=reached.has(ids[0])?[ids[0]]:[],seen=new Set(queue);for(let i=0;i<queue.length;i++)for(const n of model.edges.get(queue[i])||[])if(reached.has(n)&&!seen.has(n)){seen.add(n);queue.push(n);}
  return {progress:completed.length,total:2,completed:ids.length===2&&seen.has(ids[1]),blocked:false};
 }
 return {progress:Math.min(completed.length,need),total:need,completed:need>0&&!blocked&&completed.length>=need,blocked:blocked||Boolean(model.context.tasks?.[key]?.blocked)};
}
export function applyAction(model,state,action,round){
 let s=cloneState(state);const add=id=>{s=previewReach(model,s,id);};
 const hit=(room,hits)=>{const id=sid(room.id);if(s.reached.includes(id))return;s.monsterHits[id]=Math.min(number(room.hits),number(s.monsterHits[id])+hits);
  if(s.monsterHits[id]===number(room.hits)){add(id);s.diamonds=number(s.diamonds)+rewardFor(model,room,round);s.enemyCompletionRounds[id]=round;if(!model.claims.has(id)||model.claims.get(id)>=round)s.firstKills.push(id);}
 };
 const reach=room=>{const id=sid(room.id);if(s.reached.includes(id))return;add(id);
  if(room.type==='diamond')s.diamonds=number(s.diamonds)+1;
  if(room.type==='goldSack'||room.type==='goldCoin')s.goldPoints=number(s.goldPoints)+(room.type==='goldSack'?2:1);
  if(room.type==='chest')s.pendingChests.push(id);
  if(room.type==='trap'){
   const armedAt=model.traps.get(id)??s._trapRounds[id];s._trapRounds[id]=armedAt??round;
   if(armedAt!=null&&armedAt<round){const k=room.trapKind==='life'?'lostLives':'diamonds';s[k]=number(s[k])+(k==='diamonds'?-1:1)*number(room.trapCost);}
  }
  if(room.type==='rune')for(const effect of model.definition.rules?.bossHits||[])if(sid(effect.sourceCellId)===id){const boss=model.rooms.get(sid(effect.targetCellId));if(boss)hit(boss,number(effect.hits));}
 };
 if(action.kind==='lose_life')s.lostLives=number(s.lostLives)+1;
 else if(action.kind==='cell'){
  if(action.middleCellId){s.torchUses=number(s.torchUses)-1;reach(model.rooms.get(sid(action.middleCellId)));}
  if(action.useRed)s.redUses=number(s.redUses)-1;if(action.useAxe)s.axeUses=number(s.axeUses)-1;
  const room=model.rooms.get(sid(action.cellId));if(ENEMY_TYPES.has(room.type))hit(room,action.useAxe?2:1);else reach(room);
  for(let pass=0;pass<2;pass++)for(const [i,goal] of model.goals.entries()){
   const key=i?'custom':'special';if(Object.hasOwn(s.taskRewards,key)||!taskProgress(model,s,goal,round).completed)continue;
   const claim=model.context.taskClaims?.find(c=>c.key===key),first=claim?number(claim.completedInRound)>=round:model.context.tasks?.[key]?.firstAvailable!==false;
   const reward=number(goal.reward?.[first?'first':'later']);s.diamonds=number(s.diamonds)+reward;s.taskRewards[key]=reward;s.taskCompletionRounds[key]=round;
  }
 }
 return s;
}
export function bossGroupDiamonds(model,state){let n=0;for(const room of model.rooms.values())if(['boss','miniboss'].includes(room.type)&&!state.firstKills?.includes(sid(room.id)))n+=Math.floor(number(state.monsterHits?.[sid(room.id)])/3);return n;}
export const simulatedPoints=(model,state)=>number(state.diamonds)*3+number(state.goldPoints)+lifePenalty(state)+bossGroupDiamonds(model,state)*3;
