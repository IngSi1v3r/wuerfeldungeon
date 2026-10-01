import {h,feedback,setFeedback} from '../dom.js';
import {POWERUPS,ENEMIES,defaultRules} from './model.js';
const numberLabel=n=>n==='doubles'?'Pasch':String(n ?? 'ohne Zahl');
const label=r=>`${r.name || ({special:'X-Feld',normal:'Wegfeld',diamond:'Diamant',chest:'Schatzkiste',monster:'Monster',miniboss:'Mini-Boss',boss:'Boss'})[r.type]} #${r.id}${ENEMIES.includes(r.type)?'':` · ${numberLabel(r.number)}`}`;

export function rulesDialog({document:doc,readOnly,onSave}) {
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
