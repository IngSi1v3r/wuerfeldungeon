import {replayDialog} from './replay.js';
import {h,icon,avatar,feedback,setFeedback} from '../dom.js';
import {GameCommands} from './commands.js';
import {diceHints,fieldHints} from './rules.js';
import {TYPES,goalText} from '../maps/features.js';

export const gameLink=id=>`#/game?id=${id}`;
export const dateLabel=value=>value?new Date(value).toLocaleString('de-AT',{dateStyle:'medium',timeStyle:'short'}):'';
export const gameStatusLabel=g=>({lobby:'Warteraum',playing:'Laufend',paused:'Pausiert',finished:'Abgeschlossen',cancelled:'Abgebrochen'})[g.status];
export function settingsBadges(settings) {
  return h('div',{class:'game-badges'},h('span',{class:'badge'},icon('eye'),settings.cards==='hidden'?'Verdeckte Karten':'Offene Karten'),h('span',{class:'badge'},icon('sparkle'),diceHints(settings)&&fieldHints(settings)?'Mit Tipps':diceHints(settings)?'Würfelsummen':fieldHints(settings)?'Feldtipps':'Ohne Tipps'),settings.fog?h('span',{class:'badge'},'☁ Fog of War'):null);
}
export function lobbyRules(definition){
 if(!definition)return null;
 const rooms=definition.document.rooms,types=new Set(rooms.map(r=>r.type)),descriptions={
  doubleSum:'Nur der passende Pasch zählt: 6 benötigt 3 + 3, 8 benötigt 4 + 4.',diamond:'Ein Diamant zählt drei Punkte.',chest:'Ein noch nicht gewähltes Powerup auswählen.',rune:'Schaltet die entsprechende Angriffszahl beim Boss auch aus der Ferne frei.',bonus:'Optionale Aufgabe mit Treffern und eigener Belohnung.',trap:'Ab der Runde nach dem ersten Betreten kostet die Falle Diamanten oder Leben.',portal:'Aktiviert automatisch das zweite Portal mit derselben Zahl.',crazy:'Wählt jede Runde eine gemeinsame neue Zahl aus seinem Vorrat.',goldSack:'Zählt zwei Punkte.',goldCoin:'Zählt einen Punkt.'};
 const goals=definition.rules.goals||[{type:'allType',fieldType:'special',reward:{first:3,later:1}}, {...definition.rules.customGoal,reward:{first:3,later:1}}];
 return h('section',{class:'lobby-rules'},h('h3',{},'Diese Welt'),h('dl',{},...Object.entries(descriptions).filter(([type])=>types.has(type)).flatMap(([type,text])=>[h('dt',{},TYPES[type]),h('dd',{},text)])),
  rooms.some(r=>r.dimmed)?h('p',{},'Graue Wegfelder schalten eine Angriffszahl bei angrenzenden Monstern oder Bossen frei.'):null,
  h('h3',{},'Bonusaufgaben'),...goals.filter(g=>g.type!=='none').map((g,i)=>h('p',{'data-lobby-goal':i},h('strong',{},goalText(g,rooms)),h('br'),`${g.reward.first} ♦ zuerst / ${g.reward.later} ♦ später`)),goals.every(g=>g.type==='none')?h('p',{class:'muted'},'Keine zusätzlichen Bonusaufgaben.'):null);
}
export function lifeLossDialog(events,{eliminated=false}={}){
 const amount=events.reduce((sum,e)=>sum+(e.payload.amount||1),0),trap=events.some(e=>e.payload.cause==='trap');
 const dialog=h('dialog',{class:'game-dialog life-loss-dialog','aria-label':'Leben verloren'},h('span',{class:'life-loss-symbol','aria-hidden':true},'♡'),h('h2',{},eliminated?'Ausgeschieden':`${amount===1?'Ein Leben':`${amount} Leben`} verloren`),h('p',{},eliminated?'Deine Lebensanzeige ist vollständig ausgefüllt. Dein bisheriger Punktestand zählt weiterhin.':trap?'Eine scharfe Falle hat dich erwischt.':'Für diesen Zug wurde ein Lebensfeld ausgefüllt.'),h('button',{class:'button primary',autofocus:true,onclick:()=>dialog.close()},'Verstanden'));
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
export function liveIndicator() {
 const node=h('span',{class:'live-indicator',role:'status'},h('span',{class:'status-dot'}),'Verbindung wird aufgebaut');
 return {element:node,set(state){node.dataset.state=state;const label=({connected:'Live verbunden',connecting:'Live-Verbindung wird aufgebaut',fallback:'Regelmäßige Aktualisierung',offline:'Offline · letzter gespeicherter Stand'})[state]||'Verbindung wird aufgebaut';node.title=label;node.replaceChildren(h('span',{class:'status-dot'}),label);}};
}
export function joinForm({api,game,onJoined,commands=new GameCommands(api)}) {
 const message=feedback(),password=h('input',{id:'join-password',type:'password',autocomplete:'off',maxlength:72,required:game.passwordRequired,'aria-label':'Spielpasswort'});
 const submit=h('button',{type:'submit',class:'button primary',id:'join-submit'},icon('arrow'),'Beitreten');
 const form=h('form',{class:'join-form',onsubmit:async event=>{
  event.preventDefault();submit.disabled=true;setFeedback(message,'');
  try {await commands.run('join_game',{p_game_id:game.id,p_password:game.passwordRequired?password.value:''});password.value='';await onJoined();}
  catch(error){setFeedback(message,error.message);}finally{submit.disabled=false;}
 }},h('p',{class:'muted'},`${game.playerCount} / ${game.settings.maxPlayers} Plätze · Host: ${game.host.displayName}`),game.passwordRequired?h('label',{class:'map-form-label'},'Spielpasswort',password):h('p',{class:'muted'},'Für diesen Warteraum brauchst du kein Passwort.'),message,submit);
 return {element:form};
}
export function joinDialog(ctx,game) {
 const dialog=h('dialog',{class:'workshop-dialog game-dialog','aria-label':'Warteraum beitreten'},h('p',{class:'eyebrow'},'Gemeinsam spielen'),h('h2',{},game.name),h('p',{class:'muted'},game.map.name),
  joinForm({...ctx,game,onJoined:()=>{dialog.close();location.hash=gameLink(game.id);}}).element,
  h('button',{class:'text-button dialog-back',type:'button',onclick:()=>dialog.close()},'Abbrechen'));
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
export function resultsDialog(game,{api=null}={}) {
 const dialog=h('dialog',{class:'workshop-dialog game-dialog result-dialog','aria-label':'Spielergebnis'},h('p',{class:'eyebrow'},'Chronik'),h('h2',{},game.name),h('p',{class:'muted'},`${game.map.name} · ${dateLabel(game.finishedAt)}`),
  game.startedAt?h('div',{class:'result-summary'},h('span',{},`${game.round||'–'} Runden`),h('span',{},`${Math.max(0,Math.round((Date.parse(game.finishedAt)-Date.parse(game.startedAt))/60000))} Minuten`),h('span',{},`${game.results.length} Spieler`)):null,
  game.status==='cancelled'?h('p',{class:'feedback info'},'Dieses Spiel wurde ohne Wertung abgebrochen.'):h('div',{class:'results-list'},...game.results.map(r=>h('article',{class:`result-row ${r.won?'winner':''}`},
   avatar(r,'small'),h('div',{class:'result-name'},h('strong',{},r.displayName),h('small',{class:'muted'},`${r.diamonds} Diamanten${r.breakdown?.goldPoints?` · ${r.breakdown.goldPoints} Goldpunkte`:''} · ${r.lifePenalty} Lebenspunkte · ${r.monstersDefeated} Gegner${r.removed?' · entfernt':r.eliminated?' · ausgeschieden':''}`),r.breakdown?.bossBonusDiamonds!=null?h('small',{class:'result-breakdown'},`${r.breakdown.otherDiamonds} ♦ gesammelt · ${r.breakdown.specialTaskDiamonds+r.breakdown.customTaskDiamonds} ♦ Spezialaufgaben · ${r.breakdown.bossBonusDiamonds} ♦ Bossgruppen`):null),h('div',{class:'result-points'},r.won?h('span',{class:'winner-label'},'Sieg'):null,h('strong',{},`${r.points} Punkte`))))),
  h('div',{class:'button-row'},api&&game.status==='finished'?h('button',{id:'watch-replay',class:'button secondary',onclick:()=>replayDialog(api,game.id)},'Wiederholung ansehen'):null,game.participated?h('a',{class:'button secondary',href:gameLink(game.id),onclick:()=>dialog.close()},'Spielraum ansehen'):null,h('button',{class:'button primary',onclick:()=>dialog.close()},'Schließen')));
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
