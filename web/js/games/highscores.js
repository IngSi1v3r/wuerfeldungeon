import {h,feedback,setFeedback} from '../dom.js';
import {dateLabel} from './ui.js';

export function highscorePanel(api,{mapVersionId,gameId=null}={}){
 let closed=false,offset=0,loading=false,serial=0;
 const message=feedback(),entries=h('div',{class:'highscore-list'}),personal=h('p',{class:'personal-rank',hidden:true}),count=h('span');
 const opponents=h('select',{'aria-label':'Bestenliste nach Gegnerzahl filtern'},h('option',{value:''},'Alle Gegnerzahlen'),...Array.from({length:16},(_,n)=>h('option',{value:n},n?`${n} ${n===1?'Gegner':'Gegner'}`:'Ohne Gegner')));
 const red=h('select',{'aria-label':'Rotwürfel-Takt filtern'},h('option',{value:''},'Alle Rotwürfel-Takte'),...Array.from({length:16},(_,n)=>h('option',{value:n+1},n?`Rot jede ${n+1}. Runde`:'Rot jede Runde')));
 const previous=h('button',{type:'button',class:'button secondary',onclick:()=>{offset=Math.max(0,offset-30);load();}},'Zurück'),next=h('button',{type:'button',class:'button secondary',onclick:()=>{offset+=30;load();}},'Weitere Ergebnisse');
 const element=h('section',{class:'highscore-panel'},h('div',{class:'game-title-row'},h('h2',{},'Abenteuerwertung'),count),h('div',{class:'highscore-filters'},opponents,red),personal,message,entries,h('div',{class:'button-row highscore-pagination'},previous,next),h('details',{class:'rating-explanation'},h('summary',{},'Wie wird die Abenteuerwertung berechnet?'),h('p',{},'Punkte im Verhältnis zur erreichbaren Punktzahl zählen doppelt. Dazu kommt die Geschwindigkeit im Verhältnis zur Kartengröße, angepasst an den Rotwürfel-Takt. 100 ist ein Richtwert; höhere Werte sind möglich.'),h('p',{},'Wertung = 100 × (2 × Punkte / erwartete Punkte + Rotfaktor × Kartenaufwand / Runden) / 3. Monster zählen je benötigtem Treffer. Erstbelohnungen werden im Erwartungswert auf die Teilnehmer verteilt.')));
 function row(e){return h('details',{class:`highscore-row ${e.mine?'mine':''} ${e.current?'current':''}`,'data-score-player':e.playerId},
  h('summary',{},h('span',{class:'highscore-rank'},`#${e.rank}`),h('strong',{},e.displayName),h('span',{class:'highscore-value'},`${Math.round(e.rating)}`)),
  h('div',{class:'highscore-details'},h('span',{},`${e.points} Punkte`),h('span',{},`${e.rounds} Runden`),h('span',{},`${e.opponents} Gegner${e.aiOpponents?` · ${e.aiOpponents} KI (experimentell)`:''}`),h('span',{},e.redEvery===1?'Rot jede Runde':`Rot jede ${e.redEvery}. Runde`),h('small',{},dateLabel(e.completedAt))));}
 async function load(){
  const request=++serial;loading=true;previous.disabled=next.disabled=true;setFeedback(message,'');
  try{
   const data=await api.authRpc('list_highscores',{p_map_version_id:mapVersionId,p_opponents:opponents.value===''?null:Number(opponents.value),p_red_every:red.value===''?null:Number(red.value),p_game_id:gameId,p_offset:offset,p_limit:30});
   if(closed||request!==serial)return;
   entries.replaceChildren(...data.entries.map(row));if(!data.entries.length)entries.append(h('p',{class:'muted'},'Hier wartet noch der erste Eintrag.'));
   count.textContent=`${data.total} ${data.total===1?'Ergebnis':'Ergebnisse'}`;personal.hidden=!data.personal;
   if(data.personal)personal.textContent=`${gameId?'Diese Partie':'Dein bestes Ergebnis'}: Platz ${data.personal.rank} · ${Math.round(data.personal.rating)} Abenteuerwertung`;
   previous.disabled=offset===0;next.disabled=offset+30>=data.total;
  }catch(error){if(!closed&&request===serial)setFeedback(message,error.message);}
  finally{if(request===serial)loading=false;}
 }
 for(const input of [opponents,red])input.addEventListener('change',()=>{offset=0;load();});
 load();return {element,reload:load,cleanup(){closed=true;serial++;},isLoading:()=>loading};
}
