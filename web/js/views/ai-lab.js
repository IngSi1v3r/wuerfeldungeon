import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {GameCommands} from '../games/commands.js';
import {aiController} from '../games/ai-controller.js';
import {boardPreview} from '../games/board-preview.js';
import {resultsDialog,gameLink,dateLabel} from '../games/ui.js';
import {gameFullscreen} from '../games/fullscreen.js';

async function runRequestId(root,index){
 const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(`${root}:ai-test:${index}`))).slice(0,16);
 digest[6]=(digest[6]&15)|64;digest[8]=(digest[8]&63)|128;const hex=[...digest].map(n=>n.toString(16).padStart(2,'0')).join('');
 return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
export function aiLabView({api,profile,status,gameId,runs=1,toast=()=>{}}){
 let closed=false,controller=null,preview=null,current=null,definition=null,changing=false,switching=false,serial=0,refreshTimer=null;
 const root=gameId,total=Math.max(1,Math.min(10,Math.floor(runs)||1)),cacheKey=`wuerfeldungeon.ai-series.${root}`;
 let ids=root?[root]:[];
 try{const cached=JSON.parse(localStorage.getItem(cacheKey)||'null');if(Array.isArray(cached)&&cached[0]===root&&cached.every(v=>/^[a-f0-9-]{36}$/.test(v)))ids=cached.slice(0,total);}catch{/* Der Vergleich funktioniert auch ohne lokalen Komfort-Cache. */}
 let activeId=ids.at(-1),completed=0;
 const message=feedback(),summary=h('p',{id:'ai-lab-status',role:'status'}),controls=h('div',{class:'button-row'}),stage=h('div',{class:'ai-lab-stage'}),history=h('div',{class:'ai-lab-history'}),players=h('select',{id:'ai-lab-player','aria-label':'KI-Spielplan auswählen'}),scores=h('div',{class:'ai-lab-scores'}),series=h('div',{class:'ai-series-results'}),commands=new GameCommands(api);
 const fullscreen=gameFullscreen({toast});fullscreen.button.id='ai-lab-fullscreen';
 const pause=h('button',{id:'ai-lab-pause',type:'button',class:'button secondary',onclick:async()=>{
  if(!current||changing)return;changing=true;pause.disabled=true;
  try{const latest=(await api.authRpc('get_game',{p_game_id:activeId,p_include_definition:false})).game;
   await commands.run('manage_game',{p_game_id:activeId,p_action:latest.status==='paused'?'resume':'pause',p_expected_revision:latest.revision,p_target_player_id:null});await refresh();controller?.wake();}catch(e){setFeedback(message,e.message);}finally{changing=false;pause.disabled=false;}
 }},'Pausieren');
 const speed=h('select',{id:'ai-lab-speed','aria-label':'KI-Testtempo'},h('option',{value:40},'Schneller Testlauf'),h('option',{value:700},'Züge beobachten'));speed.value='40';
 const element=h('section',{class:'ai-lab-view'},pageHeading('KI-Labor · experimentell','Automatische Testpartien'),h('div',{class:'play-toolbar'},h('a',{class:'button primary',href:'#/solo'},icon('dice'),'Neue Testreihe · experimentell'),h('a',{class:'button secondary',href:'#/play'},icon('back'),'Spielauswahl'),fullscreen.button),message,summary,controls,stage,scores,series,history);
 controls.append(players,pause,speed);
 function showBoard(){
  if(!current||!preview)return;
  const player=current.participants.find(p=>p.id===players.value)||current.participants[0],entry=current.states?.find(s=>s.playerId===player?.id);
  preview.update({state:entry?.state||current.ownState,markStyle:player?.markStyle||'cross',interactive:false,hints:false,fog:current.settings.fog&&current.status!=='finished',visibleCells:entry?.visibleCells||current.visibleCells,roundRequirements:current.roundRequirements,claims:current.claims,traps:current.traps});
 }
 players.addEventListener('change',showBoard);
 function addResult(game,index){
  if(series.querySelector(`[data-series-game="${game.id}"]`))return;
  const best=game.results.reduce((max,r)=>r.adventureRating==null?max:Math.max(max,r.adventureRating),-Infinity);
  series.append(h('article',{class:'panel ai-series-row','data-series-game':game.id},h('strong',{},`Partie ${index+1}`),h('span',{},`${game.round} Runden`),h('span',{},Number.isFinite(best)?`Beste Abenteuerwertung: ${Math.round(best)}`:'Ohne Wertung'),
   h('div',{class:'ai-run-players'},...game.results.map(r=>h('span',{},`${r.displayName}: ${r.points} Punkte · ${r.adventureRating==null?'–':Math.round(r.adventureRating)}`))),h('button',{class:'button secondary',onclick:()=>resultsDialog(game,{api})},'Ergebnis & Replay')));
 }
 async function refresh(){
  if(closed||switching)return;const request=++serial,id=activeId;
  try{
   const data=await api.authRpc('get_game',{p_game_id:id,p_include_definition:!definition});if(closed||request!==serial||id!==activeId)return;
   const game=data.game;if(game.mode!=='ai_test')throw Error('Das KI-Labor zeigt nur experimentelle KI-Testpartien.');
   current=game;definition=game.definition||definition;
   if(!preview){preview=boardPreview(api,definition,{prefix:'ai-lab',title:game.map.name,onReady:showBoard});stage.replaceChildren(preview.element);}
   const selected=players.value;if(players.options.length!==game.participants.length){players.replaceChildren(...game.participants.map(p=>h('option',{value:p.id},p.displayName)));if(game.participants.some(p=>p.id===selected))players.value=selected;}
   pause.hidden=['finished','cancelled'].includes(game.status);pause.textContent=game.status==='paused'?'Fortsetzen':'Pausieren';
   summary.textContent=`${game.map.name} · Partie ${ids.length} / ${total} · Runde ${game.round} · ${game.status==='paused'?'Pausiert':game.status==='finished'?'Abgeschlossen':game.status==='cancelled'?'Abgebrochen':'KI spielt automatisch'}`;
   scores.replaceChildren(...game.participants.map(p=>h('span',{class:'badge'},`${p.displayName}: ${p.points} Punkte`)));showBoard();setFeedback(message,'');
   if(game.status==='finished'){
    controller?.cleanup();controller=null;addResult(game,ids.length-1);completed=ids.length;
    if(ids.length<total)await nextRun();else{summary.textContent+=` · Testreihe abgeschlossen (${completed} Partien)`;clearInterval(refreshTimer);await loadHistory();}
   }
  }catch(error){if(!closed)setFeedback(message,error.message);}
 }
 function launch(){controller?.cleanup();controller=aiController({api,gameId:activeId,delay:()=>Number(speed.value),onChange:refresh,onError:e=>setFeedback(message,e.message),enabled:()=>!changing});}
 async function nextRun(){
  switching=true;
  try{
   const requestId=await runRequestId(root,ids.length);
   const answer=await api.authRpc('create_solo_game',{p_map_version_id:current.map.versionId,p_name:`${current.map.name.slice(0,60)} · KI-Test ${ids.length+1}`,p_settings:current.settings,p_bot_count:current.participants.length,p_red_every:current.settings.redEvery,p_ai_only:true,p_request_id:requestId});if(closed)return;
   activeId=answer.gameId;ids.push(activeId);try{localStorage.setItem(cacheKey,JSON.stringify(ids));}catch{}
   current=null;preview?.cleanup();preview=null;definition=null;players.replaceChildren();launch();
  }catch(error){if(!closed)setFeedback(message,error.message);}
  finally{switching=false;if(!closed&&current===null)await refresh();}
 }
 async function loadHistory(){
  try{const data=await api.authRpc('list_ai_experiments',{p_limit:50});if(closed)return;
   history.replaceChildren(h('h2',{},'Deine KI-Testpartien · experimentell'),...data.games.map(g=>h('article',{class:'panel ai-history-row'},h('div',{},h('strong',{},g.name),h('small',{class:'muted'},`${dateLabel(g.createdAt)} · ${g.round} Runden · ${g.status==='finished'?'abgeschlossen':g.status==='paused'?'pausiert':'läuft'}`)),h('a',{class:'button secondary',href:g.status==='finished'?gameLink(g.id):`#/ai-lab?id=${g.id}`},g.status==='finished'?'Ergebnis ansehen':'Test fortsetzen'))));
   for(const [i,id] of ids.entries()){const g=data.games.find(g=>g.id===id&&g.status==='finished');if(g)addResult(g,i);}
  }catch(error){if(!closed)setFeedback(message,error.message);}
 }
 if(status?.soloAIVersion!==1){controls.hidden=true;setFeedback(message,'Bitte zuerst das Datenbank-Update 032 installieren.');}
 else if(!root){controls.hidden=true;summary.textContent='Eine Karte und die Anzahl der KI-Gegner im Einzelspiel auswählen. Dort lässt sich eine automatische Testreihe starten.';loadHistory();}
 else{launch();refresh();loadHistory();refreshTimer=setInterval(()=>{if(current?.status==='paused'||!controller)refresh();},2500);}
 return {element,cleanup(){closed=true;serial++;clearInterval(refreshTimer);controller?.cleanup();preview?.cleanup();fullscreen.cleanup();}};
}
