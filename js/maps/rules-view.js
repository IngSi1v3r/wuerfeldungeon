import {FORMAT,TYPES,GOALS,newRules,cellLabel} from './features.js';
import {h,feedback,setFeedback} from '../dom.js';
import {POWERUPS,ENEMIES,defaultRules} from './model.js';
const numberLabel=n=>n==='doubles'?'Pasch':String(n ?? 'ohne Zahl');
const label=r=>`${r.name || ({special:'X-Feld',normal:'Wegfeld',diamond:'Diamant',chest:'Schatzkiste',monster:'Monster',miniboss:'Mini-Boss',boss:'Boss'})[r.type]} #${r.id}${ENEMIES.includes(r.type)?'':` · ${numberLabel(r.number)}`}`;

function legacyRulesDialog({document:doc,readOnly,onSave}) {
  const rules=structuredClone(doc.rules || defaultRules()),specials=doc.rooms.filter(r=>r.type==='special'),locked=doc.rooms.filter(r=>ENEMIES.includes(r.type)).flatMap(r=>r.attacks.filter(a=>a.state==='locked').map(a=>({r,a}))),message=feedback();
  const powers=Object.entries(POWERUPS).map(([key,name])=>({key,node:h('input',{type:'checkbox',checked:doc.allowedPowerups.includes(key),disabled:readOnly}),name}));
  const unlocks=locked.map(({r,a})=>({r,a,checks:specials.map(s=>({s,input:h('input',{type:'checkbox',disabled:readOnly,checked:rules.unlocks.some(u=>u.targetCellId===r.id&&u.number===a.number&&u.sourceCellId===s.id)})}))}));
  const type=h('select',{id:'custom-goal-type',disabled:readOnly,onchange:renderTargets},...Object.entries({none:'Keine zweite Spezialaufgabe',reachFields:'Bestimmte Felder erreichen',defeatEnemies:'Bestimmte Gegner besiegen',collectDiamonds:'Diamanten sammeln'}).map(([value,text])=>h('option',{value},text)));
  type.value=rules.customGoal.type;
  const threshold=h('input',{id:'custom-goal-diamonds',type:'number',min:1,max:999,value:rules.customGoal.diamonds,disabled:readOnly}),targets=h('div',{class:'rule-targets'}),thresholdLabel=h('label',{class:'map-form-label'},'Benötigte Diamanten',threshold);
  let targetChecks=[];const selected=new Set(rules.customGoal.cellIds);
  function renderTargets(){for(const {r,input} of targetChecks)input.checked?selected.add(r.id):selected.delete(r.id);targetChecks=doc.rooms.filter(r=>type.value==='reachFields'||type.value==='defeatEnemies'&&ENEMIES.includes(r.type)).map(r=>({r,input:h('input',{type:'checkbox',checked:selected.has(r.id),disabled:readOnly})}));targets.hidden=!['reachFields','defeatEnemies'].includes(type.value);thresholdLabel.hidden=type.value!=='collectDiamonds';targets.replaceChildren(...targetChecks.map(({r,input})=>h('label',{class:'rule-check'},input,label(r))));}
  const dialog=h('dialog',{class:'workshop-dialog rules-dialog','aria-label':'Spielregeln'},h('p',{class:'eyebrow'},'Die Karte fürs Online-Spiel vorbereiten'),h('h2',{},'Spielregeln'),
    h('section',{class:'rule-section'},h('h3',{},'Powerups aus Schatzkisten'),h('p',{class:'muted'},'Jeden Typ kann ein Spieler einmal wählen. Seine Verwendungen bleiben wie besprochen.'),h('div',{class:'rule-powerups'},...powers.map(p=>h('label',{class:'rule-check'},p.node,p.name)))),
    h('section',{class:'rule-section'},h('h3',{},'Graue Angriffszahlen freischalten'),h('p',{class:'muted'},'Ein erreichtes X-Feld aktiviert die zugeordnete Angriffszahl. Bei mehreren ausgewählten X-Feldern genügt eines davon. Graue Wegfelder sind eine optische Markierung.'),
      ...unlocks.map(({r,a,checks})=>h('fieldset',{class:'unlock-rule'},h('legend',{},`${label(r)} · Angriff ${numberLabel(a.number)}`),checks.length?checks.map(({s,input})=>h('label',{class:'rule-check'},input,label(s))):h('p',{class:'muted'},'Zuerst ein X-Feld anlegen.'))),
      !locked.length?h('p',{class:'muted'},'Noch keine grauen Angriffszahlen auf dieser Karte.'):null,
      rules.unlocks.some(u=>!locked.some(({r,a})=>r.id===u.targetCellId&&a.number===u.number)||!specials.some(s=>s.id===u.sourceCellId))?h('p',{class:'feedback info'},'Es gibt veraltete Zuordnungen. Beim Übernehmen ersetzen die hier ausgewählten Zuordnungen den bisherigen Stand.'):null),
    h('section',{class:'rule-section'},h('h3',{},'Spezialpunkte'),h('p',{},`Aufgabe 1: alle ${specials.length} X-Felder erreichen. Belohnung: 3 ♦ / 1 ♦.`),h('label',{class:'map-form-label'},'Aufgabe 2',type),targets,thresholdLabel,
      h('p',{class:'muted'},'Für Aufgabe 2 gilt ebenfalls 3 ♦ / 1 ♦. Die eigene Erklärungsgrafik kannst du im Drucklayout hochladen. Ohne zweite Aufgabe wird dafür im Online-Spiel keine Belohnung vergeben.')),message,
    h('div',{class:'button-row'},readOnly?null:h('button',{class:'button primary',id:'save-map-rules',onclick:()=>{
      const diamonds=Number(threshold.value);if(!Number.isInteger(diamonds)||diamonds<1||diamonds>999){setFeedback(message,'Bitte eine ganze Diamantenzahl zwischen 1 und 999 eingeben.');return;}
      const next={version:1,specialReward:{first:3,later:1},unlocks:unlocks.flatMap(({r,a,checks})=>checks.filter(c=>c.input.checked).map(({s})=>({sourceCellId:s.id,targetCellId:r.id,number:a.number}))),customGoal:{type:type.value,cellIds:targetChecks.filter(c=>c.input.checked).map(c=>c.r.id),diamonds}};
      onSave(next,powers.filter(p=>p.node.checked).map(p=>p.key));dialog.close();
    }},'Übernehmen'),h('button',{class:'button secondary',onclick:()=>dialog.close()},readOnly?'Schließen':'Abbrechen')));
  dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);renderTargets();dialog.showModal();return dialog;
}

export function rulesDialog(options) {
  if(options.document.format!==FORMAT)return legacyRulesDialog(options);
  const {document:doc,readOnly,onSave}=options,rules=structuredClone(doc.rules || newRules()),message=feedback();
  const powers=Object.entries(POWERUPS).map(([key,name])=>({key,node:h('input',{type:'checkbox',checked:doc.allowedPowerups.includes(key),disabled:readOnly}),name}));
  const controls=rules.goals.map((g,i)=>{
    const selected=new Set(g.cellIds),type=h('select',{id:`goal-${i+1}-type`,disabled:readOnly},...Object.entries(GOALS).map(([value,text])=>h('option',{value},text)));
    type.value=g.type;
    const fieldType=h('select',{id:`goal-${i+1}-field-type`,disabled:readOnly},...Object.entries(TYPES).map(([value,text])=>h('option',{value},text)));fieldType.value=g.fieldType || 'rune';
    const threshold=h('input',{id:i===1?'custom-goal-diamonds':'goal-1-diamonds',type:'number',min:1,max:999,value:g.diamonds,disabled:readOnly});
    const first=h('input',{id:`goal-${i+1}-first`,type:'number',min:0,max:999,value:g.reward.first,disabled:readOnly}),later=h('input',{id:`goal-${i+1}-later`,type:'number',min:0,max:999,value:g.reward.later,disabled:readOnly});
    const targets=h('div',{class:'rule-targets'}),typeLabel=h('label',{class:'map-form-label'},'Feldart',fieldType),thresholdLabel=h('label',{class:'map-form-label'},'Benötigte Diamanten',threshold);let checks=[];
    function render(){for(const {r,input} of checks)input.checked?selected.add(r.id):selected.delete(r.id);
      const enemy=['defeatEnemies','firstEnemies'].includes(type.value);
      checks=doc.rooms.filter(r=>!enemy || ['monster','boss'].includes(r.type)).map(r=>({r,input:h('input',{type:'checkbox',disabled:readOnly,checked:selected.has(r.id)})}));
      targets.hidden=!['reachFields','defeatEnemies','firstEnemies','connect'].includes(type.value);typeLabel.hidden=type.value!=='allType';thresholdLabel.hidden=type.value!=='collectDiamonds';
      targets.replaceChildren(...checks.map(({r,input})=>h('label',{class:'rule-check'},input,cellLabel(r))));}
    type.addEventListener('change',render);render();
    return {section:h('section',{class:'rule-section'},h('h3',{},`Bonusaufgabe ${i+1}`),h('label',{class:'map-form-label'},'Aufgabe',type),typeLabel,targets,thresholdLabel,h('div',{class:'rule-powerups'},h('label',{class:'map-form-label'},'Erstbelohnung · Diamanten',first),h('label',{class:'map-form-label'},'Spätere Belohnung · Diamanten',later))),value(){
      const reward={first:Number(first.value),later:Number(later.value)},diamonds=Number(threshold.value),cellIds=checks.filter(c=>c.input.checked).map(c=>c.r.id);
      if(![reward.first,reward.later].every(n=>Number.isInteger(n)&&n>=0&&n<=999)||!Number.isInteger(diamonds)||diamonds<1||diamonds>999)throw Error('Belohnungen: 0–999, Diamantenziel: 1–999.');
      if(type.value==='connect'&&cellIds.length!==2)throw Error('Für einen durchgängigen Weg genau zwei Endpunkte auswählen.');
      if(['reachFields','defeatEnemies','firstEnemies'].includes(type.value)&&!cellIds.length)throw Error('Für diese Bonusaufgabe mindestens ein Feld auswählen.');
      return {type:type.value,fieldType:fieldType.value,cellIds,diamonds,reward};
    }};
  });
  const dialog=h('dialog',{class:'workshop-dialog rules-dialog','aria-label':'Spielregeln'},h('h2',{},'Spielregeln'),
    h('section',{class:'rule-section'},h('h3',{},'Powerups aus Schatzkisten'),h('div',{class:'rule-powerups'},...powers.map(p=>h('label',{class:'rule-check'},p.node,p.name)))),
    h('section',{class:'rule-section'},h('h3',{},'Automatische Freischaltungen'),h('p',{},'Graue Wegfelder schalten ihre Zahl beim angrenzenden Monster frei. Runenfelder schalten die passende Zahl beim Boss frei.'),
      h('div',{class:'rule-targets'},...(rules.unlocks || []).map(u=>h('p',{},`${cellLabel(doc.rooms.find(r=>r.id===u.sourceCellId))} → #${u.targetCellId} · ${numberLabel(u.number)}`)))),
    ...controls.map(c=>c.section),message,h('div',{class:'button-row'},readOnly?null:h('button',{id:'save-map-rules',class:'button primary',onclick:()=>{try{onSave({...rules,version:2,goals:controls.map(c=>c.value())},powers.filter(p=>p.node.checked).map(p=>p.key));dialog.close();}catch(error){setFeedback(message,error.message);}}},'Übernehmen'),h('button',{class:'button secondary',onclick:()=>dialog.close()},readOnly?'Schließen':'Abbrechen')));
  dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
