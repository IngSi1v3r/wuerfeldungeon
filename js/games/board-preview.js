import {h,icon,feedback} from '../dom.js';
import {MapAssets} from '../maps/model.js';

// Die bestehende Zeichenlogik liefert den SVG-Spielplan. Im Spielraum bleibt
// davon nur das Bild, ohne Editor-Menüs, Durchgangsknöpfe oder Schreibfunktionen.
// Eigenes Pan/Zoom unterstützt Maus, ein Finger und Zwei-Finger-Zoom.
export function boardPreview(api,definition) {
 let closed=false,frame=null,svg=null,base=null,box=null,pointers=new Map(),pinch=null;
 const stage=h('div',{class:'game-board-stage',id:'game-board-stage'},h('p',{class:'board-loading',role:'status'},h('span',{class:'loader'}),'Spielplan wird geladen …'));
 function setBox(next){box=next;svg?.setAttribute('viewBox',box.join(' '));}
 function metrics(){const rect=svg.getBoundingClientRect(),scale=Math.min(rect.width/box[2],rect.height/box[3]);return {rect,scale,dx:(rect.width-box[2]*scale)/2,dy:(rect.height-box[3]*scale)/2};}
 function focal(x,y){const {rect,scale,dx,dy}=metrics();return [(x-rect.left-dx)/(box[2]*scale),(y-rect.top-dy)/(box[3]*scale)];}
 function zoom(factor,cx=.5,cy=.5) {
  if(!box)return;const width=Math.max(base[2]/12,Math.min(base[2]*3,box[2]*factor)),ratio=width/box[2],height=box[3]*ratio;
  setBox([box[0]+(box[2]-width)*cx,box[1]+(box[3]-height)*cy,width,height]);
 }
 const element=h('section',{class:'game-board-wrap'},h('div',{class:'game-board-toolbar'},h('span',{class:'muted'},'Dein Spielplan'),h('div',{class:'button-row'},
  h('button',{class:'button secondary',title:'Verkleinern','aria-label':'Verkleinern',onclick:()=>zoom(1.25)},'−'),h('button',{class:'button secondary',title:'Vergrößern','aria-label':'Vergrößern',onclick:()=>zoom(.8)},'+'),h('button',{class:'button secondary',onclick:()=>base&&setBox([...base])},icon('map'),'Alles zeigen'))),stage);
 function wire() {
  svg.addEventListener('wheel',event=>{event.preventDefault();zoom(event.deltaY<0?.9:1.1,...focal(event.clientX,event.clientY));},{passive:false});
  svg.addEventListener('contextmenu',event=>event.preventDefault());
  svg.addEventListener('pointerdown',event=>{if(event.button>1)return;event.preventDefault();try{svg.setPointerCapture(event.pointerId);}catch{/* Synthetische Eingabe ohne aktive Pointer-ID. */}pointers.set(event.pointerId,{x:event.clientX,y:event.clientY});pinch=null;});
  svg.addEventListener('pointermove',event=>{
   const previous=pointers.get(event.pointerId);if(!previous)return;const next={x:event.clientX,y:event.clientY};pointers.set(event.pointerId,next);const {scale}=metrics();
   if(pointers.size===1)setBox([box[0]-(next.x-previous.x)/scale,box[1]-(next.y-previous.y)/scale,box[2],box[3]]);
   else {const [a,b]=[...pointers.values()],distance=Math.hypot(a.x-b.x,a.y-b.y);if(pinch&&distance>0)zoom(pinch/distance,...focal((a.x+b.x)/2,(a.y+b.y)/2));pinch=distance;}
  });
  for(const event of ['pointerup','pointercancel','lostpointercapture'])svg.addEventListener(event,e=>{pointers.delete(e.pointerId);pinch=null;});
 }
 async function load() {
  try {
   const hydrated=await new MapAssets(api,null,null).hydrate(definition.document);if(closed)return;
   frame=h('iframe',{class:'board-render-frame',src:'./editor/index.html',title:'Spielplan vorbereiten','aria-hidden':'true',tabindex:-1});
   const ready=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Der Spielplan konnte nicht vorbereitet werden. Bitte erneut laden.')),20000);frame.onload=()=>{clearTimeout(timer);const bridge=frame.contentWindow?.DungeonEditor;if(bridge)resolve(bridge);else reject(Error('Die Editor-Dateien fehlen. Bitte den Ordner editor vollständig hochladen.'));};});
   stage.append(frame);const bridge=await ready;if(closed)return;bridge.setReadOnly(true);await bridge.load(hydrated);bridge.fit();
   const original=frame.contentDocument.querySelector('#board');svg=document.importNode(original,true);svg.id='game-board-svg';svg.setAttribute('role','img');svg.setAttribute('aria-label','Spielplan · ziehen zum Verschieben, zwei Finger zum Zoomen');
   // Feldfüllungen stammen im Editor aus CSS. Als SVG-Attribute übernehmen,
   // damit keine globalen Editor-Styles die Spieloberfläche beeinflussen.
   const originals=[...original.querySelectorAll('.room-body')];[...svg.querySelectorAll('.room-body')].forEach((body,i)=>{const style=frame.contentWindow.getComputedStyle(originals[i]);for(const property of ['fill','stroke','stroke-width'])body.setAttribute(property,style.getPropertyValue(property));});
   for(const id of ['doorsLayer','selectionLayer','gridPlane'])svg.querySelector(`#${id}`)?.remove();
   const bounds=['backgroundLayer','roomsLayer','wallsLayer','enemyImagesLayer','enemyInfoLayer'].map(id=>original.querySelector(`#${id}`)).filter(layer=>layer?.children.length).map(layer=>layer.getBBox());
   const left=Math.min(...bounds.map(b=>b.x)),top=Math.min(...bounds.map(b=>b.y)),right=Math.max(...bounds.map(b=>b.x+b.width)),bottom=Math.max(...bounds.map(b=>b.y+b.height));
   base=[left-24,top-24,right-left+48,bottom-top+48];if(base.some(n=>!Number.isFinite(n))||base[2]<=0||base[3]<=0)throw Error('Der Spielplan hat ungültige Bildgrenzen.');
   stage.replaceChildren(svg);frame.remove();frame=null;setBox([...base]);wire();
  } catch(error){frame?.remove();frame=null;if(!closed)stage.replaceChildren(feedback(error.message),h('button',{class:'button secondary',onclick:load},'Spielplan erneut laden'));}
 }
 load();return {element,cleanup:()=>{closed=true;frame?.remove();pointers.clear();}};
}
