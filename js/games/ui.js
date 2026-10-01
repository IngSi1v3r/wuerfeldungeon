import {h,icon,avatar,feedback,setFeedback} from '../dom.js';
import {GameCommands} from './commands.js';

export const gameLink=id=>`#/game?id=${id}`;
export const dateLabel=value=>value?new Date(value).toLocaleString('de-AT',{dateStyle:'medium',timeStyle:'short'}):'';
export const gameStatusLabel=g=>({lobby:'Warteraum',playing:'Laufend',paused:'Pausiert',finished:'Abgeschlossen',cancelled:'Abgebrochen'})[g.status];
export function settingsBadges(settings) {
  return h('div',{class:'game-badges'},h('span',{class:'badge'},icon('eye'),settings.cards==='hidden'?'Verdeckte Karten':'Offene Karten'),h('span',{class:'badge'},icon('sparkle'),settings.hints?'Mit Tipps':'Ohne Tipps'));
}
export function liveIndicator() {
 const node=h('span',{class:'live-indicator',role:'status'},h('span',{class:'status-dot'}),'Verbindung wird aufgebaut');
 return {element:node,set(state){node.dataset.state=state;node.replaceChildren(h('span',{class:'status-dot'}),({connected:'Live verbunden',connecting:'Live-Verbindung wird aufgebaut',fallback:'Regelmäßige Aktualisierung',offline:'Offline · letzter gespeicherter Stand'})[state]||'Verbindung wird aufgebaut');}};
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
export function resultsDialog(game) {
 const dialog=h('dialog',{class:'workshop-dialog game-dialog result-dialog','aria-label':'Spielergebnis'},h('p',{class:'eyebrow'},'Chronik'),h('h2',{},game.name),h('p',{class:'muted'},`${game.map.name} · ${dateLabel(game.finishedAt)}`),
  game.status==='cancelled'?h('p',{class:'feedback info'},'Dieses Spiel wurde ohne Wertung abgebrochen.'):h('div',{class:'results-list'},...game.results.map(r=>h('article',{class:`result-row ${r.won?'winner':''}`},
   avatar(r,'small'),h('div',{class:'result-name'},h('strong',{},r.displayName),h('small',{class:'muted'},`${r.diamonds} Diamanten · ${r.lifePenalty} Lebenspunkte · ${r.monstersDefeated} Gegner${r.removed?' · entfernt':r.eliminated?' · ausgeschieden':''}`),r.breakdown?.bossBonusDiamonds!=null?h('small',{class:'result-breakdown'},`${r.breakdown.otherDiamonds} ♦ gesammelt · ${r.breakdown.specialTaskDiamonds+r.breakdown.customTaskDiamonds} ♦ Spezialaufgaben · ${r.breakdown.bossBonusDiamonds} ♦ Bossgruppen`):null),h('div',{class:'result-points'},r.won?h('span',{class:'winner-label'},'Sieg'):null,h('strong',{},`${r.points} Punkte`))))),
  h('div',{class:'button-row'},game.participated?h('a',{class:'button secondary',href:gameLink(game.id),onclick:()=>dialog.close()},'Spielraum ansehen'):null,h('button',{class:'button primary',onclick:()=>dialog.close()},'Schließen')));
 dialog.addEventListener('close',()=>dialog.remove(),{once:true});document.body.append(dialog);dialog.showModal();return dialog;
}
