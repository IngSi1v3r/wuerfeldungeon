import {diceCombinations,ENEMY_TYPES,activeAttacks} from './rules.js';

// Ein-Runden-Heuristik: kein Suchbaum, keine simulierten zukünftigen Würfe.
// Die Eingabe enthält ausschließlich die für diesen Spieler sichtbaren Räume.
const id=value=>String(value),num=value=>Number(value)||0;
const probabilities=new Map();
export function requirementProbability(requirements,red=false){
 const req=[...new Set(requirements.map(String))].sort(),key=JSON.stringify([req,red]);
 if(probabilities.has(key))return probabilities.get(key);
 let matches=0,total=0;
 for(let a=1;a<=6;a++)for(let b=1;b<=6;b++)for(let c=1;c<=6;c++)for(let d=1;d<=(red?6:1);d++){
  total++;if(diceCombinations([a,b,c,d],red,true).some(n=>req.includes(n)))matches++;
 }
 const result=matches/total;probabilities.set(key,result);return result;
}
function graphOf(definition){
 const rooms=new Map(definition.document.rooms.map(r=>[id(r.id),r])),edges=new Map();
 for(const [rawA,rawB] of [...(Array.isArray(definition.graph)?definition.graph:definition.graph?.edges||[]),...(definition.rules?.portalPairs||[])]){
  const a=id(rawA),b=id(rawB);if(!rooms.has(a)||!rooms.has(b))continue;
  if(!edges.has(a))edges.set(a,new Set());if(!edges.has(b))edges.set(b,new Set());edges.get(a).add(b);edges.get(b).add(a);
 }return {rooms,edges};
}
function hash(text){let n=2166136261;for(const c of text)n=Math.imul(n^c.charCodeAt(0),16777619);return (n>>>0)/4294967296;}
function claimedReward(room,context){
 const claim=(context.claims||[]).find(c=>id(c.cellId)===id(room.id));
 return num(claim&&claim.claimedInRound<context.round?room.rewardLater:room.rewardFirst);
}
export function choosePowerup(context){
 const s=context.state,rooms=context.definition.document.rooms,remaining=rooms.filter(r=>ENEMY_TYPES.has(r.type)&&!s.reached?.map(id).includes(id(r.id))).reduce((n,r)=>n+Math.max(0,num(r.hits)-num(s.monsterHits?.[id(r.id)])),0);
 const scores={
  extraLife:5+Math.min(12,num(s.lostLives)*1.8),
  torch:9+Math.min(3,rooms.filter(r=>!ENEMY_TYPES.has(r.type)).length/12),
  axe:remaining>3?10:4,
  redDice:num(s.redUses)<2?10:7,
  binocular:context.fog?7:0,horn:context.fog?3:0
 };
 return [...(context.availablePowerups||[])].sort((a,b)=>(scores[b]||0)-(scores[a]||0)||a.localeCompare(b))[0]||null;
}
export function chooseAiAction(context){
 if(context.pendingChest)return {kind:'powerup',powerup:choosePowerup(context)};
 if(!context.canAct)return null;
 const s=context.state,reached=new Set((s.reached||[]).map(id)),{rooms,edges}=graphOf(context.definition);
 const goals=context.definition.rules?.goals||[],goalIds=new Set(goals.filter((g,i)=>g.type!=='none'&&!context.tasks?.[i?'custom':'special']?.completed&&!context.tasks?.[i?'custom':'special']?.blocked).flatMap(g=>g.cellIds||[]).map(id));
 const enemies=[...rooms.values()].filter(r=>['monster','boss','miniboss'].includes(r.type)&&!reached.has(id(r.id)));
 if(context.fog&&num(s.hornUses)>0&&!enemies.length&&!(Date.parse(s.hornUntil||'')>Date.now()))return {kind:'horn'};
 function requirements(r){return ENEMY_TYPES.has(r.type)?activeAttacks(r,context.definition.rules,s):r.type==='crazy'?[context.roundRequirements?.[id(r.id)]].filter(Boolean):[r.type==='doubleSum'?`doubles:${r.number}`:r.number].filter(n=>n!=null);}
 function targetValue(r){
  if(reached.has(id(r.id)))return 0;
  if(ENEMY_TYPES.has(r.type))return 10+3*claimedReward(r,context);
  return ({diamond:10,chest:11,rune:8,goldSack:6,goldCoin:4,portal:7})[r.type]|| (goalIds.has(id(r.id))?7:0);
 }
 function proximity(from){
  const queue=[[from,0]],seen=new Set([from]);let best=0;
  for(let i=0;i<queue.length;i++){
   const [at,dist]=queue[i];if(dist>0)best=Math.max(best,targetValue(rooms.get(at))/(1+dist));
   for(const to of edges.get(at)||[])if(!seen.has(to)){
    seen.add(to);const r=rooms.get(to),cost=ENEMY_TYPES.has(r.type)&&!reached.has(to)?Math.max(1,num(r.hits)-num(s.monsterHits?.[to])):1;
    queue.push([to,dist+cost]);
   }
  }return best;
 }
 function roomValue(r,axe=false){
  if(!r||reached.has(id(r.id)))return 0;
  let value=1;
  if(ENEMY_TYPES.has(r.type)){
   const left=Math.max(1,num(r.hits)-num(s.monsterHits?.[id(r.id)])),hits=Math.min(left,axe?2:1),reward=claimedReward(r,context);
   value=5+hits*(3+3*reward/Math.max(1,num(r.hits)));
   if(left<=hits)value+=10+3*reward+(enemies.length===1&&r.type!=='bonus'?5:0);
  }else{
   value+=({diamond:10,goldSack:6,goldCoin:3,chest:9,portal:5})[r.type]||0;
   const fresh=[...(edges.get(id(r.id))||[])].filter(n=>!reached.has(n));
   value+=Math.min(4,fresh.length)*1.2+proximity(id(r.id));
   if(r.type==='rune'){
    const hits=(context.definition.rules?.bossHits||[]).filter(u=>id(u.sourceCellId)===id(r.id));
    for(const u of hits){const boss=rooms.get(id(u.targetCellId));if(boss&&!reached.has(id(boss.id)))value+=Math.min(num(u.hits),num(boss.hits)-num(s.monsterHits?.[id(boss.id)]))*4;}
   }
   value+=(context.definition.rules?.unlocks||[]).filter(u=>id(u.sourceCellId)===id(r.id)&&!reached.has(id(u.targetCellId))).length*3;
   if(r.type==='trap'&&(context.traps||[]).some(t=>id(t.cellId)===id(r.id)&&t.armed))value-=r.trapKind==='diamonds'?num(r.trapCost)*3:num(r.trapCost)*(num(s.lostLives)>5?6:2);
  }
  if(goalIds.has(id(r.id)))value+=4;
  // Seltene, gerade verfügbare Kombinationen nutzen: lokale Gelegenheit,
  // nicht ein hypothetischer vorausgeplanter Wurf.
  value+=(1-requirementProbability(requirements(r),context.freeRed))*2;
  return value;
 }
 const candidates=[];
 for(const a of [...(context.actions||[]),...(context.torchActions||[])]){
  const room=rooms.get(id(a.cellId));if(!room)continue;
  for(const axe of ENEMY_TYPES.has(room.type)&&num(s.axeUses)>0&&!a.middleCellId&&num(room.hits)-num(s.monsterHits?.[id(room.id)])>1?[false,true]:[false]){
   const score=roomValue(room,axe)+(a.middleCellId?roomValue(rooms.get(id(a.middleCellId)))*.85-3:0)-(a.redOnly?2:0)-(axe?2:0);
   candidates.push({kind:'cell',cellId:id(a.cellId),middleCellId:a.middleCellId?id(a.middleCellId):null,useRed:Boolean(a.redOnly),useAxe:axe,score});
  }
 }
 candidates.sort((a,b)=>b.score-a.score||hash(`${context.playerId}:${context.round}:${a.cellId}:${a.middleCellId}`)-hash(`${context.playerId}:${context.round}:${b.cellId}:${b.middleCellId}`));
 return candidates[0]|| (context.canLoseLife?{kind:'lose_life'}:null);
}
