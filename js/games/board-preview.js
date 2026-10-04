import {viewVisibility} from './visibility.js';
import {h,icon,feedback} from '../dom.js';
import {MapAssets} from '../maps/model.js';
import {activeAttacks,roomLabel} from './rules.js';
import {markingPrimitives} from '../markings.js';

// Die bestehende Zeichenlogik liefert den SVG-Spielplan. Im Spielraum bleibt
// davon nur das Bild, ohne Editor-Menüs, Durchgangsknöpfe oder Schreibfunktionen.
// Eigenes Pan/Zoom unterstützt Maus, ein Finger und Zwei-Finger-Zoom.
export function boardPreview(api,definition,{onCell=()=>{},onContextCell=()=>{},onReady=()=>{},template=null,title='Dein Spielplan',prefix='game'}={}) {
 let closed=false,frame=null,svg=null,base=null,box=null,pristine=null,pointers=new Map(),pinch=null,tap=null,view=null,art=new Map();
 const ns='http://www.w3.org/2000/svg',rooms=definition.document.rooms;
 const painted=new WeakMap();
 const sv=(tag,attrs={})=>{const node=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))node.setAttribute(k,String(v));return node;};
 const attr=(node,key,value)=>{const text=String(value);if(node.getAttribute(key)!==text)node.setAttribute(key,text);};
 const toggle=(node,key,value)=>{if(node.classList.contains(key)!==Boolean(value))node.classList.toggle(key,Boolean(value));};
 const stage=h('div',{class:'game-board-stage',id:`${prefix}-board-stage`},h('p',{class:'board-loading',role:'status'},h('span',{class:'loader'}),'Spielplan wird geladen …'));
 function setBox(next){box=next;svg?.setAttribute('viewBox',box.join(' '));}
 function metrics(){const rect=svg.getBoundingClientRect(),scale=Math.min(rect.width/box[2],rect.height/box[3]);return {rect,scale,dx:(rect.width-box[2]*scale)/2,dy:(rect.height-box[3]*scale)/2};}
 function focal(x,y){const {rect,scale,dx,dy}=metrics();return [(x-rect.left-dx)/(box[2]*scale),(y-rect.top-dy)/(box[3]*scale)];}
 function zoom(factor,cx=.5,cy=.5) {
  if(!box)return;const width=Math.max(base[2]/12,Math.min(base[2]*3,box[2]*factor)),ratio=width/box[2],height=box[3]*ratio;
  setBox([box[0]+(box[2]-width)*cx,box[1]+(box[3]-height)*cy,width,height]);
 }
 const element=h('section',{class:'game-board-wrap'},h('div',{class:'game-board-toolbar'},h('span',{class:'muted'},title),h('div',{class:'button-row'},
  h('button',{class:'button secondary',title:'Verkleinern','aria-label':'Verkleinern',onclick:()=>zoom(1.25)},'−'),h('button',{class:'button secondary',title:'Vergrößern','aria-label':'Vergrößern',onclick:()=>zoom(.8)},'+'),h('button',{class:'button secondary',onclick:()=>base&&setBox([...base])},icon('map'),'Alles zeigen'))),stage);
 function wire() {
  svg.addEventListener('wheel',event=>{event.preventDefault();zoom(event.deltaY<0?.9:1.1,...focal(event.clientX,event.clientY));},{passive:false});
  svg.addEventListener('contextmenu',event=>{event.preventDefault();const id=event.target.closest('[data-cell-id]')?.getAttribute('data-cell-id');if(id&&view?.contextInteractive)onContextCell(id);});
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
 function update(next){view=next;toggle(stage,'fog-active',next.fog);if(svg)paint(svg,next);}
 function paint(canvas,next){
  if(next.fog)next={...next,visibleCells:viewVisibility(definition,next.state,next.visibleCells,next.now??Date.now())};
  let previous=painted.get(canvas);
  if(!previous){
   previous={marks:canvas.querySelector('.game-progress-marks'),targets:new Map([...canvas.querySelectorAll('.game-cell-target')].map(n=>[n.getAttribute('data-cell-id'),n])),
    infos:new Map([...canvas.querySelectorAll('.enemy-info')].map(n=>[n.getAttribute('data-id'),n])),marked:new Map([...canvas.querySelectorAll('[data-marked-cell]')].map(n=>[n.getAttribute('data-marked-cell'),n])),
    rooms:new Map([...canvas.querySelectorAll('.room[data-id]')].map(n=>[n.getAttribute('data-id'),n])),images:new Map([...canvas.querySelectorAll('.enemy-image[data-id]')].map(n=>[n.getAttribute('data-id'),n])),
    crazy:new Map(),traps:new Map()};
   painted.set(canvas,previous);
  }
  const key=JSON.stringify([next.state?.reached,next.state?.monsterHits,next.hints?next.actions:null,next.claims,next.markStyle,next.interactive,next.middleCellId,next.roundRequirements,next.traps,next.fog,next.visibleCells,next.contextInteractive]);
  if(previous.key===key)return;previous.key=key;
  const state=next.state||{},reached=new Set((state.reached||[]).map(String)),legal=new Map((next.hints?next.actions||[]:[]).map(a=>[String(a.cellId),a])),claims=new Map((next.claims||[]).map(c=>[String(c.cellId),c]));
  attr(canvas,'data-fog',Boolean(next.fog));
  const {marks,targets,infos,marked}=previous,style=next.markStyle||'pencil',visible=next.fog?new Set((next.visibleCells||[]).map(String)):null;
  const trapStates=new Map((next.traps||[]).map(t=>[String(t.cellId),t]));
  paintFog(canvas,previous,next);
  for(const r of rooms){const id=String(r.id),done=reached.has(id),action=legal.get(id),target=targets.get(id),seen=!visible||visible.has(id),info=infos.get(id),imageGroup=previous.images.get(id),roomGroup=previous.rooms.get(id);
   for(const group of [roomGroup,info,imageGroup,marked.get(id)])if(group)attr(group,'visibility',seen?'visible':'hidden');
   if(target){
    attr(target,'visibility',seen||next.contextInteractive?'visible':'hidden');attr(target,'aria-hidden',!seen);attr(target,'tabindex',seen?0:-1);
    toggle(target,'legal-cell',action&&next.interactive);toggle(target,'red-cell',action?.redOnly&&next.interactive);toggle(target,'reached-cell',done);toggle(target,'torch-middle',next.middleCellId===id);
    const shownRoom=r.type==='crazy'?{...r,number:next.roundRequirements?.[id]??null}:r;
    attr(target,'aria-label',seen?`${roomLabel(shownRoom)}${r.type==='trap'&&trapStates.get(id)?.armed?' · scharf':''}${done?' · erreicht':''}${action&&next.interactive?` · ${action.redOnly?'mit rotem Würfel':'spielbar'}`:''}`:'Im Nebel');attr(target,'aria-disabled',!seen||!next.interactive||done);
   }
   if(r.type==='crazy'&&roomGroup){
    const value=String(next.roundRequirements?.[id]??'?');
    if(previous.crazy.get(id)!==value){
     let numbers=roomGroup.querySelector('[data-crazy-value]');
     if(!numbers){for(const child of [...roomGroup.children])if(!child.classList.contains('room-body')&&!child.hasAttribute('data-crazy-icon')&&child.tagName!=='rect')child.remove();numbers=sv('g',{'data-crazy-value':true});roomGroup.append(numbers);}
     const primitives=art.get(id)?.numbers?.[value]||[{tag:'text',text:'?',attrs:{x:r.x*24+r.w*12,y:r.y*24+r.h*24*.77,'text-anchor':'middle','dominant-baseline':'central','font-size':30,fill:'#653d74'}}];
     numbers.replaceChildren(...primitives.map(p=>{const n=sv(p.tag,p.attrs);if(p.matrix)n.setAttribute('transform',`matrix(${p.matrix.join(' ')})`);if(p.text!=null)n.textContent=p.text;return n;}));attr(numbers,'data-number',value);previous.crazy.set(id,value);
    }
   }
   if(r.type==='trap'&&roomGroup){
    const armed=Boolean(trapStates.get(id)?.armed);toggle(roomGroup,'armed-trap',armed);
    let badge=roomGroup.querySelector('[data-trap-armed]');
    if(armed&&!badge){badge=sv('text',{'data-trap-armed':true,x:r.x*24+r.w*24-12,y:r.y*24+18,'text-anchor':'end','font-size':16,'font-weight':'bold',fill:'#a33b27'});badge.textContent='!';roomGroup.append(badge);}
    else if(!armed)badge?.remove();
   }
   if(imageGroup){
    const sprite=art.get(id),chosen=done&&sprite?.defeated?sprite.defeated:sprite?.alive;
    if(sprite){let image=imageGroup.querySelector('image');if(chosen){if(!image){image=sv('image');imageGroup.append(image);}for(const [name,value] of Object.entries(chosen))attr(image,name,value);attr(image,'data-defeated',done&&Boolean(sprite.defeated));attr(image,'visibility',seen?'visible':'hidden');}else if(image)attr(image,'visibility','hidden');}
   }
   const x=r.x*24+9,y=r.y*24+9,w=r.w*24-18,h=r.h*24-18;
   const oldMark=marked.get(id);
   if(oldMark&&(!done||!oldMark.classList.contains(style))){oldMark.remove();marked.delete(id);}
   if(done&&!marked.has(id)){const g=sv('g',{'data-marked-cell':id,class:`played-mark ${style}`});
    for(const p of markingPrimitives(style,x,y,w,h))g.append(sv(p.tag,p.attrs));
    attr(g,'visibility',seen?'visible':'hidden');marks.append(g);marked.set(id,g);
   }
   if(!info)continue;
   const hits=state.monsterHits?.[id]||0;for(const rect of info.querySelectorAll('[data-hit]'))attr(rect,'fill',Number(rect.getAttribute('data-hit'))<=hits?'#375b48':'#fff');
   const active=new Set(activeAttacks(r,definition.rules,state));for(const node of info.querySelectorAll('[data-attack]')){
    const unlocked=active.has(node.getAttribute('data-attack'));attr(node,'data-state',unlocked?'active':'locked');
    const color=unlocked?'#172b3b':'#9aa3ac';if(node.tagName==='text')attr(node,'fill',color);else for(const n of [node,...node.querySelectorAll('*')])for(const property of ['fill','stroke'])if(['#9aa3ac','#172b3b'].includes(n.getAttribute(property)))attr(n,property,color);
   }
   const strike=info.querySelector('[data-reward-strike]'),claim=claims.get(id),first=info.querySelector('[data-enemy-reward="1"]'),needed=claim&&!claim.ownFirst&&!claim.firstAvailable&&r.rewardFirst>0&&first;
   if(!needed)strike?.remove();
   else if(!strike){const b=JSON.parse(first.getAttribute('data-strike-bounds')||'null')||first.getBBox();info.append(sv('path',{'data-reward-strike':true,d:`M ${b.x-2} ${b.y+b.height/2} L ${b.x+b.width+2} ${b.y+b.height/2}`,stroke:'#a34238','stroke-width':1.7}));}
  }
 }
 function paintFog(canvas,previous,next){
  const key=JSON.stringify([Boolean(next.fog),next.visibleCells,next.state?.reached]);if(previous.fogKey===key)return;previous.fogKey=key;
  let layer=canvas.querySelector('.game-fog'),defs=canvas.querySelector('.game-fog-defs');
  if(!next.fog){layer?.remove();defs?.remove();return;}
  if(!layer){layer=sv('g',{class:'game-fog','pointer-events':'none','aria-hidden':true});canvas.insertBefore(layer,canvas.querySelector('.game-cell-targets'));}
  if(!defs){defs=sv('defs',{class:'game-fog-defs'});canvas.prepend(defs);}
  const uid=`fog-${crypto.randomUUID()}`,maskId=uid+'-mask',haloId=uid+'-halo',cloudId=uid+'-cloud';
  const mask=sv('mask',{id:maskId,maskUnits:'userSpaceOnUse',x:base[0],y:base[1],width:base[2],height:base[3]});
  mask.append(sv('rect',{x:base[0],y:base[1],width:base[2],height:base[3],fill:'white'}));
  const halo=sv('filter',{id:haloId,x:'-35%',y:'-35%',width:'170%',height:'170%'});
  halo.append(sv('feTurbulence',{type:'fractalNoise',baseFrequency:'.018',numOctaves:2,seed:8,result:'noise'}),sv('feDisplacementMap',{in:'SourceGraphic',in2:'noise',scale:25,xChannelSelector:'R',yChannelSelector:'G'}),sv('feGaussianBlur',{stdDeviation:15}));
  const visible=new Set((next.visibleCells||[]).map(String)),reached=new Set((next.state?.reached||[]).map(String));
  const halos=sv('g',{filter:`url(#${haloId})`});
  for(const r of rooms)if(reached.has(String(r.id)))halos.append(sv('rect',{x:r.x*24-120,y:r.y*24-120,width:r.w*24+240,height:r.h*24+240,rx:100,fill:'black'}));
  mask.append(halos);
  // Halo reveals landscape only. Hidden rooms and their immediate surroundings
  // stay opaque; exact visible rooms are cut out last, so no neighbor is lost.
  for(const r of rooms)if(!visible.has(String(r.id)))mask.append(sv('rect',{x:r.x*24-48,y:r.y*24-48,width:r.w*24+96,height:r.h*24+96,rx:16,fill:'white'}));
  for(const r of rooms)if(visible.has(String(r.id)))mask.append(sv('rect',{x:r.x*24-5,y:r.y*24-5,width:r.w*24+10,height:r.h*24+10,rx:5,fill:'black'}));
  const cloud=sv('filter',{id:cloudId,x:'0%',y:'0%',width:'100%',height:'100%'});
  cloud.append(sv('feTurbulence',{type:'fractalNoise',baseFrequency:'.009 .014',numOctaves:3,seed:31}),sv('feColorMatrix',{type:'saturate',values:0}));
  defs.replaceChildren(halo,cloud,mask);
  const surface=sv('g',{mask:`url(#${maskId})`});surface.append(sv('rect',{x:base[0],y:base[1],width:base[2],height:base[3],fill:'#263c39'}),sv('rect',{class:'fog-cloud-texture',x:base[0]-100,y:base[1]-100,width:base[2]+200,height:base[3]+200,fill:'#96aba1',opacity:.2,filter:`url(#${cloudId})`}));layer.replaceChildren(surface);
 }
 async function load() {
  try {
   if(template){svg=document.importNode(template.svg,true);base=[...template.base];art=new Map(Array.isArray(template.art)?template.art:[]);finish();return;}
   const hydrated=await new MapAssets(api,null,null).hydrate(definition.document);if(closed)return;
   frame=h('iframe',{class:'board-render-frame',src:'./editor/index.html',title:'Spielplan vorbereiten','aria-hidden':'true',tabindex:-1});
   const ready=new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Der Spielplan konnte nicht vorbereitet werden. Bitte erneut laden.')),20000);frame.onload=()=>{clearTimeout(timer);const bridge=frame.contentWindow?.DungeonEditor;if(bridge)resolve(bridge);else reject(Error('Die Editor-Dateien fehlen. Bitte den Ordner editor vollständig hochladen.'));};});
   stage.append(frame);const bridge=await ready;if(closed)return;bridge.setReadOnly(true);await bridge.load(hydrated);bridge.fit();art=new Map((bridge.getGameArt?.()||[]).map(r=>[r.id,r]));
   const original=frame.contentDocument.querySelector('#board');svg=document.importNode(original,true);svg.id=`${prefix}-board-svg`;svg.setAttribute('role','group');svg.setAttribute('aria-label','Spielplan · Feld antippen, ziehen zum Verschieben, zwei Finger zum Zoomen');
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
   for(const sprite of art.values())if(sprite.defeated)bounds.push({x:sprite.defeated.x,y:sprite.defeated.y,width:sprite.defeated.width,height:sprite.defeated.height});
   const left=Math.min(...bounds.map(b=>b.x)),top=Math.min(...bounds.map(b=>b.y)),right=Math.max(...bounds.map(b=>b.x+b.width)),bottom=Math.max(...bounds.map(b=>b.y+b.height));
   base=[left-24,top-24,right-left+48,bottom-top+48];if(base.some(n=>!Number.isFinite(n))||base[2]<=0||base[3]<=0)throw Error('Der Spielplan hat ungültige Bildgrenzen.');
   stage.replaceChildren(svg);
   for(const first of svg.querySelectorAll('[data-enemy-reward="1"]')){const {x,y,width,height}=first.getBBox();first.setAttribute('data-strike-bounds',JSON.stringify({x,y,width,height}));}
   frame.remove();frame=null;finish();
  } catch(error){frame?.remove();frame=null;if(!closed)stage.replaceChildren(feedback(error.message),h('button',{class:'button secondary',onclick:load},'Spielplan erneut laden'));}
 }
 function finish(){
  pristine=svg.cloneNode(true);pristine.id='';
  if(prefix!=='game')for(const n of svg.querySelectorAll('[id]'))n.removeAttribute('id');
  svg.id=`${prefix}-board-svg`;
  const marks=sv('g',{id:`${prefix}Marks`,class:'game-progress-marks','pointer-events':'none'}),targets=sv('g',{id:`${prefix}Targets`,class:'game-cell-targets'});
  svg.insertBefore(marks,svg.querySelector('.enemy-info')?.parentNode||null);
  for(const r of rooms)targets.append(sv('rect',{x:r.x*24+6,y:r.y*24+6,width:r.w*24-12,height:r.h*24-12,rx:3,fill:'transparent','data-cell-id':r.id,role:'button',tabindex:0,class:'game-cell-target','aria-label':roomLabel(r)}));
  svg.append(targets);stage.replaceChildren(svg);setBox([...base]);wire();if(view)update(view);onReady();
 }
 function getTemplate(){return pristine?{svg:pristine,base:[...base],art:[...art]}:null;}
 function thumbnail(next,existing=null){
  if(!svg)return null;
  if(existing){paint(existing,{...next,interactive:false,hints:false});return existing;}
  const clone=svg.cloneNode(true);clone.setAttribute('viewBox',base.join(' '));clone.setAttribute('aria-hidden','true');clone.removeAttribute('role');clone.removeAttribute('aria-label');
  for(const n of [clone,...clone.querySelectorAll('[id]')])n.removeAttribute('id');
  clone.querySelector('.game-fog')?.remove();clone.querySelector('.game-fog-defs')?.remove();paint(clone,{...next,interactive:false,hints:false});clone.querySelector('.game-cell-targets')?.remove();
  return clone;
 }
 load();return {element,update,getTemplate,thumbnail,cleanup:()=>{closed=true;frame?.remove();pointers.clear();tap=null;}};
}
