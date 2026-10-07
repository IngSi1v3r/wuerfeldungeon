import {h,feedback,setFeedback,pageHeading} from '../dom.js';
import {highscorePanel} from '../games/highscores.js';

export function highscoresView({api,status}){
 let closed=false,panel=null;
 const message=feedback(),select=h('select',{id:'highscore-map','aria-label':'Karte für Bestenliste wählen'}),content=h('div');
 const element=h('section',{class:'highscores-view'},pageHeading('Bestenlisten','Eure Abenteuerwertung'),h('div',{class:'panel'},h('label',{class:'map-form-label'},'Karte',select),message,content));
 function show(){panel?.cleanup();panel=select.value?highscorePanel(api,{mapVersionId:select.value}):null;content.replaceChildren(panel?.element||h('p',{class:'muted'},'Noch keine veröffentlichte Karte.'));}
 select.addEventListener('change',show);
 if(status?.highscoreVersion!==1)setFeedback(message,'Bitte zuerst das Datenbank-Update 032 installieren.');
 else api.authRpc('list_highscore_maps').then(data=>{if(closed)return;select.append(...data.maps.map(m=>h('option',{value:m.versionId},`${m.name} · ${m.entries} ${m.entries===1?'Ergebnis':'Ergebnisse'}`)));show();}).catch(e=>{if(!closed)setFeedback(message,e.message);});
 return {element,cleanup(){closed=true;panel?.cleanup();}};
}
