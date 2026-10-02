import {h,icon,avatar,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {miniature,mapMiniature} from './maps.js';
import {watchGameChanges} from '../games/realtime.js';
import {gameLink,dateLabel,settingsBadges,liveIndicator,joinDialog,gameStatusLabel} from '../games/ui.js';

export function playView(ctx) {
 const {api,status}=ctx;let closed=false,loaded=false;
 const message=feedback(),lobbies=h('div',{class:'game-list',id:'lobby-list'}),ongoing=h('div',{class:'game-list',id:'ongoing-list'}),live=liveIndicator();
 const element=h('section',{class:'play-view'},pageHeading('Gemeinsam spielen','Das nächste Abenteuer wartet.'),
  h('div',{class:'play-toolbar'},h('a',{class:'button primary',id:'new-game',href:'#/new-game'},icon('dice'),'Neues Spiel'),h('a',{class:'button secondary',href:'#/history'},icon('book'),'Chronik'),live.element,
   h('button',{class:'button secondary',title:'Spiele aktualisieren',id:'refresh-games',onclick:()=>watch.refresh()},'↻')),message,
  h('div',{class:'game-section-heading'},h('h2',{},'Deine laufenden Spiele')),ongoing,
  h('div',{class:'game-section-heading'},h('h2',{},'Offene Warteräume')),lobbies);
 function card(g) {
  const lobby=g.status==='lobby',full=g.playerCount>=g.settings.maxPlayers;
  return h('article',{class:'game-card panel','data-game-id':g.id},h('div',{class:'game-card-map'},mapMiniature(api,g.map)),h('div',{class:'game-card-main'},
   h('div',{class:'game-title-row'},h('h3',{},g.name),h('span',{class:`game-status ${g.status}`},gameStatusLabel(g))),h('p',{class:'game-map-name'},icon('map'),g.map.name),
   h('div',{class:'game-host'},avatar(g.host,'small'),h('span',{},'Host: ',g.host.displayName),h('span',{class:'muted'},`${g.playerCount} / ${g.settings.maxPlayers} Spieler`)),settingsBadges(g.settings),
   h('small',{class:'muted'},`Erstellt ${dateLabel(g.createdAt)}`)),h('div',{class:'game-card-action'},g.passwordRequired?h('span',{class:'muted password-note'},icon('lock'),'Mit Passwort'):null,
    g.mine?h('a',{class:'button primary',href:gameLink(g.id)},icon(lobby?'arrow':'dice'),lobby?'Warteraum öffnen':'Fortsetzen'):h('button',{class:'button primary',disabled:full,onclick:()=>joinDialog(ctx,g)},full?'Voll':'Beitreten')));
 }
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('list_games');if(closed)return;loaded=true;setFeedback(message,'');
   ongoing.replaceChildren(...data.ongoing.map(card));lobbies.replaceChildren(...data.lobbies.map(card));
   if(!data.ongoing.length)ongoing.append(h('div',{class:'game-empty'},icon('dice'),h('p',{},'Noch kein begonnenes Spiel.')));
   if(!data.lobbies.length)lobbies.append(h('div',{class:'game-empty'},icon('user'),h('p',{},'Gerade wartet kein Trupp. Eröffne eine neue Runde.')));
  } catch(error){if(!closed){setFeedback(message,error.message);if(!loaded)lobbies.replaceChildren(h('p',{class:'muted'},'Mit ↻ erneut laden.'));}}
 }
 const watch=watchGameChanges(['dungeon:lobbies'],{refresh:load,onState:state=>{if(!closed)live.set(state);},allowRealtime:status?.realtimeAvailable!==false});
 return {element,cleanup:()=>{closed=true;watch.cleanup();for(const dialog of document.querySelectorAll('.game-dialog'))dialog.close();}};
}
