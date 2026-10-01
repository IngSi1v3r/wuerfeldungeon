import {h,icon,avatar,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {miniature} from './maps.js';
import {GameCommands} from '../games/commands.js';
import {watchGameChanges} from '../games/realtime.js';
import {boardPreview} from '../games/board-preview.js';
import {settingsBadges,liveIndicator,joinForm,gameStatusLabel,resultsDialog} from '../games/ui.js';

export function gameView(ctx) {
 const {api,profile,status,toast,gameId}=ctx;let closed=false,game=null,definition=null,board=null,currentMode=null,joining=false;
 const commands=new GameCommands(api),message=feedback(),body=h('div',{id:'game-content'}),live=liveIndicator(),heading=h('div',{class:'game-heading'});
 const element=h('section',{class:'game-view'},h('div',{class:'play-toolbar'},h('a',{class:'button secondary',href:'#/play'},icon('back'),'Spielauswahl'),live.element,
  h('button',{class:'button secondary',title:'Spiel aktualisieren',id:'refresh-game',onclick:()=>watch.refresh()},'↻')),heading,message,body);
 async function command(name,params,after) {
  if(commands.busy)return;
  try {const task=commands.run(name,params);render();await task;if(closed)return;setFeedback(message,'');if(after)await after();else await watch.refresh();}
  catch(error){if(!closed){setFeedback(message,error.message);if(['GAME_CHANGED','GAME_ALREADY_STARTED','GAME_CLOSED'].includes(error.code))await watch.refresh();}}
  finally {if(!closed&&game)render();}
 }
 function manage(action,target=null) {
  const text={cancel:'Dieses Spiel ohne Wertung abbrechen? Es bleibt in der Chronik sichtbar.',remove:'Diesen Spieler aus dem Warteraum entfernen?',host:'Die Hostrolle an diesen Spieler übergeben?'}[action];
  if(text&&!confirm(text))return;
  command('manage_game',{p_game_id:gameId,p_action:action,p_target_player_id:target,p_expected_revision:game.revision});
 }
 function players(isLobby) {
  const host=game.host.id===profile.id;
  return h('div',{class:isLobby?'lobby-players':'room-players',id:'game-players'},...game.participants.filter(p=>isLobby||p.id!==profile.id).map(p=>h('article',{class:`lobby-player ${p.id===profile.id?'me':''}`,'data-player-id':p.id},
   avatar(p),h('div',{class:'lobby-player-copy'},h('strong',{},p.displayName),h('span',{class:'muted'},p.id===game.host.id?'Host':p.id===profile.id?'Dein Platz':'Mitspieler'),
    h('small',{class:p.online?'player-online':'muted'},p.online?'Gerade im Spielraum':'Zurzeit nicht im Spielraum')),
   host&&p.id!==profile.id&&game.status!=='finished'&&game.status!=='cancelled'?h('div',{class:'player-actions'},
    h('button',{class:'text-button',disabled:commands.busy,onclick:()=>manage('host',p.id)},'Host übergeben'),isLobby?h('button',{class:'text-button',disabled:commands.busy,onclick:()=>manage('remove',p.id)},'Entfernen'):null):null)));
 }
 async function invite() {
  try {await navigator.clipboard.writeText(location.href);toast('Einladungslink kopiert.');}catch{prompt('Diesen Link an deine Freunde weitergeben:',location.href);}
 }
 function render() {
  if(!game||closed)return;const lobby=game.status==='lobby',host=game.host.id===profile.id,ended=['cancelled','finished'].includes(game.status);
  heading.replaceChildren(pageHeading(lobby?'Euer Warteraum':'Euer Spielraum',game.name,`${game.map.name} · Host: ${game.host.displayName}`),h('span',{class:`game-status ${game.status}`,id:'game-status'},gameStatusLabel(game)),settingsBadges(game.settings));
  const mode=lobby?'lobby':'room';
  if(currentMode!==mode){currentMode=mode;body.replaceChildren();}
  if(lobby) {
   body.replaceChildren(h('div',{class:'lobby-layout'},h('div',{class:'panel lobby-roster'},h('div',{class:'game-title-row'},h('h2',{},'Euer Trupp'),h('span',{class:'badge',id:'game-player-count'},`${game.playerCount} / ${game.settings.maxPlayers}`)),players(true)),
    h('aside',{class:'panel lobby-map'},miniature(game.map.preview),h('h2',{},game.map.name),h('p',{class:'muted'},`${game.map.fields} Felder · ${game.map.enemies} Gegner`),
     h('p',{class:'muted'},game.passwordRequired?'Dieser Warteraum ist mit einem Passwort geschützt.':'Freunde können ohne Spielpasswort beitreten.'),h('button',{class:'button secondary',onclick:invite},icon('upload'),'Einladungslink kopieren'))),
    h('div',{class:'lobby-controls panel'},h('div',{},h('h2',{},host?'Alle da?':'Wir warten auf den Start.'),h('p',{class:'muted'},host?'Mit dem Start wird der Warteraum geschlossen. Später können die Teilnehmer ihren Spielraum jederzeit wieder öffnen.':`${game.host.displayName} startet, sobald euer Trupp bereit ist.`)),
     h('div',{class:'button-row'},host?h('button',{id:'start-game',class:'button primary',disabled:commands.busy,onclick:()=>command('start_game',{p_game_id:gameId,p_expected_revision:game.revision})},icon('dice'),'Spiel starten'):null,
      h('button',{id:'leave-lobby',class:'button secondary',disabled:commands.busy,onclick:()=>{
       if(confirm(host&&game.playerCount>1?'Warteraum verlassen? Die Hostrolle übernimmt der nächste Teilnehmer.':'Warteraum verlassen?'))command('leave_game',{p_game_id:gameId},()=>{location.hash='#/play';});
      }},'Warteraum verlassen'))));
  } else {
   let top=body.querySelector('.room-management');
   if(!top){top=h('div',{class:'room-management'});body.append(top);}
   top.replaceChildren(h('div',{class:'room-others'},game.participants.length>1?players(false):h('p',{class:'muted'},'Du bist allein in dieser Runde.')),
    h('div',{class:'room-controls'},h('p',{class:'phase-note',id:'game-phase-note'},ended?(game.status==='cancelled'?'Ohne Wertung abgebrochen.':'Dieses Abenteuer ist abgeschlossen.'):game.status==='paused'?'Das Spiel ist für alle pausiert.':'Der Spielraum ist gespeichert und bereit. Würfeln und Züge werden in Phase 4 ergänzt.'),
     h('div',{class:'button-row'},host&&!ended?h('button',{id:'pause-game',class:'button secondary',disabled:commands.busy,onclick:()=>manage(game.status==='paused'?'resume':'pause')},game.status==='paused'?'Pause beenden':'Für alle pausieren'):null,
      host&&!ended?h('button',{id:'cancel-game',class:'text-button',disabled:commands.busy,onclick:()=>manage('cancel')},'Spiel abbrechen'):null,
      ended?h('button',{class:'button secondary',onclick:async()=>{try{const data=await api.authRpc('get_game_result',{p_game_id:gameId});if(!closed)resultsDialog(data.game);}catch(error){setFeedback(message,error.message);}}},'Chronik ansehen'):null)));
   if(!board&&definition){board=boardPreview(api,definition);body.append(board.element);}
  }
 }
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('get_game',{p_game_id:gameId,p_include_definition:!definition});if(closed)return;
   if(game&&data.game.revision<game.revision)return;
   game=data.game;definition=data.game.definition||definition;setFeedback(message,'');render();
  } catch(error) {
   if(closed)return;
   if(error.code==='GAME_JOIN_REQUIRED'&&!game) {
    if(joining)return;joining=true;const lobby=error.details.lobby;
    heading.replaceChildren(pageHeading('Einladung',lobby.name,lobby.map.name));body.replaceChildren(h('div',{class:'panel invited-game'},joinForm({api,game:lobby,onJoined:async()=>{joining=false;await load();}}).element));setFeedback(message,'');
   } else if(['GAME_NOT_MEMBER','GAME_REMOVED'].includes(error.code)){game=null;board?.cleanup();board=null;body.replaceChildren(h('a',{class:'button secondary',href:'#/play'},'Zur Spielauswahl'));setFeedback(message,error.message);}
   else setFeedback(message,error.message);
  }
 }
 const watch=watchGameChanges([`dungeon:game:${gameId}`],{refresh:load,onState:state=>{if(!closed)live.set(state);},allowRealtime:status?.realtimeAvailable!==false});
 return {element,cleanup:()=>{closed=true;watch.cleanup();board?.cleanup();for(const dialog of document.querySelectorAll('.game-dialog'))dialog.close();}};
}
