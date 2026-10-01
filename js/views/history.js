import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {dateLabel,resultsDialog} from '../games/ui.js';

export function historyView({api,status}) {
 let closed=false,entries=[],cursor=null,hasMore=false,request=0,timer;
 const message=feedback(),list=h('div',{class:'history-list',id:'history-list'}),more=h('button',{class:'button secondary',id:'history-more',hidden:true,onclick:()=>load(true)},'Weitere Spiele');
 const search=h('input',{id:'history-search',type:'search',maxlength:100,placeholder:'Spiel, Karte oder Host …','aria-label':'Chronik durchsuchen',oninput:()=>{clearTimeout(timer);timer=setTimeout(()=>load(false),300);}});
 const scope=h('select',{id:'history-scope','aria-label':'Teilnahmefilter',onchange:()=>load(false)},h('option',{value:'all'},'Alle Spiele'),h('option',{value:'mine'},'Mit mir'),h('option',{value:'won'},'Meine Siege'));
 const finished=h('select',{id:'history-status','aria-label':'Ergebnisfilter',onchange:()=>load(false)},h('option',{value:'finished'},'Abgeschlossen'),h('option',{value:'cancelled'},'Abgebrochen'),h('option',{value:'all'},'Alle Ergebnisse'));
 const since=h('input',{id:'history-since',type:'date','aria-label':'Ab Datum',onchange:()=>load(false)}),until=h('input',{id:'history-until',type:'date','aria-label':'Bis Datum',onchange:()=>load(false)});
 const element=h('section',{class:'history-view'},h('a',{class:'back-link',href:'#/play'},icon('back'),'Zur Spielauswahl'),pageHeading('Die Chronik','Eure Abenteuer bleiben.','Ergebnisse, gemeinsame Siege und Erinnerungen an eure Runden.'),
  h('div',{class:'history-filters'},search,scope,finished,h('label',{},'Von',since),h('label',{},'Bis',until)),message,list,more);
 function dateBoundary(input,nextDay=false){if(!input.value)return null;const [y,m,d]=input.value.split('-').map(Number);return new Date(y,m-1,d+(nextDay?1:0)).toISOString();}
 function render() {
  list.replaceChildren(...entries.map(g=>{const winners=g.results.filter(r=>r.won);return h('article',{class:'history-card panel','data-game-id':g.id},h('div',{},h('p',{class:'eyebrow'},dateLabel(g.finishedAt)),h('h2',{},g.name),h('p',{class:'muted'},g.map.name),
   h('p',{class:'history-winners'},g.status==='cancelled'?'Ohne Wertung abgebrochen':winners.length?`${winners.length>1?'Gemeinsamer Sieg':'Sieg'}: ${winners.map(r=>r.displayName).join(' · ')}`:'Ergebnis wird noch bereitgestellt.')),
   h('button',{class:'button secondary',onclick:async()=>{try{const data=await api.authRpc('get_game_result',{p_game_id:g.id});if(!closed)resultsDialog(data.game);}catch(error){if(!closed)setFeedback(message,error.message);}}},'Ergebnis ansehen'));}));
  if(!entries.length)list.append(h('div',{class:'panel game-empty'},icon('book'),h('h2',{},'Hier beginnt eure Geschichte.'),h('p',{class:'muted'},'Noch keine passenden abgeschlossenen Spiele.')));more.hidden=!hasMore;
 }
 async function load(append=false) {
  const id=++request;more.disabled=true;
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('list_game_history',{p_scope:scope.value,p_query:search.value.trim(),p_status:finished.value,p_since:dateBoundary(since),p_until:dateBoundary(until,true),p_before:append?cursor?.finishedAt:null,p_before_id:append?cursor?.id:null,p_limit:30});
   if(closed||id!==request)return;entries=append?[...entries,...data.games]:data.games;hasMore=data.hasMore;cursor=entries.at(-1)||null;setFeedback(message,'');render();
  } catch(error){if(!closed&&id===request)setFeedback(message,error.message);}finally{if(!closed&&id===request)more.disabled=false;}
 }
 load();return {element,cleanup:()=>{closed=true;clearTimeout(timer);for(const dialog of document.querySelectorAll('.game-dialog'))dialog.close();}};
}
