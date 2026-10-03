import {h,feedback,setFeedback} from '../dom.js';
import {boardPreview} from './board-preview.js';
import {pointsSoFar} from './rules.js';

export function replayDialog(api,gameId){
 let closed=false,preview=null,data=null,frames=[],index=0,timer=null;
 const message=feedback(),stage=h('div'),players=h('select',{id:'replay-player','aria-label':'Spieler auswählen'}),speed=h('select',{id:'replay-speed','aria-label':'Wiedergabegeschwindigkeit'},h('option',{value:500},'Schnell'),h('option',{value:1000},'Normal'),h('option',{value:180},'Sehr schnell')),
 range=h('input',{id:'replay-position',type:'range',min:0,max:0,value:0,'aria-label':'Stand der Wiederholung'}),info=h('p',{class:'replay-info',role:'status'}),play=h('button',{id:'replay-play',class:'button primary',onclick:()=>timer?pause():start()},'Abspielen');
 function pause(){clearInterval(timer);timer=null;play.textContent='Abspielen';}
 function show(){const frame=frames[index];if(!frame)return;range.value=String(index);preview?.update({state:frame.state,roundRequirements:frame.roundRequirements,fog:false,interactive:false,hints:false,markStyle:'pencil'});info.textContent=`Runde ${frame.round} · ${index+1} / ${frames.length} · ${pointsSoFar(frame.state)} Punkte`;}
 function start(){if(!frames.length)return;if(index===frames.length-1)index=0;show();play.textContent='Pause';timer=setInterval(()=>{if(index>=frames.length-1){pause();return;}index++;show();},Number(speed.value));}
 function choose(){pause();const p=data.players.find(p=>p.id===players.value);frames=p?.frames||[];index=0;range.max=String(Math.max(0,frames.length-1));play.disabled=!frames.length;setFeedback(message,!frames.length?'Für diesen Spieler wurde noch kein Verlauf aufgezeichnet.':p.complete?'':'Dieser Verlauf beginnt beim Einspielen des Updates; frühere Züge sind nicht enthalten.','info');show();}
 range.addEventListener('input',()=>{pause();index=Number(range.value);show();});players.addEventListener('change',choose);speed.addEventListener('change',()=>{if(timer){pause();start();}});
 const controls=h('div',{class:'replay-controls',hidden:true},players,play,speed,range),dialog=h('dialog',{class:'game-dialog replay-dialog','aria-label':'Spiel wiederholen'},h('h2',{},'Wiederholung'),controls,info,stage,message,h('button',{class:'button secondary',onclick:()=>dialog.close()},'Schließen'));
 dialog.addEventListener('close',()=>{closed=true;pause();preview?.cleanup();dialog.remove();},{once:true});document.body.append(dialog);dialog.showModal();
 api.authRpc('get_game_replay',{p_game_id:gameId}).then(result=>{if(closed)return;data=result;if(!data.available){setFeedback(message,'Für diese ältere Partie gibt es noch keine aufgezeichnete Wiederholung.','info');return;}
 players.append(...data.players.map(p=>h('option',{value:p.id},p.displayName)));preview=boardPreview(api,data.definition,{prefix:'replay',title:data.game.map.name,onReady:show});stage.append(preview.element);controls.hidden=false;choose();
 }).catch(error=>{if(!closed)setFeedback(message,error.message);});return dialog;
}
