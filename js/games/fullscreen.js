import {h,icon} from '../dom.js';

// Das gesamte Dokument bleibt die Vollbildwurzel: Dialoge und Meldungen
// außerhalb des Spielplans sind dadurch auch im nativen Vollbild sichtbar.
export function gameFullscreen({toast}){
 let closed=false,ownsFullscreen=false,orientationLocked=false;
 const button=h('button',{id:'game-fullscreen',type:'button',class:'table-icon-button',title:'Vollbild','aria-label':'Vollbild einschalten','aria-pressed':false,onclick:toggle},icon('fullscreen'));
 const active=()=>document.fullscreenElement||document.webkitFullscreenElement;
 function update(){if(closed)return;const on=Boolean(active());button.setAttribute('aria-pressed',String(on));button.title=on?'Vollbild verlassen':'Vollbild';button.setAttribute('aria-label',on?'Vollbild verlassen':'Vollbild einschalten');button.replaceChildren(icon(on?'minimize':'fullscreen'));if(!on){ownsFullscreen=false;if(orientationLocked){screen.orientation?.unlock?.();orientationLocked=false;}}}
 async function toggle(){
  try{
   if(active()){await (document.exitFullscreen?.()??document.webkitExitFullscreen?.());return;}
   const request=document.documentElement.requestFullscreen||document.documentElement.webkitRequestFullscreen;
   if(!request){toast('Die Spielansicht füllt bereits das Fenster. Am Handy erhältst du im Querformat mehr Platz.');return;}
   await request.call(document.documentElement);ownsFullscreen=true;
   if(closed){const exit=document.exitFullscreen||document.webkitExitFullscreen;await exit?.call(document);return;}
   if(matchMedia('(pointer: coarse)').matches&&screen.orientation?.lock){try{await screen.orientation.lock('landscape');orientationLocked=true;if(closed){screen.orientation.unlock();orientationLocked=false;}}catch{/* Nicht jeder mobile Browser erlaubt eine Orientierungssperre. */}}
  }catch{toast('Vollbild ist hier nicht verfügbar. Die Spielansicht bleibt über das ganze Fenster geöffnet.');}
  update();
 }
 document.addEventListener('fullscreenchange',update);document.addEventListener('webkitfullscreenchange',update);
 update();
 return {button,cleanup(){closed=true;document.removeEventListener('fullscreenchange',update);document.removeEventListener('webkitfullscreenchange',update);if(orientationLocked){screen.orientation?.unlock?.();orientationLocked=false;}if(ownsFullscreen&&active()){const exit=document.exitFullscreen||document.webkitExitFullscreen;try{const result=exit?.call(document);result?.catch?.(()=>{});}catch{}}}};
}
