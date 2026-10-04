import {connections} from './model.js';

export const FORMAT='dungeon-layout-v7';
export const TYPES=Object.freeze({normal:'Wegfeld',doubleSum:'Bestimmter Pasch',diamond:'Diamant',chest:'Schatzkiste',rune:'Runenfeld',monster:'Monster',boss:'Boss',bonus:'Bonusaufgabe',trap:'Falle',portal:'Portal',crazy:'Verrücktes Feld',goldSack:'Goldsack',goldCoin:'Goldmünze'});
export const GOALS=Object.freeze({none:'Keine Aufgabe',allType:'Felder einer Art erreichen',reachFields:'Bestimmte Felder erreichen',defeatEnemies:'Gegnerkombination besiegen',firstEnemies:'Einzelne Gegner jeweils als Erste besiegen',connect:'Zwei Felder durchgehend verbinden',collectDiamonds:'Diamanten sammeln'});
export const goalDefault=()=>({type:'none',fieldType:'rune',cellIds:[],requiredCount:null,diamonds:3,reward:{first:3,later:1}});
export const newRules=()=>({version:2,unlocks:[],goals:[{...goalDefault(),type:'allType'},goalDefault()]});
export const numberLabel=n=>n==='doubles'?'Pasch':String(n??'–');
export const cellLabel=r=>`${r.name || TYPES[r.type] || r.type} #${r.id} · ${r.type==='doubleSum'&&r.number!=null?`${r.number} (${r.number/2}+${r.number/2})`:numberLabel(r.number)}`;
export const COUNT_GOALS=new Set(['allType','reachFields','defeatEnemies','firstEnemies']);
export function goalTargetIds(g,rooms=[]){return g.type==='allType'?rooms.filter(r=>r.type===g.fieldType).map(r=>r.id):g.cellIds||[];}
export function goalRequiredCount(g,rooms=[]){return COUNT_GOALS.has(g.type)&&g.requiredCount!=null?g.requiredCount:goalTargetIds(g,rooms).length;}

// Only drafts are upgraded. Published versions retain their original semantics.
export function upgradeDocument(raw) {
  const d=structuredClone(raw);
  if(d.format===FORMAT)return compileDocument(d);
  d.format=FORMAT;
  for(const r of d.rooms){if(r.type==='special')r.type='rune';if(r.type==='miniboss')r.type='bonus';}
  const previous=d.rules;
  d.rules=newRules();
  if(previous?.customGoal)d.rules.goals[1]={...goalDefault(),...previous.customGoal,reward:{first:3,later:1}};
  d.allowedPowerups??=['extraLife','redDice','torch'];
  return compileDocument(d);
}

export function compileDocument(raw) {
  const d=structuredClone(raw);
  if(d.format!==FORMAT)return d;
  d.rules??=newRules();
  const edges=connections(d),unlocks=[];
  for(const source of d.rooms){
    if(source.number==null || !(source.type==='rune'||source.type==='normal'&&source.dimmed))continue;
    for(const target of d.rooms){
      const linked=source.type==='rune'?target.type==='boss':['monster','boss'].includes(target.type)&&edges.some(e=>e.includes(String(source.id))&&e.includes(String(target.id)));
      if(!linked)continue;
      target.attacks??=[];
      let attack=target.attacks.find(a=>a.number===source.number);
      if(!attack){attack={number:source.number,state:'locked'};target.attacks.push(attack);}
      attack.state='locked';target.attacks.sort((a,b)=>(a.number==='doubles'?13:a.number)-(b.number==='doubles'?13:b.number));
      unlocks.push({sourceCellId:source.id,targetCellId:target.id,number:source.number});
    }
  }
  d.rules.unlocks=unlocks;
  for(const g of d.rules.goals || [])if(g.type==='allType')g.cellIds=d.rooms.filter(r=>r.type===g.fieldType).map(r=>r.id);
  d.rules.portalPairs=[];
  const portals=d.rooms.filter(r=>r.type==='portal'&&r.number!=null);
  for(const a of portals)for(const b of portals)if(a.id<b.id&&a.number===b.number)d.rules.portalPairs.push([a.id,b.id]);
  return d;
}

export function goalText(g,rooms=[]) {
  if(!g||g.type==='none')return 'Keine Bonusaufgabe';
  const labels=(g.cellIds||[]).map(id=>rooms.find(r=>r.id===id)).filter(Boolean).map(cellLabel);
  const total=goalTargetIds(g,rooms).length,need=goalRequiredCount(g,rooms),subset=COUNT_GOALS.has(g.type)&&g.requiredCount!=null&&need<total;
  if(g.type==='allType')return `${subset?`${need} von ${total}`:'Alle'} ${({normal:'Wegfelder',doubleSum:'Paschfelder',diamond:'Diamantfelder',chest:'Schatzkisten',rune:'Runenfelder',special:'Runenfelder',monster:'Monster',boss:'Bosse',bonus:'Bonusaufgabenfelder',trap:'Fallenfelder',portal:'Portalfelder',crazy:'verrückten Felder',goldSack:'Goldsackfelder',goldCoin:'Goldmünzfelder'})[g.fieldType] || g.fieldType} erreichen`;
  if(g.type==='collectDiamonds')return `${g.diamonds} Diamanten sammeln`;
  if(g.type==='connect')return `Durchgängiger Weg: ${labels.join(' ↔ ')} (Portale zählen mit)`;
  return `${GOALS[g.type]}${subset?` (${need} von ${total})`:''}: ${labels.join(', ')}`;
}
