import {h,icon,avatar,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {miniature,mapMiniature} from './maps.js';
import {GameCommands} from '../games/commands.js';
import {watchGameChanges} from '../games/realtime.js';
import {boardPreview} from '../games/board-preview.js';
import {settingsBadges,liveIndicator,joinForm,gameStatusLabel,resultsDialog,lobbyRules,lifeLossDialog} from '../games/ui.js';
import {powerupDialog} from '../games/powerups.js';
import {cellReachable,ENEMY_TYPES,gameWaitKind,fieldHints} from '../games/rules.js';
import {turnPanel,redDiceDialog} from '../games/turn-panel.js';
import {renderSection} from '../games/render.js';

export function gameView(ctx) {
 const {api,profile,status,toast,gameId}=ctx;let closed=false,game=null,definition=null,board=null,currentMode=null,joining=false,confirming=false,lastEvent=null,torchMode=false,middleCellId=null,axeMode=false,torchActions=[],torchLoading=false,ownKey=null,powerDialog=null,powerKey=null,dismissedPowerKey=null,opponent=null,finishedShown=false;
 const commands=new GameCommands(api),message=feedback(),body=h('div',{id:'game-content'}),live=liveIndicator(),heading=h('div',{class:'game-heading'});
 const roomRows=new Map(),roomPlayers=h('div',{class:'room-players',id:'game-players'}),roomOthers=h('div',{class:'room-others'}),roomControls=h('div',{class:'room-controls'});
 const playInstalled=status?.playSchemaVersion===CONFIG.playSchemaVersion;
 const rulesInstalled=status?.rulesSchemaVersion===CONFIG.rulesSchemaVersion;
 const panel=turnPanel({profile,onTorch:rulesInstalled?toggleTorch:null,onAxe:rulesInstalled?()=>{axeMode=!axeMode;torchMode=false;middleCellId=null;render();}:null,onChoosePowerup:rulesInstalled?()=>openPowerup(true):null,onRoll:()=>command('roll_game_dice',{p_game_id:gameId,p_round:game.round}),onLoseLife:()=>{
  if(confirm('Ein Leben verlieren und diesen Zug beenden? Deine Powerup-Verwendungen bleiben erhalten.'))playTurn(null,'lose_life');
 },onResolveWait:(id,action)=>{
  if(confirm(action==='remove'?'Diesen Spieler aus dem laufenden Spiel entfernen?':gameWaitKind(game)==='roll'?'Diesen Wurf an den nächsten aktiven Spieler weitergeben? Der Spieler bleibt im Spiel und kann danach seinen Zug machen.':'Diesen offenen Zug ohne Lebensabzug überspringen? Eine noch offene Powerup-Auswahl verfällt dabei.'))command('resolve_game_wait',{p_game_id:gameId,p_round:game.round,p_target_player_id:id,p_action:action});
 }});
 const element=h('section',{class:'game-view'},h('div',{class:'play-toolbar'},h('a',{class:'button secondary',href:'#/play'},icon('back'),'Spielauswahl'),live.element,
  h('button',{class:'button secondary',title:'Spiel aktualisieren',id:'refresh-game',onclick:()=>watch.refresh()},'↻')),heading,message,body);
 async function command(name,params,after) {
  if(commands.busy)return;
  try {const task=commands.run(name,params);render();const result=await task;if(closed)return;setFeedback(message,'');if(after)await after();else await watch.refresh();return result;}
  catch(error){if(!closed){if(error.code!=='GAME_RED_CONFIRMATION')setFeedback(message,error.message);if(['GAME_CHANGED','GAME_ALREADY_STARTED','GAME_CLOSED','GAME_ROUND_CHANGED','GAME_STATE_CHANGED','GAME_TURN_DONE','GAME_ALREADY_ROLLED','GAME_ROLLER_ONLY','GAME_PAUSED','GAME_POWERUP_PENDING','GAME_CHEST_INVALID'].includes(error.code))await watch.refresh();}return {error};}
  finally {if(!closed&&game)render();}
 }
 async function playTurn(cellId,action='cell') {
  if(closed||commands.busy||confirming||!playInstalled||!game.turn?.canAct)return;
  const params={p_game_id:gameId,p_round:game.round,p_state_revision:game.turn.ownRevision,p_action:action,p_cell_id:cellId,p_use_red:false,...(rulesInstalled?{p_middle_cell_id:action==='cell'&&torchMode?middleCellId:null,p_use_axe:action==='cell'&&axeMode}: {})};
  async function ask(){confirming=true;render();try{return await redDiceDialog(game.ownState.redUses);}finally{confirming=false;if(!closed)render();}}
  if(action==='cell'&&(torchMode?torchActions:game.turn.actions)?.some(a=>a.cellId===cellId&&(!torchMode||a.middleCellId===middleCellId)&&a.redOnly)){if(!await ask()||closed)return;params.p_use_red=true;}
  const answer=await command(rulesInstalled?'play_game_action':'play_game_turn',params);
  if(answer?.error?.code==='GAME_RED_CONFIRMATION'&&!closed&&await ask()&&!closed)await command(rulesInstalled?'play_game_action':'play_game_turn',{...params,p_use_red:true});
 }
 async function toggleTorch(){
  torchMode=!torchMode;middleCellId=null;axeMode=false;torchActions=[];render();
  if(!torchMode||!fieldHints(game.settings))return;
  torchLoading=true;const key=ownKey;
  try{const data=await api.authRpc('get_torch_options',{p_game_id:gameId,p_round:game.round,p_state_revision:game.turn.ownRevision});
   if(!closed&&torchMode&&key===ownKey)torchActions=data.actions;
  }catch(error){if(!closed)setFeedback(message,error.message);}finally{torchLoading=false;if(!closed)render();}
 }
 function chooseCell(id){
  if(!game.turn?.canAct||commands.busy||confirming||torchLoading)return;
  if(torchMode&&!middleCellId){
   const room=definition.document.rooms.find(r=>String(r.id)===id);
   if(!room||ENEMY_TYPES.has(room.type)||!cellReachable(definition,game.ownState,id)){setFeedback(message,'Die Fackel braucht zuerst einen angrenzenden, noch freien Raum. Ein Gegner kann kein Zwischenraum sein.');return;}
   middleCellId=id;setFeedback(message,'');render();return;
  }
  if(torchMode&&id===middleCellId){middleCellId=null;render();return;}
  playTurn(id);
 }
 function highlightedActions(){
  if(!torchMode)return game.turn?.actions;
  if(middleCellId)return torchActions.filter(a=>a.middleCellId===middleCellId);
  const grouped=new Map();for(const a of torchActions){const previous=grouped.get(a.middleCellId);if(!previous||previous.redOnly&&!a.redOnly)grouped.set(a.middleCellId,{cellId:a.middleCellId,redOnly:a.redOnly});}return [...grouped.values()];
 }
 function openPowerup(force=false){
  if(!rulesInstalled||closed||game.status!=='playing'||!game.turn?.pendingPowerup)return;
  const chest=game.ownState.pendingChests[0],key=`${chest}:${game.turn.ownRevision}`;
  if(powerDialog||!force&&dismissedPowerKey===key)return;
  powerKey=key;const revision=game.turn.ownRevision;
  const dialog=powerupDialog({available:game.turn.availablePowerups,onChoose:async type=>{
   const result=await command('choose_game_powerup',{p_game_id:gameId,p_chest_cell_id:chest,p_state_revision:revision,p_powerup:type});
   if(result?.error)throw result.error;return Boolean(result?.ok);
  },onClose:()=>{if(powerDialog===dialog){powerDialog=null;dismissedPowerKey=key;}}});powerDialog=dialog;
 }
 function claimsFor(playerId){const state=game.states?.find(s=>s.playerId===playerId)?.state;return (game.claims||[]).map(claim=>({...claim,ownFirst:game.rulesVersion>=7?state?.firstKills?.includes(String(claim.cellId)):claim.playerId===playerId}));}
 function opponentView(id){const entry=game.states?.find(s=>s.playerId===id);return {state:entry?.state,claims:claimsFor(id),markStyle:'pencil',interactive:false,hints:false,fog:game.settings.fog&&game.status!=='finished',visibleCells:entry?.visibleCells,roundRequirements:game.roundRequirements,traps:game.traps};}
 function openOpponent(player){
  if(game.settings.cards!=='open'||!board?.getTemplate())return;
  opponent?.dialog.close();
  const preview=boardPreview(api,definition,{template:board.getTemplate(),prefix:'opponent',title:`Spielplan von ${player.displayName}`});
  preview.update(opponentView(player.id));
  const dialog=h('dialog',{class:'game-dialog opponent-dialog','aria-label':`Spielplan von ${player.displayName}`},h('div',{class:'opponent-dialog-heading'},h('h2',{},player.displayName),h('button',{class:'button secondary',onclick:()=>dialog.close()},'Schließen')),preview.element);
  opponent={id:player.id,preview,dialog};dialog.addEventListener('close',()=>{preview.cleanup();dialog.remove();if(opponent?.dialog===dialog)opponent=null;},{once:true});document.body.append(dialog);dialog.showModal();
 }
 function manage(action,target=null) {
  const text={cancel:'Dieses Spiel ohne Wertung abbrechen? Es bleibt in der Chronik sichtbar.',remove:'Diesen Spieler aus dem Warteraum entfernen?',host:'Die Hostrolle an diesen Spieler übergeben?'}[action];
  if(text&&!confirm(text))return;
  command('manage_game',{p_game_id:gameId,p_action:action,p_target_player_id:target,p_expected_revision:game.revision});
 }
 function players(isLobby) {
  const host=game.host.id===profile.id;
  return h('div',{class:isLobby?'lobby-players':'room-players',id:'game-players'},...game.participants.filter(p=>isLobby||p.id!==profile.id).map(p=>{
   const article=h('article',{class:`lobby-player ${p.id===profile.id?'me':''}`,'data-player-id':p.id},
    avatar(p),h('div',{class:'lobby-player-copy'},h('strong',{},p.displayName),h('span',{class:'muted'},p.id===game.host.id?'Host':p.id===profile.id?'Dein Platz':'Mitspieler'),
     isLobby?h('small',{class:p.online?'player-online':'muted'},p.online?'Gerade im Spielraum':'Zurzeit nicht im Spielraum'):h('small',{class:'opponent-score'},`${p.points||0} Punkte · ${p.eliminated?'ausgeschieden':p.hasPendingPowerup?'wählt Powerup':game.phase==='choosing'?(p.turnDone?'Zug gespeichert':'wählt noch'):'bereit'}`)),
    !isLobby&&p.id===game.rollerId?h('span',{class:'roller-indicator',title:'Mit Würfeln dran','aria-label':'Mit Würfeln dran'},icon('dice')):null,
    host&&p.id!==profile.id&&game.status!=='finished'&&game.status!=='cancelled'?h('div',{class:'player-actions'},
     h('button',{class:'text-button',disabled:commands.busy,onclick:()=>manage('host',p.id)},'Host übergeben'),isLobby?h('button',{class:'text-button',disabled:commands.busy,onclick:()=>manage('remove',p.id)},'Entfernen'):null):null);
   if(!isLobby&&game.settings.cards==='open'){
    const mini=board?.thumbnail(opponentView(p.id));
    if(mini)article.append(h('button',{class:'opponent-miniature',type:'button','aria-label':`Spielplan von ${p.displayName} vergrößern`,onclick:()=>openOpponent(p)},mini));
   }return article;
  }));
 }
 function updateRoomPlayers(){
  const participants=game.participants.filter(p=>p.id!==profile.id),ids=new Set(participants.map(p=>p.id)),host=game.host.id===profile.id;
  for(const [id,row] of roomRows)if(!ids.has(id)){row.article.remove();roomRows.delete(id);}
  for(const p of participants){
   let row=roomRows.get(p.id);
   if(!row){
    const name=h('strong'),role=h('span',{class:'muted'}),score=h('small',{class:'opponent-score'}),picture=avatar(p),actions=h('div',{class:'player-actions'}),roller=h('span',{class:'roller-indicator',title:'Mit Würfeln dran','aria-label':'Mit Würfeln dran',hidden:true},icon('dice'));
    const article=h('article',{class:'lobby-player','data-player-id':p.id},picture,h('div',{class:'lobby-player-copy'},name,role,score),roller,actions);
    row={article,name,role,score,picture,actions,roller,avatarKey:JSON.stringify([p.displayName,p.avatarPath]),mini:null};roomRows.set(p.id,row);
   }
   const avatarKey=JSON.stringify([p.displayName,p.avatarPath]);if(row.avatarKey!==avatarKey){const picture=avatar(p);row.picture.replaceWith(picture);row.picture=picture;row.avatarKey=avatarKey;}
   renderSection(row.name,p.displayName,()=>p.displayName);renderSection(row.role,p.id===game.host.id,()=>p.id===game.host.id?'Host':'Mitspieler');
   const text=`${p.points||0} Punkte · ${p.eliminated?'ausgeschieden':p.hasPendingPowerup?'wählt Powerup':game.phase==='choosing'?(p.turnDone?'Zug gespeichert':'wählt noch'):'bereit'}`;
   renderSection(row.score,text,()=>text);row.roller.hidden=p.id!==game.rollerId;
   renderSection(row.actions,[host,game.status,commands.busy],()=>host&&!['finished','cancelled'].includes(game.status)?h('button',{class:'text-button',disabled:commands.busy,onclick:()=>manage('host',p.id)},'Host übergeben'):null);
   row.actions.hidden=!host||['finished','cancelled'].includes(game.status);
   if(game.settings.cards==='open'){
    if(!row.mini){const mini=board?.thumbnail(opponentView(p.id));if(mini){row.mini=h('button',{class:'opponent-miniature',type:'button',onclick:()=>openOpponent(game.participants.find(player=>player.id===p.id))},mini);row.article.append(row.mini);}}
    else board?.thumbnail(opponentView(p.id),row.mini.firstElementChild);
    const label=`Spielplan von ${p.displayName} vergrößern`;if(row.mini&&row.mini.getAttribute('aria-label')!==label)row.mini.setAttribute('aria-label',label);
   }
  }
  // Nur bei einer geänderten Reihenfolge bewegen; Realtime darf Bilder und
  // einen fokussierten Vorschauknopf nicht aus dem DOM herausnehmen.
  participants.forEach((p,i)=>{const row=roomRows.get(p.id).article;if(roomPlayers.children[i]!==row)roomPlayers.insertBefore(row,roomPlayers.children[i]||null);});
 }
 async function invite() {
  try {await navigator.clipboard.writeText(location.href);toast('Einladungslink kopiert.');}catch{prompt('Diesen Link an deine Freunde weitergeben:',location.href);}
 }
 function render() {
  if(!game||closed)return;const lobby=game.status==='lobby',host=game.host.id===profile.id,ended=['cancelled','finished'].includes(game.status);
  renderSection(heading,[lobby,game.name,game.map.name,game.host.displayName,game.status,game.settings],()=>[pageHeading(lobby?'Euer Warteraum':'Euer Spielraum',game.name,`${game.map.name} · Host: ${game.host.displayName}`),h('span',{class:`game-status ${game.status}`,id:'game-status'},gameStatusLabel(game)),settingsBadges(game.settings)]);
  const mode=lobby?'lobby':'room';
  if(currentMode!==mode){currentMode=mode;body.replaceChildren();}
  if(lobby) {
   body.replaceChildren(h('div',{class:'lobby-layout'},h('div',{class:'panel lobby-roster'},h('div',{class:'game-title-row'},h('h2',{},'Euer Trupp'),h('span',{class:'badge',id:'game-player-count'},`${game.playerCount} / ${game.settings.maxPlayers}`)),players(true)),
    h('aside',{class:'panel lobby-map'},mapMiniature(api,game.map),h('h2',{},game.map.name),h('p',{class:'muted'},`${game.map.fields} Felder · ${game.map.enemies} Gegner`),
     lobbyRules(definition),h('p',{class:'muted'},game.passwordRequired?'Dieser Warteraum ist mit einem Passwort geschützt.':'Freunde können ohne Spielpasswort beitreten.'),h('button',{class:'button secondary',onclick:invite},icon('upload'),'Einladungslink kopieren'))),
    h('div',{class:'lobby-controls panel'},h('div',{},h('h2',{},host?'Alle da?':'Wir warten auf den Start.'),h('p',{class:'muted'},host?'Mit dem Start wird der Warteraum geschlossen. Später können die Teilnehmer ihren Spielraum jederzeit wieder öffnen.':`${game.host.displayName} startet, sobald euer Trupp bereit ist.`)),
     h('div',{class:'button-row'},host?h('button',{id:'start-game',class:'button primary',disabled:commands.busy,onclick:()=>command('start_game',{p_game_id:gameId,p_expected_revision:game.revision})},icon('dice'),'Spiel starten'):null,
      h('button',{id:'leave-lobby',class:'button secondary',disabled:commands.busy,onclick:()=>{
       if(confirm(host&&game.playerCount>1?'Warteraum verlassen? Die Hostrolle übernimmt der nächste Teilnehmer.':'Warteraum verlassen?'))command('leave_game',{p_game_id:gameId},()=>{location.hash='#/play';});
      }},'Warteraum verlassen'))));
  } else {
   let top=body.querySelector('.room-management');
   if(!top){top=h('div',{class:'room-management'},roomOthers,roomControls);body.append(top);}
   renderSection(roomOthers,game.participants.length>1,()=>game.participants.length>1?roomPlayers:h('p',{class:'muted'},'Du bist allein in dieser Runde.'));updateRoomPlayers();
   renderSection(roomControls,[host,ended,game.status,playInstalled,rulesInstalled,game.settings.hints,commands.busy],()=>[
    h('p',{class:'phase-note',id:'game-phase-note'},ended?(game.status==='cancelled'?'Ohne Wertung abgebrochen.':'Dieses Abenteuer ist abgeschlossen.'):!playInstalled?'Zum Würfeln bitte 008_phase4.sql installieren.':rulesInstalled?'':'Powerups und Schlusswertung benötigen 010_phase5.sql.'),
     h('div',{class:'button-row'},host&&!ended?h('button',{id:'pause-game',class:'button secondary',disabled:commands.busy,onclick:()=>manage(game.status==='paused'?'resume':'pause')},game.status==='paused'?'Pause beenden':'Für alle pausieren'):null,
      host&&!ended?h('button',{id:'cancel-game',class:'text-button',disabled:commands.busy,onclick:()=>manage('cancel')},'Spiel abbrechen'):null,
      ended?h('button',{class:'button secondary',onclick:async()=>{try{const data=await api.authRpc('get_game_result',{p_game_id:gameId});if(!closed)resultsDialog(data.game);}catch(error){setFeedback(message,error.message);}}},'Chronik ansehen'):null)]);
   if(!board&&definition){board=boardPreview(api,definition,{onCell:chooseCell,onReady:()=>{if(!closed)render();}});
    if(playInstalled){body.append(panel.element,h('div',{class:'room-play'},board.element,panel.lives),panel.score);}else body.append(board.element);
   }
   if(playInstalled){panel.update({...game,definition},commands.busy||confirming,{torch:torchMode,middleCellId,axe:axeMode});board?.update({state:game.ownState,hints:fieldHints(game.settings),actions:highlightedActions(),middleCellId,claims:game.claims,markStyle:profile.preferences?.markStyle,interactive:game.turn?.canAct&&!commands.busy&&!confirming&&!torchLoading,fog:game.settings.fog&&game.status!=='finished',visibleCells:game.visibleCells,roundRequirements:game.roundRequirements,traps:game.traps});}
   opponent?.preview.update(opponentView(opponent.id));
  }
 }
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('get_game',{p_game_id:gameId,p_include_definition:!definition});if(closed)return;
   if(game&&data.game.revision<game.revision)return;
   game=data.game;definition=data.game.definition||definition;
   const key=`${game.round}:${game.turn?.ownRevision}`;if(ownKey!==key){ownKey=key;torchMode=false;axeMode=false;middleCellId=null;torchActions=[];}
   const nextPowerKey=game.turn?.pendingPowerup?`${game.ownState.pendingChests[0]}:${game.turn.ownRevision}`:null;
   if(powerDialog&&(powerKey!==nextPowerKey||game.status!=='playing'))powerDialog.close();
   setFeedback(message,'');render();openPowerup();
   if(game.status==='finished'&&!finishedShown){finishedShown=true;resultsDialog(game);const data=await api.authRpc('get_player_profile');if(!closed)ctx.updateProfile(data.profile);}
   if(lastEvent!==null){const fresh=(game.events||[]).filter(event=>Number(event.id)>lastEvent).sort((a,b)=>Number(a.id)-Number(b.id));
    for(const event of fresh){
     if(['enemy_defeated','bonus_completed'].includes(event.kind)){const name=game.participants.find(p=>p.id===event.payload.playerId)?.displayName;toast(event.kind==='bonus_completed'?(name?`${name} hat ${event.payload.name} abgeschlossen.`:`${event.payload.name} wurde abgeschlossen.`):name?`${name} hat ${event.payload.name} besiegt.`:`${event.payload.name} wurde besiegt.`);}
     if(event.kind==='trap_triggered'&&event.payload.costKind==='diamonds')toast(`Falle: ${event.payload.cost} Diamanten verloren.`);
     if(event.kind==='life_lost')toast(event.payload.cause==='trap'?`Falle: ${event.payload.amount} Leben verloren.`:event.payload.automatic?'Kein legaler Zug möglich: ein Leben verloren.':'Ein Leben verloren.');
    }
    const losses=fresh.filter(e=>e.kind==='life_lost');if(losses.length&&game.rulesVersion>=7&&game.status!=='finished'&&!document.querySelector('.life-loss-dialog'))lifeLossDialog(losses);
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
 return {element,cleanup:()=>{closed=true;watch.cleanup();board?.cleanup();opponent?.preview.cleanup();panel.cleanup();for(const dialog of document.querySelectorAll('.game-dialog'))dialog.close();}};
}
