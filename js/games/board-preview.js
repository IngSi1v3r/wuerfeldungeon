import {h,icon,feedback} from '../dom.js';
import {MapAssets} from '../maps/model.js';
import {activeAttacks,roomLabel} from './rules.js';

// Die bestehende Zeichenlogik liefert den SVG-Spielplan. Im Spielraum bleibt
// davon nur das Bild, ohne Editor-Menüs, Durchgangsknöpfe oder Schreibfunktionen.
// Eigenes Pan/Zoom unterstützt Maus, ein Finger und Zwei-Finger-Zoom.
export function boardPreview(api,definition,{onCell=()=>{}}={}) {
 let closed=false,frame=null,svg=null,base=null,box=null,pointers=new Map(),pinch=null,tap=null,view=null;
 const ns='http://www.w3.org/2000/svg',rooms=definition.document.rooms;
 const sv=(tag,attrs={})=>{const node=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))node.setAttribute(k,String(v));return node;};
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
  svg.addEventListener('pointerdown',event=>{if(event.button>1)return;event.preventDefault();try{svg.setPointerCapture(event.pointerId);}catch{/* Synthetische Eingabe ohne aktive Pointer-ID. */}pointers.set(event.pointerId,{x:event.clientX,y:event.clientY});pinch=null;tap=pointers.size===1&&event.button===0?{id:event.target.closest('[data-cell-id]')?.getAttribute('data-cell-id'),pointer:event.pointerId,x:event.clientX,y:event.clientY}:null;});
  svg.addEventListener('pointermove',event=>{
   const previous=pointers.get(event.pointerId);if(!previous)return;const next={x:event.clientX,y:event.clientY};pointers.set(event.pointerId,next);const {scale}=metrics();
   if(tap&&Math.hypot(next.x-tap.x,next.y-tap.y)>7)tap=null;
   if(pointers.size===1)setBox([box[0]-(next.x-previous.x)/scale,box[1]-(next.y-previous.y)/scale,box[2],box[3]]);
   else {const [a,b]=[...pointers.values()],distance=Math.hypot(a.x-b.x,a.y-b.y);if(pinch&&distance>0)zoom(pinch/distance,...focal((a.x+b.x)/2,(a.y+b.y)/2));pinch=distance;}
  });
  svg.addEventListener('pointerup',e=>{const target=tap;tap=null;pointers.delete(e.pointerId);pinch=null;if(target?.id&&target.pointer===e.pointerId&&view?.interactive)onCell(target.id);});
  for(const event of ['pointercancel','lostpointercapture'])svg.addEventListener(event,e=>{pointers.delete(e.pointerId);pinch=null;tap=null;});
  svg.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)&&e.target.hasAttribute('data-cell-id')){e.preventDefault();if(view?.interactive)onCell(e.target.getAttribute('data-cell-id'));}});
 }
 function update(next){view=next;if(!svg)return;
  const state=next.state||{},reached=new Set((state.reached||[]).map(String)),legal=new Map((next.hints?next.actions||[]:[]).map(a=>[String(a.cellId),a])),claims=new Map((next.claims||[]).map(c=>[String(c.cellId),c]));
  const marks=svg.querySelector('#gameMarks'),targets=svg.querySelector('#gameTargets');marks.replaceChildren();
  for(const r of rooms){const id=String(r.id),done=reached.has(id),action=legal.get(id),target=[...targets.children].find(n=>n.getAttribute('data-cell-id')===id);
   target.classList.toggle('legal-cell',Boolean(action&&next.interactive));target.classList.toggle('red-cell',Boolean(action?.redOnly&&next.interactive));target.classList.toggle('reached-cell',done);
   target.setAttribute('aria-label',`${roomLabel(r)}${done?' · erreicht':''}${action&&next.interactive?` · ${action.redOnly?'mit rotem Würfel':'spielbar'}`:''}`);target.setAttribute('aria-disabled',String(!next.interactive||done));
   const x=r.x*24+9,y=r.y*24+9,w=r.w*24-18,h=r.h*24-18;
   if(done){const g=sv('g',{'data-marked-cell':id,class:`played-mark ${next.markStyle||'pencil'}`});
    if(next.markStyle==='solid')g.append(sv('rect',{x,y,width:w,height:h,rx:5,fill:'#20352a',opacity:.3}));
    else if(next.markStyle==='cross')g.append(sv('path',{d:`M ${x} ${y} L ${x+w} ${y+h} M ${x+w} ${y} L ${x} ${y+h}`,stroke:'#263932','stroke-width':3,opacity:.5,fill:'none'}));
    else if(next.markStyle==='waves'){
     for(let dy=6;dy<h;dy+=14)g.append(sv('path',{d:`M ${x} ${y+dy} Q ${x+w/4} ${y+dy-8} ${x+w/2} ${y+dy} T ${x+w} ${y+dy}`,stroke:'#263932','stroke-width':1.6,opacity:.35,fill:'none'}));
    }else{
     // Eine schmale Schraffur; keine Raster-/Raumgeometrie wird verändert.
     for(let dy=8;dy<h;dy+=12)g.append(sv('path',{d:`M ${x+3} ${y+dy} L ${x+w-3} ${y+dy-5}`,stroke:'#263932','stroke-width':1.4,opacity:.33,fill:'none'}));
    }marks.append(g);
   }
   const info=[...svg.querySelectorAll('.enemy-info')].find(n=>n.getAttribute('data-id')===id);if(!info)continue;
   const hits=state.monsterHits?.[id]||0;for(const rect of info.querySelectorAll('[data-hit]'))rect.setAttribute('fill',Number(rect.getAttribute('data-hit'))<=hits?'#375b48':'#fff');
   const active=new Set(activeAttacks(r,definition.rules,state));for(const node of info.querySelectorAll('[data-attack]')){
    const unlocked=active.has(node.getAttribute('data-attack'));node.setAttribute('data-state',unlocked?'active':'locked');
    const color=unlocked?'#172b3b':'#9aa3ac';if(node.tagName==='text')node.setAttribute('fill',color);else for(const n of [node,...node.querySelectorAll('*')])for(const attr of ['fill','stroke'])if(['#9aa3ac','#172b3b'].includes(n.getAttribute(attr)))n.setAttribute(attr,color);
   }
   info.querySelector('[data-reward-strike]')?.remove();const claim=claims.get(id),first=info.querySelector('[data-enemy-reward="1"]');
   if(claim&&!claim.ownFirst&&r.rewardFirst>0&&first){const b=first.getBBox();info.append(sv('path',{'data-reward-strike':true,d:`M ${b.x-2} ${b.y+b.height/2} L ${b.x+b.width+2} ${b.y+b.height/2}`,stroke:'#a34238','stroke-width':1.7}));}
  }
 }
 async function load() {
  try {
   const hydrated=await new MapAssets(api,null,null).hydrate(definition.document);if(closed)return;
   frame=h('iframe',{class:'board-render-frame',src:'./editor/index.html',title:'Spielplan vorbereiten','aria-hidden':'true',tabindex:-1});
   const ready=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Der Spielplan konnte nicht vorbereitet werden. Bitte erneut laden.')),20000);frame.onload=()=>{clearTimeout(timer);const bridge=frame.contentWindow?.DungeonEditor;if(bridge)resolve(bridge);else reject(Error('Die Editor-Dateien fehlen. Bitte den Ordner editor vollständig hochladen.'));};});
   stage.append(frame);const bridge=await ready;if(closed)return;bridge.setReadOnly(true);await bridge.load(hydrated);bridge.fit();
   const original=frame.contentDocument.querySelector('#board');svg=document.importNode(original,true);svg.id='game-board-svg';svg.setAttribute('role','group');svg.setAttribute('aria-label','Spielplan · Feld antippen, ziehen zum Verschieben, zwei Finger zum Zoomen');
   // Feldfüllungen stammen im Editor aus CSS. Als SVG-Attribute übernehmen,
   // damit keine globalen Editor-Styles die Spieloberfläche beeinflussen.
   const originals=[...original.querySelectorAll('.room-body')];[...svg.querySelectorAll('.room-body')].forEach((body,i)=>{const style=frame.contentWindow.getComputedStyle(originals[i]);for(const property of ['fill','stroke','stroke-width'])body.setAttribute(property,style.getPropertyValue(property));});
   for(const id of ['doorsLayer','selectionLayer','gridPlane'])svg.querySelector(`#${id}`)?.remove();
   // Der Editor zeichnet Pasch als neun SVG-Teile. Zusammenfassen, damit beim
   // Freischalten beide Würfel samt Punkten und Gleichheitszeichen mitfärben.
   for(const first of [...svg.querySelectorAll('[data-pasch][data-attack]')]){
    const group=sv('g',{'data-attack':first.getAttribute('data-attack'),'data-state':first.getAttribute('data-state')});first.parentNode.insertBefore(group,first);
    let node=first;for(let i=0;i<9&&node;i++){const next=node.nextSibling;group.append(node);node=next;}first.removeAttribute('data-attack');first.removeAttribute('data-state');
   }
   const bounds=['backgroundLayer','roomsLayer','wallsLayer','enemyImagesLayer','enemyInfoLayer'].map(id=>original.querySelector(`#${id}`)).filter(layer=>layer?.children.length).map(layer=>layer.getBBox());
   const left=Math.min(...bounds.map(b=>b.x)),top=Math.min(...bounds.map(b=>b.y)),right=Math.max(...bounds.map(b=>b.x+b.width)),bottom=Math.max(...bounds.map(b=>b.y+b.height));
   base=[left-24,top-24,right-left+48,bottom-top+48];if(base.some(n=>!Number.isFinite(n))||base[2]<=0||base[3]<=0)throw Error('Der Spielplan hat ungültige Bildgrenzen.');
   const marks=sv('g',{id:'gameMarks','pointer-events':'none'}),targets=sv('g',{id:'gameTargets'});svg.insertBefore(marks,svg.querySelector('#enemyInfoLayer'));
   for(const r of rooms){const target=sv('rect',{x:r.x*24+6,y:r.y*24+6,width:r.w*24-12,height:r.h*24-12,rx:3,fill:'transparent','data-cell-id':r.id,role:'button',tabindex:0,class:'game-cell-target','aria-label':roomLabel(r)});targets.append(target);}svg.append(targets);
   stage.replaceChildren(svg);frame.remove();frame=null;setBox([...base]);wire();if(view)update(view);
  } catch(error){frame?.remove();frame=null;if(!closed)stage.replaceChildren(feedback(error.message),h('button',{class:'button secondary',onclick:load},'Spielplan erneut laden'));}
 }
 load();return {element,update,cleanup:()=>{closed=true;frame?.remove();pointers.clear();tap=null;}};
}
