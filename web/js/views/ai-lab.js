import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {GameCommands} from '../games/commands.js';
import {aiController} from '../games/ai-controller.js';
import {boardPreview} from '../games/board-preview.js';
import {resultsDialog,dateLabel} from '../games/ui.js';
import {gameFullscreen} from '../games/fullscreen.js';
import {adventurerCharacter,ADVENTURER_COLORS} from '../games/adventurers.js';
import {visibleCells} from '../games/visibility.js';
import {roomLabel} from '../games/rules.js';
import {diceFace} from '../games/dice.js';

async function runRequestId(root,index){
 const digest=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(`${root}:ai-test:${index}`))).slice(0,16);digest[6]=(digest[6]&15)|64;digest[8]=(digest[8]&63)|128;const hex=[...digest].map(n=>n.toString(16).padStart(2,'0')).join('');return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
export function aiLabView({api,profile,status,gameId,runs=1,toast=()=>{}}){
 let closed=false,controller=null,preview=null,current=null,definition=null,changing=false,switching=false,refreshing=false,serial=0,refreshTimer=null,playTimer=null,viewRound=null,livePlans=null,focusCell=null;
 let frames=[],decisions=[],rolls=[],cursors={frame:0,decision:0,roll:0};
 const root=gameId,total=Math.max(1,Math.min(10,Math.floor(runs)||1)),cacheKey=`wuerfeldungeon.ai-series.${root}`;let ids=root?[root]:[];
 try{const cached=JSON.parse(localStorage.getItem(cacheKey)||'null');if(Array.isArray(cached)&&cached[0]===root&&cached.every(v=>/^[a-f0-9-]{36}$/.test(v)))ids=cached.slice(0,total);}catch{}
 let activeId=ids.at(-1);
 const message=feedback(),summary=h('p',{id:'ai-lab-status',role:'status'}),controls=h('div',{class:'adventurer-controls'}),stage=h('div',{class:'ai-lab-stage'}),history=h('div',{class:'ai-lab-history'}),players=h('select',{id:'ai-lab-player','aria-label':'Spielplan auswählen'}),scores=h('div',{class:'ai-lab-scores'}),series=h('div',{class:'ai-series-results'}),commands=new GameCommands(api);
 const fullscreen=gameFullscreen({toast});fullscreen.button.id='ai-lab-fullscreen';
 const pause=h('button',{id:'ai-lab-pause',type:'button',class:'button secondary',onclick:async()=>{
  if(!current||changing)return;changing=true;pause.disabled=true;try{const latest=(await api.authRpc('get_game',{p_game_id:activeId,p_include_definition:false})).game;
   await commands.run('manage_game',{p_game_id:activeId,p_action:latest.status==='paused'?'resume':'pause',p_expected_revision:latest.revision,p_target_player_id:null});await refresh();controller?.wake();}catch(e){setFeedback(message,e.message);}finally{changing=false;pause.disabled=false;}
 }},'Partie pausieren');
 const speed=h('select',{id:'ai-lab-speed','aria-label':'Tempo der Abenteurerprobe'},h('option',{value:40},'Schneller Durchlauf'),h('option',{value:700},'Züge beobachten'));speed.value='40';
 const analysisToggle=h('input',{id:'ai-lab-analysis',type:'checkbox'}),steps=h('input',{id:'ai-lab-steps',type:'checkbox'}),analysisPlayer=h('select',{id:'ai-analysis-player','aria-label':'Entscheidungen eines Abenteurers'}),analysisBody=h('div',{id:'ai-analysis-body'}),analysisBox=h('aside',{class:'adventurer-analysis',hidden:true},h('div',{class:'analysis-heading'},h('h2',{},'Entscheidungsanalyse · experimentell'),analysisPlayer),analysisBody);
 const advance=h('button',{id:'ai-lab-advance',type:'button',class:'button primary',hidden:true,onclick:()=>{viewRound=null;controller?.advance();showBoard();}},'Züge ausführen');
 const range=h('input',{id:'ai-lab-round',type:'range',min:0,max:1,value:0,'aria-label':'Runde im Verlauf'}),position=h('strong',{id:'ai-lab-position'}),prev=h('button',{id:'ai-lab-prev',class:'button secondary',type:'button','aria-label':'Vorherige Runde',onclick:()=>seek((viewRound??maxRound())-1)},'←'),next=h('button',{id:'ai-lab-next',class:'button secondary',type:'button','aria-label':'Nächste Runde',onclick:()=>seek((viewRound??maxRound())+1)},'→'),play=h('button',{id:'ai-lab-replay',class:'button secondary',type:'button',onclick:togglePlayback},'Verlauf abspielen'),live=h('button',{id:'ai-lab-live',class:'button secondary',type:'button',onclick:()=>{stopPlayback();viewRound=null;showBoard();}},'Live');
 const timeline=h('div',{class:'adventurer-timeline'},prev,play,next,position,range,live),rollDisplay=h('div',{class:'adventurer-dice',id:'ai-lab-dice','aria-label':'Wurf dieser Runde'}),workspace=h('div',{class:'adventurer-workspace'},stage,analysisBox);
 const element=h('section',{class:'ai-lab-view'},pageHeading('Experimentell','Abenteurerprobe'),h('div',{class:'play-toolbar'},h('a',{class:'button primary',href:'#/solo'},icon('dice'),'Neue Abenteurerprobe · experimentell'),h('a',{class:'button secondary',href:'#/play'},icon('back'),'Spielauswahl'),fullscreen.button),message,summary,controls,scores,timeline,rollDisplay,workspace,series,history);
 controls.append(h('label',{},'Ansicht',players),pause,speed,h('label',{class:'experiment-check'},analysisToggle,'Bewertungen anzeigen'),h('label',{class:'experiment-check'},steps,'Nach jedem Wurf anhalten'),advance);
 function maxRound(){return Math.max(0,current?.round||0,...rolls.map(r=>r.round||0),...frames.filter(f=>!f.initial).map(f=>f.round||0));}
 function stopPlayback(){clearInterval(playTimer);playTimer=null;play.textContent='Verlauf abspielen';}
 function seek(round){stopPlayback();viewRound=Math.max(0,Math.min(maxRound(),round));focusCell=null;showBoard();}
 function togglePlayback(){if(playTimer){stopPlayback();return;}if(viewRound==null||viewRound>=maxRound())viewRound=0;play.textContent='Verlauf stoppen';showBoard();playTimer=setInterval(()=>{if(closed||viewRound>=maxRound()){stopPlayback();return;}viewRound++;showBoard();},600);}
 range.addEventListener('input',()=>seek(Number(range.value)));
 function playerState(player,round){
  if(viewRound==null){const live=current.states?.find(s=>s.playerId===player.id);if(live)return live.state;}
  const candidates=frames.filter(f=>f.playerId===player.id&&(f.initial?0:f.round)<=round);return candidates.at(-1)?.state||{reached:[],monsterHits:{}};
 }
 function decisionFor(playerId,round){
  if(viewRound==null&&livePlans?.round===round){const p=livePlans.plans.find(p=>p.bot.playerId===playerId&&p.bot.canAct);if(p)return {analysis:p.analysis,stateBefore:p.bot.state,dice:p.bot.dice,round,playerId};}
  return decisions.filter(d=>d.playerId===playerId&&d.round===round&&['cell','lose_life'].includes(d.kind)).at(-1)||null;
 }
 function showBoard(){
  if(!current||!preview)return;const round=viewRound??current.round,all=players.value==='all',selected=current.participants.find(p=>p.id===players.value)||current.participants[0],choice=analysisToggle.checked?decisionFor(analysisPlayer.value,round):null;
  const entries=current.participants.map((p,i)=>({...p,name:p.displayName,label:String(i+1),color:p.color||ADVENTURER_COLORS[i%8],state:playerState(p,round)}));
  const own=entries.find(p=>p.id===selected?.id),states=entries.map(p=>p.state),state=all?{reached:(states[0]?.reached||[]).filter(id=>states.every(s=>s.reached?.includes(id))),monsterHits:Object.fromEntries(definition.document.rooms.filter(r=>r.hits).map(r=>[String(r.id),Math.min(...states.map(s=>s.monsterHits?.[String(r.id)]||0))]))}:choice?.playerId===own?.id?choice.stateBefore:own?.state||{};
  const roundFrame=frames.filter(f=>f.round<=round&&!f.initial).at(-1),requirements=viewRound==null?current.roundRequirements:roundFrame?.roundRequirements||{};
  const visible=current.settings.fog?[...new Set((all?states:[state]).flatMap(s=>visibleCells(definition,s)))]:null;
  preview.update({state,markStyle:all?'cross':selected?.markStyle||'cross',overlays:all?entries:null,hideBaseMarks:all,interactive:Boolean(analysisToggle.checked),hints:false,fog:Boolean(current.settings.fog),visibleCells:visible,roundRequirements:requirements,claims:(current.claims||[]).filter(c=>c.claimedInRound<=round).map(c=>({...c,firstAvailable:c.claimedInRound===round,ownFirst:(all?states:[state]).some(s=>s.firstKills?.includes(String(c.cellId)))})),traps:(current.traps||[]).filter(t=>t.activatedInRound<=round).map(t=>({...t,armed:t.activatedInRound<round})),analysis:choice?.analysis||null});
  position.textContent=viewRound==null?`Live · Runde ${round}`:round?`Runde ${round}`:'Vor dem ersten Zug';range.max=String(maxRound());range.value=String(round);prev.disabled=round<=0;next.disabled=round>=maxRound();live.classList.toggle('primary',viewRound==null);
  advance.hidden=!steps.checked||current.status!=='playing';advance.disabled=current.phase!=='choosing'||!livePlans?.plans.some(p=>p.bot.canAct||p.bot.pendingChest)||changing;advance.textContent=current.phase==='choosing'?'Züge dieser Runde ausführen':'Nächster Wurf wird vorbereitet …';
  const dice=choice?.dice||(viewRound==null?current.dice:null)||rolls.findLast(r=>r.round===round)?.dice||roundFrame?.dice;rollDisplay.replaceChildren(...(Array.isArray(dice)?dice.map((v,i)=>diceFace(v,i===3,i)):[]));rollDisplay.hidden=!Array.isArray(dice);
  renderAnalysis(choice,round);renderScores(entries);
 }
 function renderScores(entries){
  const key=JSON.stringify(entries.map(p=>[p.id,p.state.reached,p.state.monsterHits,p.state.diamonds,p.state.goldPoints,p.state.lostLives]));if(scores.dataset.key===key)return;scores.dataset.key=key;
  scores.replaceChildren(...entries.map(p=>h('button',{type:'button',class:'adventurer-seat',style:`--adventurer-color:${p.color}`,'data-adventurer-player':p.id,onclick:()=>{players.value=p.id;analysisPlayer.value=p.id;focusCell=null;showBoard();}},h('span',{class:'adventurer-emblem'},adventurerCharacter(p.character).symbol),h('span',{},h('strong',{},`${p.label} · ${p.displayName}`),h('small',{},`${adventurerCharacter(p.character).name} · ${p.state.diamonds||0} ♦`)),h('span',{class:'experimental-badge'},'experimentell'))));
 }
 function renderAnalysis(choice,round){
  analysisBox.hidden=!analysisToggle.checked;workspace.classList.toggle('with-analysis',analysisToggle.checked);if(!analysisToggle.checked)return;
  const key=JSON.stringify([choice,round,focusCell]);if(analysisBody.dataset.key===key)return;analysisBody.dataset.key=key;
  if(!choice){analysisBody.replaceChildren(h('p',{class:'muted'},round===0?'Noch keine Entscheidung.':'Für diese Runde liegt noch keine Zugbewertung vor. Ältere Partien enthalten erst ab diesem Update ein Analyseprotokoll.'));return;}
  const a=choice.analysis,character=adventurerCharacter(a.character||choice.character),parts={points:'Punkte',combat:'Kampffortschritt',exploration:'Wege und Möglichkeiten',goals:'Bonusaufgaben',safety:'Sicherheit',resources:'Hilfsmittel',contest:'Konkurrenz'};
  function label(c){const room=definition.document.rooms.find(r=>String(r.id)===c.cellId),middle=definition.document.rooms.find(r=>String(r.id)===c.middleCellId);return c.kind==='lose_life'?'Ein Leben verlieren':`${room?roomLabel(room):`Feld ${c.cellId}`}${middle?` · über #${middle.id}`:''}${c.useRed?' · Rot':''}${c.useAxe?' · Axt':''}`;}
  const candidates=(a.candidates||[]).filter(c=>!focusCell||c.cellId===focusCell||c.middleCellId===focusCell),selected=a.candidates?.find(c=>c.key===a.selected),number=n=>Number(n||0).toFixed(1);
  const table=h('table',{class:'analysis-table'},h('thead',{},h('tr',{},...['Zug','Jetzt','Vorausblick','Gesamt'].map(s=>h('th',{},s)))),h('tbody',{},...candidates.map(c=>h('tr',{class:c.key===a.selected?'chosen':'','data-candidate-key':c.key},h('td',{},c.key===a.selected?h('strong',{},'★ '):null,label(c)),h('td',{},number(c.immediate)),h('td',{},number(c.forecast)),h('td',{},h('strong',{},number(c.score)))))));
  analysisBody.replaceChildren(...[h('p',{class:'analysis-summary'},`${character.name} · Runde ${round} · ${a.depth||0} Folgerunden`),selected?h('p',{class:'analysis-choice'},'Gewählt: ',h('strong',{},label(selected))):null,
   focusCell?h('button',{class:'text-button',onclick:()=>{focusCell=null;showBoard();}},'Alle Züge anzeigen'):null,h('div',{class:'analysis-table-wrap'},table),
   h('details',{class:'analysis-breakdown'},h('summary',{},'Wie entsteht die Bewertung?'),h('p',{},'Gesamt = Veränderung jetzt + erwarteter weiterer Gewinn × 0,8 + seltene Gelegenheit + Charakterzufall. Die Zahlen sind interne Vergleichswerte, keine Spielpunkte.'),selected?h('dl',{},...Object.entries(selected.parts||{}).flatMap(([key,value])=>[h('dt',{},parts[key]||key),h('dd',{},number(value))]),h('dt',{},'Seltene Gelegenheit'),h('dd',{},number(selected.opportunity)),h('dt',{},'Charakterzufall'),h('dd',{},number(selected.noise))):null,
    h('small',{},`${a.samples||0} Würfelstichproben in der ersten, ${a.secondSamples||0} je zweite Folgerunde; bis zu ${a.beam||0} gute erste Fortsetzungen. ${a.knownRooms||0} bekannte Felder. Verdeckte Informationen und fremde künftige Züge werden nicht vorausgesagt.`))].filter(Boolean));
 }
 players.addEventListener('change',()=>{if(players.value!=='all')analysisPlayer.value=players.value;focusCell=null;showBoard();});analysisPlayer.addEventListener('change',()=>{focusCell=null;showBoard();});analysisToggle.addEventListener('change',showBoard);steps.addEventListener('change',()=>{if(steps.checked){analysisToggle.checked=true;controller?.hold();}else controller?.wake();showBoard();});
 function addResult(game,index){if(series.querySelector(`[data-series-game="${game.id}"]`))return;const best=game.results.reduce((max,r)=>r.adventureRating==null?max:Math.max(max,r.adventureRating),-Infinity);
  series.append(h('article',{class:'panel ai-series-row','data-series-game':game.id},h('strong',{},`Partie ${index+1}`),h('span',{},`${game.round} Runden`),h('span',{},Number.isFinite(best)?`Beste Abenteuerwertung: ${Math.round(best)}`:'Ohne Wertung'),h('div',{class:'ai-run-players'},...game.results.map(r=>h('span',{},`${r.displayName}: ${r.points} Punkte · ${r.adventureRating==null?'–':Math.round(r.adventureRating)}`))),h('button',{class:'button secondary',onclick:()=>resultsDialog(game,{api})},'Ergebnis & Replay'),h('a',{class:'button secondary',href:`#/ai-lab?id=${game.id}`},'Runden & Analyse')));
 }
 async function readJournal(id){let more=true;for(let page=0;page<20&&more&&!closed;page++){
  const data=await api.authRpc('get_adventurer_journal',{p_game_id:id,p_after_frame:cursors.frame,p_after_decision:cursors.decision,p_after_roll:cursors.roll});if(closed||id!==activeId)return;
  frames.push(...data.frames);decisions.push(...data.decisions);rolls.push(...data.rolls);cursors={frame:data.frames.at(-1)?.id??cursors.frame,decision:data.decisions.at(-1)?.id??cursors.decision,roll:data.rolls.at(-1)?.id??cursors.roll};more=data.more;
 }}
 async function refresh(){if(closed||switching||refreshing)return;refreshing=true;const request=++serial,id=activeId;
  try{
   const data=await api.authRpc('get_game',{p_game_id:id,p_include_definition:!definition});if(closed||request!==serial||id!==activeId)return;const game=data.game;if(game.mode!=='ai_test')throw Error('Die Abenteurerprobe zeigt automatische Einzelspieler-Testpartien.');
   await readJournal(id);if(closed||id!==activeId)return;current=game;definition=game.definition||definition;
   if(!preview){preview=boardPreview(api,definition,{prefix:'ai-lab',title:game.map.name,onCell:id=>{focusCell=id;showBoard();},onReady:showBoard});stage.replaceChildren(preview.element);}
   if(players.options.length!==game.participants.length+1){const selected=players.value;players.replaceChildren(h('option',{value:'all'},'Alle Abenteurer gemeinsam'),...game.participants.map(p=>h('option',{value:p.id},p.displayName)));players.value=selected||'all';analysisPlayer.replaceChildren(...game.participants.map(p=>h('option',{value:p.id},p.displayName)));}
   pause.hidden=['finished','cancelled'].includes(game.status);pause.textContent=game.status==='paused'?'Partie fortsetzen':'Partie pausieren';summary.textContent=`${game.map.name} · Partie ${ids.length} / ${total} · Runde ${game.round} · ${game.status==='paused'?'Pausiert':game.status==='finished'?'Abgeschlossen':game.status==='cancelled'?'Abgebrochen':'Abenteurer spielen automatisch'}`;showBoard();setFeedback(message,'');
   if(game.status==='finished'){controller?.cleanup();controller=null;addResult(game,ids.length-1);if(ids.length<total)await nextRun();else{summary.textContent+=` · Testreihe abgeschlossen (${ids.length} Partien)`;clearInterval(refreshTimer);await loadHistory();}}
  }catch(error){if(!closed)setFeedback(message,error.message);}finally{refreshing=false;}
 }
 function launch(){controller?.cleanup();controller=aiController({api,gameId:activeId,delay:()=>Number(speed.value),onChange:refresh,onError:e=>setFeedback(message,e.message),enabled:()=>!changing&&!switching,stepMode:()=>steps.checked,onAnalysis:plans=>{livePlans=plans;if(current){showBoard();}}});}
 async function nextRun(){switching=true;try{
  const answer=await api.authRpc('create_solo_game',{p_map_version_id:current.map.versionId,p_name:`${current.map.name.slice(0,55)} · Abenteurerprobe ${ids.length+1}`,p_settings:current.settings,p_bot_count:current.participants.length,p_red_every:current.settings.redEvery,p_ai_only:true,p_request_id:await runRequestId(root,ids.length)});if(closed)return;
  activeId=answer.gameId;ids.push(activeId);try{localStorage.setItem(cacheKey,JSON.stringify(ids));}catch{}current=null;preview?.cleanup();preview=null;definition=null;players.replaceChildren();frames=[];decisions=[];rolls=[];cursors={frame:0,decision:0,roll:0};viewRound=null;livePlans=null;focusCell=null;launch();
 }catch(error){if(!closed)setFeedback(message,error.message);}finally{switching=false;if(!closed&&current===null){refreshing=false;await refresh();}}}
 async function loadHistory(){try{const data=await api.authRpc('list_ai_experiments',{p_limit:50});if(closed)return;history.replaceChildren(h('h2',{},'Deine Abenteurerproben · experimentell'),...data.games.map(g=>h('article',{class:'panel ai-history-row'},h('div',{},h('strong',{},g.name),h('small',{class:'muted'},`${dateLabel(g.createdAt)} · ${g.round} Runden · ${g.status==='finished'?'abgeschlossen':g.status==='paused'?'pausiert':'läuft'}`)),h('a',{class:'button secondary',href:`#/ai-lab?id=${g.id}`},g.status==='finished'?'Verlauf & Analyse':'Probe fortsetzen'))));for(const [i,id] of ids.entries()){const g=data.games.find(g=>g.id===id&&g.status==='finished');if(g)addResult(g,i);}}
 catch(error){if(!closed)setFeedback(message,error.message);}}
 if(status?.adventurerVersion!==2){controls.hidden=true;timeline.hidden=true;setFeedback(message,'Bitte zuerst das Datenbank-Update 034 installieren.');}
 else if(!root){controls.hidden=true;timeline.hidden=true;workspace.hidden=true;summary.textContent='Im Einzelspiel eine Karte und Mitreisende auswählen und „Nur Abenteurer spielen“ aktivieren.';loadHistory();}
 else{launch();refresh();loadHistory();refreshTimer=setInterval(()=>{if(current?.status==='paused'||!controller)refresh();},2500);}
 return {element,cleanup(){closed=true;serial++;clearInterval(refreshTimer);stopPlayback();controller?.cleanup();preview?.cleanup();fullscreen.cleanup();}};
}
