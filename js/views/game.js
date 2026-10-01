import {h,icon,avatar,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {miniature} from './maps.js';
import {GameCommands} from '../games/commands.js';
import {watchGameChanges} from '../games/realtime.js';
import {boardPreview} from '../games/board-preview.js';
import {settingsBadges,liveIndicator,joinForm,gameStatusLabel,resultsDialog} from '../games/ui.js';
import {turnPanel,redDiceDialog} from '../games/turn-panel.js';

export function gameView(ctx) {
 const {api,profile,status,toast,gameId}=ctx;let closed=false,game=null,definition=null,board=null,currentMode=null,joining=false,confirming=false,lastEvent=null;
 const commands=new GameCommands(api),message=feedback(),body=h('div',{id:'game-content'}),live=liveIndicator(),heading=h('div',{class:'game-heading'});
 const playInstalled=status?.playSchemaVersion===CONFIG.playSchemaVersion;
 const panel=turnPanel({profile,onRoll:()=>command('roll_game_dice',{p_game_id:gameId,p_round:game.round}),onLoseLife:()=>{
  if(confirm('Ein Leben verlieren und diesen Zug beenden? Die rote Verwendung bleibt erhalten.'))playTurn(null,'lose_life');
 },onResolveWait:(id,action)=>{
  if(confirm(action==='remove'?'Diesen Spieler aus dem laufenden Spiel entfernen?':'Diesen offenen Zug ohne Lebensabzug überspringen?'))command('resolve_game_wait',{p_game_id:gameId,p_round:game.round,p_target_player_id:id,p_action:action});
 }});
 const element=h('section',{class:'game-view'},h('div',{class:'play-toolbar'},h('a',{class:'button secondary',href:'#/play'},icon('back'),'Spielauswahl'),live.element,
  h('button',{class:'button secondary',title:'Spiel aktualisieren',id:'refresh-game',onclick:()=>watch.refresh()},'↻')),heading,message,body);
 async function command(name,params,after) {
  if(commands.busy)return;
  try {const task=commands.run(name,params);render();const result=await task;if(closed)return;setFeedback(message,'');if(after)await after();else await watch.refresh();return result;}
  catch(error){if(!closed){if(error.code!=='GAME_RED_CONFIRMATION')setFeedback(message,error.message);if(['GAME_CHANGED','GAME_ALREADY_STARTED','GAME_CLOSED','GAME_ROUND_CHANGED','GAME_STATE_CHANGED','GAME_TURN_DONE','GAME_ALREADY_ROLLED','GAME_PAUSED'].includes(error.code))await watch.refresh();}return {error};}
  finally {if(!closed&&game)render();}
 }
 async function playTurn(cellId,action='cell') {
  if(closed||commands.busy||confirming||!playInstalled||!game.turn?.canAct)return;
  const params={p_game_id:gameId,p_round:game.round,p_state_revision:game.turn.ownRevision,p_action:action,p_cell_id:cellId,p_use_red:false};
  async function ask(){confirming=true;render();try{return await redDiceDialog(game.ownState.redUses);}finally{confirming=false;if(!closed)render();}}
  if(action==='cell'&&game.turn.actions?.some(a=>a.cellId===cellId&&a.redOnly)){if(!await ask()||closed)return;params.p_use_red=true;}
  const answer=await command('play_game_turn',params);
  if(answer?.error?.code==='GAME_RED_CONFIRMATION'&&!closed&&await ask()&&!closed)await command('play_game_turn',{...params,p_use_red:true});
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
    isLobby?h('small',{class:p.online?'player-online':'muted'},p.online?'Gerade im Spielraum':'Zurzeit nicht im Spielraum'):h('small',{class:'opponent-score'},`${p.points||0} Punkte · ${p.eliminated?'ausgeschieden':game.phase==='choosing'?(p.turnDone?'Zug gespeichert':'wählt noch'):'bereit'}`)),
   !isLobby&&p.id===game.rollerId?h('span',{class:'roller-indicator',title:'Mit Würfeln dran','aria-label':'Mit Würfeln dran'},icon('dice')):null,
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
    h('div',{class:'room-controls'},h('p',{class:'phase-note',id:'game-phase-note'},ended?(game.status==='cancelled'?'Ohne Wertung abgebrochen.':'Dieses Abenteuer ist abgeschlossen.'):!playInstalled?'Zum Würfeln bitte 008_phase4.sql installieren.':`Regelkern aktiv · ${game.settings.hints?'Spielbare Felder sind grün umrandet, zusätzliche rote Möglichkeiten rot.':'Ohne Tipps: passende Felder selbst suchen.'} Powerups und Schlusswertung folgen in Phase 5.`),
     h('div',{class:'button-row'},host&&!ended?h('button',{id:'pause-game',class:'button secondary',disabled:commands.busy,onclick:()=>manage(game.status==='paused'?'resume':'pause')},game.status==='paused'?'Pause beenden':'Für alle pausieren'):null,
      host&&!ended?h('button',{id:'cancel-game',class:'text-button',disabled:commands.busy,onclick:()=>manage('cancel')},'Spiel abbrechen'):null,
      ended?h('button',{class:'button secondary',onclick:async()=>{try{const data=await api.authRpc('get_game_result',{p_game_id:gameId});if(!closed)resultsDialog(data.game);}catch(error){setFeedback(message,error.message);}}},'Chronik ansehen'):null)));
   if(!board&&definition){board=boardPreview(api,definition,{onCell:id=>playTurn(id)});
    if(playInstalled){body.append(panel.element,h('div',{class:'room-play'},board.element,panel.lives),panel.score);}else body.append(board.element);
   }
   if(playInstalled){panel.update(game,commands.busy||confirming);board?.update({state:game.ownState,hints:game.settings.hints,actions:game.turn?.actions,claims:game.claims,markStyle:profile.preferences?.markStyle,interactive:game.turn?.canAct&&!commands.busy&&!confirming});}
  }
 }
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('get_game',{p_game_id:gameId,p_include_definition:!definition});if(closed)return;
   if(game&&data.game.revision<game.revision)return;
   game=data.game;definition=data.game.definition||definition;setFeedback(message,'');render();
   if(lastEvent!==null)for(const event of game.events||[]){if(Number(event.id)<=lastEvent)continue;
    if(event.kind==='enemy_defeated'){const name=game.participants.find(p=>p.id===event.payload.playerId)?.displayName;toast(name?`${name} hat ${event.payload.name} besiegt.`:`${event.payload.name} wurde besiegt.`);}
    if(event.kind==='life_lost')toast(event.payload.automatic?'Kein legaler Zug möglich: ein Leben verloren.':'Ein Leben verloren.');
   }
   lastEvent=Math.max(lastEvent||0,...(game.events||[]).map(e=>Number(e.id)));
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
 return {element,cleanup:()=>{closed=true;watch.cleanup();board?.cleanup();panel.cleanup();for(const dialog of document.querySelectorAll('.game-dialog'))dialog.close();}};
}
