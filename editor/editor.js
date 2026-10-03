import {FORMAT as NEW_FORMAT,TYPES,newRules,compileDocument,upgradeDocument,goalText} from '../js/maps/features.js';
import {printScorePlan,scoreTrackRows,paintPrintScore,paintPrintStatus} from './print-tracks.js';

(() => {
  'use strict';
  const SVG_NS = 'http://www.w3.org/2000/svg';
  const CELL = 24;
  const DIM = { normal:[4,4], diamond:[4,8], chest:[4,8], special:[4,4], rune:[4,4], bonus:[8,8], trap:[4,4], portal:[4,4], crazy:[4,4], goldSack:[4,8], goldCoin:[4,8], monster:[8,8], miniboss:[8,8], boss:[16,8] };
  const TYPE_NAMES = {...TYPES,normal:'Zahlenfeld',diamond:'Diamant',chest:'Schatzkiste',special:'Runenfeld',monster:'Monster',miniboss:'Bonusaufgabe',boss:'Boss'};
  const COLORS = {rune:['#f4efff','#7958ab'],bonus:['#fff','#625e54'],trap:['#fff1eb','#a65539'],portal:['#e9f5f1','#39847b'],crazy:['#fff','#625e54'],goldSack:['#fff9da','#a98224'],goldCoin:['#fff9da','#a98224'],normal:['#fff','#5b7182'],diamond:['#ecf7ff','#3481b5'],chest:['#fff7d6','#a98224'],special:['#f4efff','#7958ab'],monster:['#fff','#625e54'],miniboss:['#fff','#625e54'],boss:['#fff','#625e54']};
  const FORMAT = NEW_FORMAT;let documentFormat=FORMAT,rules=newRules(),allowedPowerups=['extraLife','redDice','torch'];const defeatedPreviews=new Set();let canonicalPaint=false;
  const imageKey=r=>defeatedPreviews.has(r.id)?'defeatedImage':'image',enemyLayoutKey=r=>defeatedPreviews.has(r.id)?'defeatedImageLayout':'imageLayout';
  const validNumber=n=>n==='doubles'||Number.isInteger(n)&&n>=2&&n<=12;
  const numberOrder=n=>n==='doubles'?13:n;
  const compareAttacks=(a,b)=>numberOrder(a.number)-numberOrder(b.number);
  const isEnemy = r => ['monster','miniboss','boss','bonus'].includes(r.type);
  const resizable = r => ['diamond','chest','goldSack','goldCoin','monster','miniboss','boss','bonus'].includes(r.type);
  const minSize = r => ['miniboss','bonus'].includes(r.type)?4:isEnemy(r)?8:4;
  const STORAGE_KEY = 'dungeon-layout-editor-v1';
  const board = document.getElementById('board');
  const viewport = document.getElementById('viewport');
  const roomsLayer = document.getElementById('roomsLayer');
  const doorsLayer = document.getElementById('doorsLayer');
  const wallsLayer = document.getElementById('wallsLayer');
  const enemyImagesLayer = document.getElementById('enemyImagesLayer');
  const enemyInfoLayer = document.getElementById('enemyInfoLayer');
  const menu = document.getElementById('numberMenu');
  const numbers = document.getElementById('numbers');
  let readOnly=true,modeApplied=false,changeListener=null,importListener=null,exportListener=null,saveListener=null;
  let rooms = [], closedDoors = {}, nextId = 1, selected = new Set(), activeId = null;
  let zoom = 1, panX = 0, panY = 0, drag = null, history = [], future = [];
  let menuRoomId = null, toastTimer = null;
  let background=null,backgroundEdit=false,imageEditRoomId=null,projectEpoch=0,loadToken=0;
  const imageCache=new Map();

  function el(tag, attrs = {}) { const node = document.createElementNS(SVG_NS, tag); for (const [k,v] of Object.entries(attrs)) node.setAttribute(k,String(v)); return node; }
  function snapshot() { return JSON.stringify({format:documentFormat,rooms,closedDoors,nextId,background,printLayout,rules,allowedPowerups}); }
  let storageQueue=Promise.resolve(),storageRevision=0;
  function storageNotice(message=''){const warning=document.getElementById('storageWarning');warning.textContent=message;warning.hidden=!message;}
  function browserBackup(mode,value){return new Promise((resolve,reject)=>{
    const request=indexedDB.open('dungeon-layout-images',1);let settled=false;
    const timer=setTimeout(()=>{settled=true;reject(Error('Browserspeicher nicht verfügbar'));},2500);
    request.onupgradeneeded=()=>request.result.createObjectStore('backups');request.onerror=()=>{clearTimeout(timer);reject(request.error);};
    request.onsuccess=()=>{const db=request.result;if(settled){db.close();return;}clearTimeout(timer);const tx=db.transaction('backups',mode==='read'?'readonly':'readwrite'),store=tx.objectStore('backups');const task=mode==='read'?store.get(STORAGE_KEY):mode==='delete'?store.delete(STORAGE_KEY):store.put(value,STORAGE_KEY);tx.oncomplete=()=>{db.close();resolve(task.result);};tx.onerror=()=>{db.close();reject(tx.error);};};
  });}
  function persist() {
    if(changeListener)changeListener(JSON.parse(snapshot()));
    return;
    // Die Online-App übernimmt die kartenspezifische lokale Sicherung.
    const data=snapshot(),revision=++storageRevision;let small=false;
    try{localStorage.setItem(STORAGE_KEY,data);small=true;storageNotice();}catch{storageNotice('Großes Projekt: Browsersicherung läuft …');}
    storageQueue=storageQueue.catch(()=>{}).then(async()=>{try{await browserBackup(small?'delete':'write',data);if(revision===storageRevision)storageNotice();}catch{if(!small&&revision===storageRevision)storageNotice('Browsersicherung nicht möglich – bitte Projekt als JSON speichern!');}});
  }
  function applyLinks(){if(documentFormat!==FORMAT)return;const d=compileDocument(JSON.parse(snapshot()));for(const r of rooms){const next=d.rooms.find(n=>n.id===r.id);if(isEnemy(r))r.attacks=next.attacks;}rules=d.rules;}
  function saveState(before) {applyLinks();invalidateLayoutBoard(); if(readOnly){restore(before);return;} const now = snapshot(); if (now === before) return; history.push(before); while(history.length>1&&(history.length>100||history.reduce((n,s)=>n+s.length,0)>24000000))history.shift(); future=[]; persist(); render(); }
  function restore(s) { const state=JSON.parse(s);documentFormat=state.format;rules=state.rules??newRules();allowedPowerups=state.allowedPowerups??['extraLife','redDice','torch'];defeatedPreviews.clear();projectEpoch++;rooms=state.rooms;closedDoors=state.closedDoors;nextId=state.nextId;background=state.background??null;printLayout=validatePrintLayout(state.printLayout);invalidateLayoutBoard();if(!background)backgroundEdit=false;imageEditRoomId=null;selected=new Set([...selected].filter(id=>rooms.some(r=>r.id===id)));closeMenu();persist();render(); }
  function undo() { if(readOnly)return; if(!history.length)return; future.push(snapshot()); restore(history.pop()); }
  function redo() { if(readOnly)return; if(!future.length)return; history.push(snapshot()); restore(future.pop()); }
  function toast(message) { const t=document.getElementById('toast'); t.textContent=message; t.hidden=false; clearTimeout(toastTimer); toastTimer=setTimeout(()=>t.hidden=true,3200); }
  function locate(e) { const box=board.getBoundingClientRect(); return { x:(e.clientX-box.left-panX)/zoom/CELL, y:(e.clientY-box.top-panY)/zoom/CELL }; }
  function projectGrid() { const w=viewport.clientWidth, h=viewport.clientHeight; board.setAttribute('viewBox',`${-panX/zoom} ${-panY/zoom} ${w/zoom} ${h/zoom}`);const plane=document.getElementById('gridPlane');for(const [key,value] of Object.entries({x:-panX/zoom-CELL,y:-panY/zoom-CELL,width:w/zoom+2*CELL,height:h/zoom+2*CELL}))plane.setAttribute(key,value);document.getElementById('zoomLabel').textContent=`${Math.round(zoom*100)} %`; }
  function clampZoom(z) { return Math.min(3,Math.max(.35,z)); }
  function zoomAt(z, px, py) { if(drag)return; const next=clampZoom(z), factor=next/zoom; panX=px-(px-panX)*factor; panY=py-(py-panY)*factor; zoom=next; projectGrid(); renderSelection(); }
  function collides(room, exceptId=room.id) { return rooms.some(other=>other.id!==exceptId && room.x<other.x+other.w && room.x+room.w>other.x && room.y<other.y+other.h && room.y+room.h>other.y); }
  function keyFor(a,b) { return [a.id,b.id].sort((x,y)=>x-y).join(':'); }
  function connection(a,b) {
    const left=Math.max(a.x,b.x), right=Math.min(a.x+a.w,b.x+b.w);
    const top=Math.max(a.y,b.y), bottom=Math.min(a.y+a.h,b.y+b.h);
    if (a.x+a.w===b.x || b.x+b.w===a.x) return bottom-top>=1 ? {orientation:'vertical', edge:a.x+a.w===b.x?b.x:a.x, center:(top+bottom)/2, span:bottom-top} : null;
    if (a.y+a.h===b.y || b.y+b.h===a.y) return right-left>=1 ? {orientation:'horizontal', edge:a.y+a.h===b.y?b.y:a.y, center:(left+right)/2, span:right-left} : null;
    return null;
  }
  function connections(list=rooms) { const found=[]; for(let i=0;i<list.length;i++) for(let j=i+1;j<list.length;j++){const c=connection(list[i],list[j]); if(c)found.push({...c,key:keyFor(list[i],list[j])});} return found; }
  function pruneDoors() { const keys=new Set(connections().map(c=>c.key)); for(const key of Object.keys(closedDoors)) if(!keys.has(key))delete closedDoors[key]; }

  // Shared drawing primitives keep the editor and PNG export identical.
  const measureContext=document.createElement('canvas').getContext('2d');
  function textWidth(text,size=16){measureContext.font=`600 ${size}px Arial, sans-serif`;return measureContext.measureText(text).width;}
  function wrapText(text,width,size){
    const lines=[];let line='';
    for(const word of text.trim().split(/\s+/).filter(Boolean)){
      if(line&&textWidth(line+' '+word,size)<=width){line+=' '+word;continue;}
      if(line){lines.push(line);line='';}
      for(const char of word){if(line&&textWidth(line+char,size)>width){lines.push(line);line='';}line+=char;}
    }
    if(line)lines.push(line);return lines;
  }
  function svgPrimitive(p){const node=el(p.tag,{...p.attrs,class:'decoration'});if(p.matrix)node.setAttribute('transform',`matrix(${p.matrix.join(' ')})`);if(p.text!==undefined)node.textContent=p.text;return node;}
  function diceArt(x,y,size=22,color='#263849'){
    const s=size/18,matrix=[s,0,0,s,x-28*s,y-9*s],art=[];
    const add=(tag,attrs)=>art.push({tag,attrs,matrix});
    for(const dx of [0,40]){
      add('rect',{x:dx+.7,y:1,width:15.3,height:16,rx:3,fill:'#fff',stroke:color,'stroke-width':1.3});
      for(const [px,py] of [[4.5,5],[8.4,9],[12.1,13]])add('circle',{cx:dx+px,cy:py,r:1.35,fill:color});
    }
    add('path',{d:'M 22 6 L 34 6 M 22 12 L 34 12',fill:'none',stroke:color,'stroke-width':1.5});return art;
  }
  function iconArt(type,cx,cy,width,height){
    const scale=Math.min(width/100,height/90),matrix=[scale,0,0,scale,cx-50*scale,cy-45*scale],art=[];
    const path=(d,fill,stroke='#66523e',sw=1.5)=>art.push({tag:'path',attrs:{d,fill,stroke,'stroke-width':sw,'stroke-linejoin':'round'},matrix});
    if(type==='goldCoin'){path('M 50 6 C 5 6 5 84 50 84 C 95 84 95 6 50 6 Z','#edbd46','#8e6922',3);path('M 50 15 C 18 15 18 75 50 75 C 82 75 82 15 50 15 Z','#ffdf7d','#ad852d',2);path('M 50 28 L 56 40 L 69 42 L 59 51 L 61 65 L 50 58 L 39 65 L 41 51 L 31 42 L 44 40 Z','#b88428');
    }else if(type==='goldSack'){path('M 28 4 L 73 4 L 63 23 C 88 39 97 75 72 84 L 29 84 C 3 75 13 41 36 23 Z','#cf9d47','#765126',2.3);path('M 32 24 L 67 24 L 66 30 L 34 30 Z','#8b652c');path('M 34 40 C 22 50 21 69 30 74','none','#ecca78',4);path('M 51 37 L 51 70 M 63 42 C 39 32 36 51 52 53 C 72 56 64 74 40 64','none','#805b28',3);
    }else if(type==='diamond'){
      path('M 21 9 L 76 9 L 98 34 L 50 85 L 2 34 Z','#52bce6','#4b6270',2.2);
      path('M 21 9 L 36 32 L 2 34 Z','#c0edfa');path('M 21 9 L 50 16 L 76 9 L 65 32 L 36 32 Z','#a5e1f5');
      path('M 76 9 L 98 34 L 65 32 Z','#7ed0ed');path('M 2 34 L 36 32 L 50 85 Z','#60c7ea');
      path('M 36 32 L 65 32 L 50 85 Z','#219cc7');path('M 65 32 L 98 34 L 50 85 Z','#42b1d9');
      path('M 18 5 L 21 16 L 33 19 L 21 22 L 18 34 L 15 22 L 4 19 L 15 16 Z','#fffbed','none');
      path('M 78 39 L 80 45 L 87 47 L 80 49 L 78 56 L 76 49 L 69 47 L 76 45 Z','#e9fbff','none');
    }else{
      path('M 8 32 L 70 45 L 94 32 L 94 69 L 70 84 L 8 68 Z','#8a4327','#583825',2);
      path('M 70 45 L 94 32 L 94 69 L 70 84 Z','#623621');
      path('M 8 32 C 9 5 28 -1 46 7 L 80 15 C 89 18 94 24 94 32 L 70 45 Z','#ad6030','#583825',2);
      path('M 8 32 C 10 9 23 1 37 7 C 56 9 69 21 70 45 Z','#cc873c');
      path('M 8 32 L 70 45 L 94 32 L 94 39 L 70 52 L 8 39 Z','#f1c55b');
      path('M 16 35 C 18 14 25 5 34 5 L 43 8 C 32 10 28 21 27 37 L 27 72 L 17 70 Z','#f5d576');
      path('M 55 42 C 52 25 44 15 36 10 L 46 7 C 58 12 65 25 66 44 L 66 82 L 55 79 Z','#e9b950');
      path('M 8 64 L 70 78 L 94 63 L 94 71 L 70 87 L 8 72 Z','#cf9d3f');
      path('M 31 42 L 48 46 L 48 62 L 31 58 Z','#ffe393','#6c4926',1.3);
      path('M 37 48 C 37 45 42 46 42 50 L 40 52 L 40 56 L 37 55 L 38 51 Z','#684523','none');
      path('M 77 51 L 88 45 L 88 49 L 77 55 Z','#dfae4c');
      path('M 78 56 C 79 70 87 64 88 53', 'none','#e6bd62',3);
      path('M 12 29 C 15 14 22 9 28 8', 'none','#ffeab4',2);
    }
    return art;
  }
  function wallArt(list=rooms,closed=closedDoors){
    const lines=new Map(),art=[];
    const add=(vertical,edge,a,b)=>{const key=(vertical?'v:':'h:')+edge;let line=lines.get(key);if(!line){line={vertical,edge,intervals:[],cuts:[]};lines.set(key,line);}line.intervals.push([a*CELL,b*CELL]);};
    for(const r of list){add(false,r.y,r.x,r.x+r.w);add(false,r.y+r.h,r.x,r.x+r.w);add(true,r.x,r.y,r.y+r.h);add(true,r.x+r.w,r.y,r.y+r.h);}
    for(const c of connections(list))if(!closed[c.key]){const half=(Math.min(2,c.span)*CELL-6)/2;lines.get((c.orientation==='vertical'?'v:':'h:')+c.edge)?.cuts.push([c.center*CELL-half,c.center*CELL+half]);}
    const hash=(n)=>{let x=(n^0x45d9f3b)|0;x=Math.imul(x^(x>>>16),0x45d9f3b);return ((x^(x>>>16))>>>0)/4294967296;};
    const palette=['#c5c1b5','#d1c9b7','#b5b8b2','#d8d1c2','#bcb6a9'];
    for(const line of lines.values()){
      const sorted=line.intervals.sort((a,b)=>a[0]-b[0]),merged=[];
      for(const interval of sorted){const last=merged.at(-1);if(last&&interval[0]<=last[1])last[1]=Math.max(last[1],interval[1]);else merged.push([...interval]);}
      let segments=merged;
      for(const [cutA,cutB] of line.cuts){const next=[];for(const [a,b] of segments){if(cutB<=a||cutA>=b)next.push([a,b]);else{if(cutA>a)next.push([a,cutA]);if(cutB<b)next.push([cutB,b]);}}segments=next;}
      const point=(along,across)=>line.vertical?[line.edge*CELL+across,along]:[along,line.edge*CELL+across];
      const polygon=points=>'M '+points.map(p=>point(...p).join(' ')).join(' L ')+' Z';
      for(const [a,b] of segments){
        let cursor=a+.45,tile=0;const baseLength=Math.max(CELL,(b-a)/150);
        while(cursor<b-.45){
          const seed=Math.round(cursor*17)+line.edge*7919+(line.vertical?104729:0)+tile*3817,rnd=hash(seed),small=hash(seed+313)>.82;
          const remaining=b-.45-cursor;
          let length=baseLength*(small?(.38+hash(seed+97)*.2):(.72+hash(seed+97)*.56));
          if(remaining-length<baseLength*.38)length=remaining;
          const start=cursor,end=Math.min(b-.45,start+length);if(end-start<2)break;
          const damaged=hash(seed+701)>.72,cut=Math.min(damaged?4.2:2,(end-start)/4),thick=4.25+rnd*1.15;
          const notch=start+(end-start)*(.38+hash(seed+41)*.25);
          const pts=damaged
            ?[[start+cut,-thick],[notch-2,-thick+.4],[notch,-thick+2.7],[notch+3,-thick+.7],[end-cut*.5,-thick+1],[end,-thick+2.5],[end-.4,thick-1],[end-cut,thick],[start+1.4,thick-.5],[start,thick-2],[start,-thick+cut]]
            :[[start+cut,-thick],[end-cut*.5,-thick+.6],[end,-thick+2],[end-.3,thick-1],[end-cut,thick],[start+1,thick-.4],[start,thick-2],[start,-thick+cut]];
          art.push({tag:'path',attrs:{d:polygon(pts),fill:palette[Math.floor(rnd*palette.length)],stroke:'#68645b','stroke-width':1,'stroke-linejoin':'round'}});
          art.push({tag:'path',attrs:{d:polygon([[start+cut,-thick+.9],[end-cut,-thick+1.4],[end-3,-thick+2.8],[start+3,-thick+2.3]]),fill:'#eee7d9'}});
          art.push({tag:'path',attrs:{d:polygon([[start+1,thick-2],[end-1,thick-2.4],[end-cut,thick-.4],[start+1,thick-.9]]),fill:'#a09d93'}});
          if(damaged||rnd>.6&&end-start>10){const mid=damaged?notch:(start+end)/2;art.push({tag:'path',attrs:{d:'M '+point(mid,-thick+.5).join(' ')+' L '+point(mid-2,-.8).join(' ')+' L '+point(mid+1,.8).join(' ')+' L '+point(mid-.4,thick-1).join(' '),fill:'none',stroke:'#77736b','stroke-width':.75}});}
          cursor=end+.7;tile++;
        }
      }
    }
    return art;
  }
  function roomArt(r,layer='all'){
    const art=[],left=r.x*CELL,top=r.y*CELL,w=r.w*CELL,h=r.h*CELL,x=left+w/2,y=top+h/2;
    const text=(value,tx,ty,size=17,fill='#263849',anchor='middle',extra={})=>art.push({tag:'text',text:String(value),attrs:{x:tx,y:ty,'font-family':'Arial, sans-serif','font-size':size,'font-weight':600,fill,'text-anchor':anchor,'dominant-baseline':'central',...extra}});
    const path=(d,fill,stroke,width=1.5)=>art.push({tag:'path',attrs:{d,fill,stroke,'stroke-width':width}});
    const rect=(rx,ry,rw,rh,fill,stroke,extra={})=>art.push({tag:'rect',attrs:{x:rx,y:ry,width:rw,height:rh,fill,stroke,'stroke-width':1.2,...extra}});
    const diamond=(dx,dy,s=1)=>path(`M ${dx-10*s} ${dy-9*s} L ${dx+10*s} ${dy-9*s} L ${dx+15*s} ${dy-s} L ${dx} ${dy+14*s} L ${dx-15*s} ${dy-s} Z`,'#85c8ed','#3481b5',1.2);
    const requirementWidth=(n,size)=>n==='doubles'?size*56/18:textWidth(String(n),size);
    const requirement=(n,px,py,size=22,color='#263849',anchor='middle',extra={})=>{if(n==='doubles'){const first=art.length;art.push(...diceArt(anchor==='start'?px+requirementWidth(n,size)/2:px,py,size,color));Object.assign(art[first].attrs,extra,{'data-pasch':'true'});}else text(n,px,py,size,color,anchor,extra);};
    if((rules.goals || []).some(g=>g.type==='connect'&&g.cellIds.includes(r.id)))rect(left+9,top+9,w-18,h-18,'none','#d2a137',{'stroke-width':3});
    if(isEnemy(r)){
      // Independent top-left and top-right zones avoid overlap, even for 11 attack numbers.
      const inset=12,attackWidth=(w-2*inset)*.46,hitsWidth=(w-2*inset)*.48;
      const attackRows=size=>{const rows=[];let row=[];for(const attack of r.attacks){const next=[...row,attack],rowWidth=next.reduce((sum,a)=>sum+requirementWidth(a.number,size),0)+(next.length-1)*textWidth(' / ',size);if(row.length&&rowWidth>attackWidth){rows.push(row);row=[];}row.push(attack);}if(row.length)rows.push(row);return rows;};
      let attackSize=19,rows=attackRows(attackSize);
      while(rows.length*(attackSize+4)>h*.4&&attackSize>11){attackSize--;rows=attackRows(attackSize);}
      rows.forEach((row,j)=>{let ax=left+inset;const ay=top+inset+attackSize/2+j*(attackSize+4);row.forEach((attack,i)=>{
        if(i){text('/',ax+textWidth(' ',attackSize),ay,attackSize,'#697786','start');ax+=textWidth(' / ',attackSize);}
        requirement(attack.number,ax,ay,attackSize,attack.state==='locked'?'#9aa3ac':'#172b3b','start',{'data-attack':attack.number,'data-state':attack.state});ax+=requirementWidth(attack.number,attackSize);
      });});
      // Fill the rightmost column downward, then add columns to its left.
      // Boss columns contain two visibly separated groups of three hits.
      const boss=r.type==='boss'||r.type==='miniboss',perColumn=boss?6:4,cols=Math.ceil(r.hits/perColumn);
      const rowsInFirst=Math.min(perColumn,r.hits),groupGap=boss?8:0;
      const nominalWidth=(cols-1)*18+12;
      const nominalHeight=(rowsInFirst-1)*16+12+(rowsInFirst>3?groupGap:0);
      const hitScale=Math.min(1,hitsWidth/nominalWidth,h*(boss ? .55 : .36)/nominalHeight);
      const box=12*hitScale;
      for(let i=0;i<r.hits;i++){
        const col=Math.floor(i/perColumn),row=i%perColumn;
        rect(left+w-inset-box-col*18*hitScale,top+inset+(row*16+(row>2?groupGap:0))*hitScale,box,box,'#fff','#536473',{'stroke-width':1.2*hitScale,'data-hit':i+1});
      }
      // Name fits the lower-right zone and rewards the lower-left zone.
      const nameWidth=(w-2*inset)*.5;let nameSize=13;
      const longestWord=Math.max(0,...r.name.split(/\s+/).map(word=>textWidth(word,nameSize)));
      if(longestWord>nameWidth)nameSize=Math.max(10,Math.floor(nameSize*nameWidth/longestWord));
      let nameLines=wrapText(r.name,nameWidth,nameSize);
      while(nameLines.length*(nameSize+3)>h*.32&&nameSize>6){nameSize--;nameLines=wrapText(r.name,nameWidth,nameSize);}
      nameLines.forEach((line,i)=>text(line,left+w-inset,top+h-inset-5-(nameLines.length-1-i)*(nameSize+3),nameSize,'#263849','end',{'data-enemy-name':'true'}));
      const rewards=[r.rewardFirst,r.rewardLater].filter(value=>value>0);
      if(rewards.length){
        const rewardY=top+h-inset-6;
        let rewardSize=14;
        const rewardText=rewards.join(' / ');
        while(textWidth(rewardText,rewardSize)+rewards.length*17>(w-2*inset)*.46&&rewardSize>9)rewardSize--;
        let rx=left+inset;
        rewards.forEach((value,i)=>{
          if(i){text('/',rx,rewardY,rewardSize,'#697786','start');rx+=textWidth('/',rewardSize)+6;}
          text(value,rx,rewardY,rewardSize,'#263849','start',{'data-enemy-reward':i+1});rx+=textWidth(String(value),rewardSize)+8;
          diamond(rx,rewardY-1,.28);rx+=9;
        });
      }
      let imagePrimitive=null;const image=(!canonicalPaint&&defeatedPreviews.has(r.id)?r.defeatedImage:r.image),imageLayout=(!canonicalPaint&&defeatedPreviews.has(r.id)?r.defeatedImageLayout:r.imageLayout);
      if(image){
        const attackBottom=top+inset+rows.length*(attackSize+4),hitBottom=top+inset+nominalHeight*hitScale;
        const bottom=Math.min(top+h-(rewards.length?37:inset),top+h-inset-5-nameLines.length*(nameSize+3)-6);
        const candidates=[{x:left+inset,y:Math.max(attackBottom,hitBottom)+8,w:w-2*inset,h:bottom-Math.max(attackBottom,hitBottom)-8},{x:left+inset,y:attackBottom+8,w:w-2*inset-nominalWidth*hitScale-10,h:bottom-attackBottom-8}];
        let placed=imageLayout?{x:left+imageLayout.x*CELL,y:top+imageLayout.y*CELL,width:imageLayout.w*CELL,height:imageLayout.h*CELL}:candidates.filter(b=>b.w>0&&b.h>0).map(b=>{const scale=Math.min(b.w/image.width,b.h/image.height),iw=image.width*scale,ih=image.height*scale;return {x:b.x+(b.w-iw)/2,y:b.y+(b.h-ih)/2,width:iw,height:ih};}).sort((a,b)=>b.width*b.height-a.width*a.height)[0];
        if(!placed){const scale=Math.min((w-24)/image.width,(h-24)/image.height);placed={x:x-image.width*scale/2,y:y-image.height*scale/2,width:image.width*scale,height:image.height*scale};}
        if(placed)imagePrimitive={tag:'image',attrs:{...placed,href:image.src,preserveAspectRatio:'xMidYMid meet','data-enemy-image':'true'}};
      }else if(!r.name)text(r.type==='boss'?'BOSS':['miniboss','bonus'].includes(r.type)?'BONUSAUFGABE':'MONSTER',x,boss?top+h*.64:y,11,'#78858f');
      if(layer==='image')return imagePrimitive?[imagePrimitive]:[];
      if(layer==='info')return art;
      return imagePrimitive?[imagePrimitive,...art]:art;
    }
    if(['diamond','chest','goldSack','goldCoin'].includes(r.type)){
      const hasNumber=r.number!==null,wide=w>=h*1.5&&hasNumber;
      if(wide){const reserved=requirementWidth(r.number,22)+30,artWidth=w-reserved-20;art.push(...iconArt(r.type,left+12+artWidth/2,y,artWidth,h-24));requirement(r.number,left+w-14-requirementWidth(r.number,22)/2,y);}
      else{const artHeight=h-(hasNumber?48:24);art.push(...iconArt(r.type,x,top+12+artHeight/2,w-24,artHeight));if(hasNumber)requirement(r.number,x,top+h-21);}
      return art;
    }
    if(r.type==='portal'){art.push({tag:'circle',attrs:{cx:x,cy:y-12,r:22,fill:'#a0ddd1',stroke:'#387f75','stroke-width':3}});art.push({tag:'circle',attrs:{cx:x,cy:y-12,r:13,fill:'#496e88',stroke:'#e6fffa','stroke-width':2}});if(r.number!=null)requirement(r.number,x,top+h-18);return art;}
    if(r.type==='trap'){
      path(`M ${x-29} ${y-18} Q ${x} ${y-39} ${x+29} ${y-18} L ${x+25} ${y-5} Q ${x} ${y+8} ${x-25} ${y-5} Z`,'#9e9a83','#514d42',2);
      path(`M ${x-22} ${y-18} Q ${x} ${y-31} ${x+22} ${y-18} L ${x+17} ${y-10} Q ${x} ${y-3} ${x-17} ${y-10} Z`,'#433e34','#ded1b0',1.5);
      for(let i=0;i<5;i++){const px=x-23+i*10;path(`M ${px} ${y-16} L ${px+4} ${y-29} L ${px+8} ${y-16} Z`,'#c7c2ac','#514d42',1);}
      path(`M ${x-10} ${y-10} L ${x+10} ${y-10} L ${x+5} ${y-3} L ${x-5} ${y-3} Z`,'#b89255','#514d42',1);
      if(r.number!=null)requirement(r.number,x,y+14);text(`−${r.trapCost} ${r.trapKind==='life'?'♥':'♦'}`,left+10,top+h-13,12,'#944432','start');return art;}
    if(r.type==='crazy'){
      rect(left+w-28,top+9,17,17,'#f4e4bf','#5c5542',{rx:3,'data-crazy-icon':true});
      for(const [dx,dy] of [[4,4],[8.5,8.5],[13,13]])art.push({tag:'circle',attrs:{cx:left+w-28+dx,cy:top+9+dy,r:1.3,fill:'#5c5542','data-crazy-icon':true}});
      const rowsFor=size=>{const rows=[[]];let width=0;for(const n of r.requirements){const add=requirementWidth(n,size)+(rows.at(-1).length?textWidth(' / ',size):0);if(width+add>w-20&&rows.at(-1).length){rows.push([]);width=0;}rows.at(-1).push(n);width+=requirementWidth(n,size)+(rows.at(-1).length>1?textWidth(' / ',size):0);}return rows;};
      let size=16,rows=rowsFor(size);while(rows.length*(size+4)>h-30&&size>6){size--;rows=rowsFor(size);}rows.forEach((row,i)=>{let ax=left+10;row.forEach((n,j)=>{if(j){text('/',ax,top+30+i*(size+4),size,'#697786','start');ax+=textWidth(' / ',size);}requirement(n,ax,top+30+i*(size+4),size,'#653d74','start');ax+=requirementWidth(n,size);});});if(!r.requirements.length)text('?',x,y,22,'#895398');return art;}

    if(['special','rune'].includes(r.type))text('✕',x,r.number!==null?y-11:y,13,'#536473');
    if(r.number!==null)requirement(r.number,x,y+(['special','rune'].includes(r.type)?14:0));
    return art;
  }
  function currentImageLayout(r){
    if(r[enemyLayoutKey(r)])return {...r[enemyLayoutKey(r)]};
    const primitive=roomArt(r,'image')[0];if(!primitive)return null;const a=primitive.attrs;
    return {x:(a.x-r.x*CELL)/CELL,y:(a.y-r.y*CELL)/CELL,w:a.width/CELL,h:a.height/CELL};
  }
  function imageLayoutWithinRoom(r,layout){return layout&&layout.w>0&&layout.h>0&&layout.x>=-4-.001&&layout.y>=-4-.001&&layout.x+layout.w<=r.w+4.001&&layout.y+layout.h<=r.h+4.001;}
  function fitImageLayout(r,layout){
    const ratio=layout.w/layout.h,minX=-4,minY=-4,maxX=r.w+4,maxY=r.h+4;
    let w=Math.min(layout.w,maxX-minX,(maxY-minY)*ratio),h=w/ratio;
    if(h>maxY-minY){h=maxY-minY;w=h*ratio;}
    return {x:Math.max(minX,Math.min(layout.x,maxX-w)),y:Math.max(minY,Math.min(layout.y,maxY-h)),w,h};
  }
  function drawRoom(r) {
    const moving=(drag?.mode==='room' && selected.has(r.id))||(drag?.mode==='resize'&&drag.id===r.id);
    const g=el('g',{class:`room ${r.type}${r.start?' start':''}${r.dimmed?' dimmed':''}${selected.has(r.id)?' selected':''}${moving?' dragging':''}${drag?.invalid && moving?' invalid':''}`, 'data-id':r.id});
    g.append(el('rect',{class:'room-body',x:r.x*CELL,y:r.y*CELL,width:r.w*CELL,height:r.h*CELL}));
    if(!isEnemy(r))for(const primitive of roomArt(r))g.append(svgPrimitive(primitive));
    g.addEventListener('pointerdown',e=>startRoomDrag(e,r.id));
    g.addEventListener('contextmenu',e=>{e.preventDefault();e.stopPropagation();if(drag)return;selected=new Set([r.id]);activeId=r.id;render();openMenu(e.clientX,e.clientY,r.id);});
    return g;
  }
  function drawEnemyLayer(r,layer){const g=el('g',{class:`enemy-${layer}`,'data-id':r.id});for(const primitive of roomArt(r,layer))g.append(svgPrimitive(primitive));return g;}
  function drawDoor(c) {
    const g=el('g',{class:'door', 'data-key':c.key});
    const vertical=c.orientation==='vertical', x=(vertical?c.edge:c.center)*CELL, y=(vertical?c.center:c.edge)*CELL;
    const opening=Math.min(2, c.span)*CELL-6;
    if(!closedDoors[c.key]) {
      g.append(el('circle',{class:'open-icon',cx:x,cy:y,r:3.2}));
    } else {
      g.append(el('line',{class:'closed-icon',x1:x-(vertical?0:Math.min(13,opening/3)),y1:y-(vertical?Math.min(13,opening/3):0),x2:x+(vertical?0:Math.min(13,opening/3)),y2:y+(vertical?Math.min(13,opening/3):0),stroke:'#a63c4c','stroke-width':5,'stroke-linecap':'round'}));
    }
    g.append(el('rect',{class:'hit',x:x-16,y:y-16,width:32,height:32}));
    g.setAttribute('aria-label',closedDoors[c.key]?'Geschlossenen Durchgang öffnen':'Offenen Durchgang schließen');
    g.addEventListener('pointerdown',e=>e.stopPropagation());
    g.addEventListener('click',e=>{e.stopPropagation();if(readOnly)return;const before=snapshot();if(closedDoors[c.key])delete closedDoors[c.key];else closedDoors[c.key]=true;saveState(before);});
    return g;
  }
  function render() {
    board.classList.toggle('background-edit',backgroundEdit);
    board.classList.toggle('image-edit',imageEditRoomId!==null);
    document.getElementById('backgroundHint').hidden=!backgroundEdit;
    document.getElementById('imageHint').hidden=imageEditRoomId===null;
    const bgLayer=document.getElementById('backgroundLayer');bgLayer.replaceChildren();
    if(background)bgLayer.append(el('image',{href:background.image.src,x:background.x*CELL,y:background.y*CELL,width:background.w*CELL,height:background.h*CELL,preserveAspectRatio:'none'}));
    document.getElementById('editBackground').disabled=!background;
    document.getElementById('editBackground').textContent=backgroundEdit?'Zur Feldbearbeitung':'Hintergrund bearbeiten';
    document.getElementById('editBackground').setAttribute('aria-pressed',String(backgroundEdit));
    if(!selected.has(activeId))activeId=[...selected].at(-1)??null;
    roomsLayer.replaceChildren(...rooms.map(drawRoom));
    const doors=connections(); doorsLayer.replaceChildren(...doors.map(drawDoor));
    wallsLayer.replaceChildren(...wallArt().map(svgPrimitive));
    const enemies=rooms.filter(isEnemy);enemyImagesLayer.replaceChildren(...enemies.map(r=>drawEnemyLayer(r,'image')));enemyInfoLayer.replaceChildren(...enemies.map(r=>drawEnemyLayer(r,'info')));
    const counts=Object.fromEntries(Object.keys(DIM).map(type=>[type,rooms.filter(r=>r.type===type).length]));
    document.getElementById('status').textContent=`${rooms.length} Felder (${counts.normal} Weg · ${counts.diamond} Diamant · ${counts.chest} Schatzkisten · ${counts.rune+counts.special} Runen · ${counts.monster} Monster · ${counts.bonus+counts.miniboss} Bonusaufgaben · ${counts.trap} Fallen · ${counts.portal} Portale · ${counts.crazy} verrückte · ${counts.goldSack+counts.goldCoin} Gold · ${counts.boss} Boss) · ${rooms.filter(r=>r.start).length} Startfelder · ${doors.length} Durchgänge${selected.size?' · '+selected.size+' ausgewählt':''}`;
    document.getElementById('delete').disabled=imageEditRoomId!==null?true:backgroundEdit?!background:!selected.size;
    document.getElementById('undo').disabled=!history.length;
    document.getElementById('redo').disabled=!future.length;
    renderSelection();
    projectGrid();
    requestLayoutPreview();
  }
  function renderSelection(){
    const layer=document.getElementById('selectionLayer');layer.replaceChildren();
    if(backgroundEdit&&background){drawBackgroundSelection(layer);return;}
    if(imageEditRoomId!==null){const r=rooms.find(r=>r.id===imageEditRoomId&&r[imageKey(r)]);if(r)drawEnemyImageSelection(layer,r);else imageEditRoomId=null;return;}
    for(const room of rooms.filter(r=>selected.has(r.id)))layer.append(el('rect',{x:room.x*CELL-6,y:room.y*CELL-6,width:room.w*CELL+12,height:room.h*CELL+12,fill:'none',stroke:drag?.invalid?'#d83446':'#1673bd','stroke-width':2,'vector-effect':'non-scaling-stroke','pointer-events':'none'}));
    if(drag?.mode==='select'){const {start,end}=drag;layer.append(el('rect',{id:'selectionBox',x:Math.min(start.x,end.x)*CELL,y:Math.min(start.y,end.y)*CELL,width:Math.abs(end.x-start.x)*CELL,height:Math.abs(end.y-start.y)*CELL}));return;}
    const r=rooms.find(r=>r.id===activeId&&selected.has(r.id));
    if(!r||!resizable(r)||drag?.mode==='room'||drag?.mode==='pan')return;
    const offset=8/zoom,left=r.x*CELL-offset,top=r.y*CELL-offset,right=(r.x+r.w)*CELL+offset,bottom=(r.y+r.h)*CELL+offset;
    layer.append(el('rect',{class:'resize-guide',x:left,y:top,width:right-left,height:bottom-top}));
    const points={nw:[left,top],n:[(left+right)/2,top],ne:[right,top],e:[right,(top+bottom)/2],se:[right,bottom],s:[(left+right)/2,bottom],sw:[left,bottom],w:[left,(top+bottom)/2]};
    for(const [side,[x,y]] of Object.entries(points)){
      const cursor=({n:'ns',s:'ns',e:'ew',w:'ew',nw:'nwse',se:'nwse',ne:'nesw',sw:'nesw'})[side]+'-resize';
      const handle=el('rect',{class:'resize-handle','data-resize':side,x:x-5/zoom,y:y-5/zoom,width:10/zoom,height:10/zoom,rx:2/zoom,style:`cursor:${cursor}`,'aria-label':`${TYPE_NAMES[r.type]} vergrößern oder verkleinern (${side})`});
      handle.addEventListener('pointerdown',e=>startResize(e,r.id,side));
      handle.addEventListener('contextmenu',e=>{e.preventDefault();e.stopPropagation();});layer.append(handle);
    }
    const label=el('text',{x:(left+right)/2,y:top-10/zoom,'text-anchor':'middle','font-size':12/zoom,'font-family':'Arial, sans-serif',fill:drag?.invalid?'#c42c40':'#14649b',stroke:'#fafbfc','stroke-width':3/zoom,'paint-order':'stroke','pointer-events':'none'});
    label.textContent=`${r.w} × ${r.h}${drag?.invalid?' · Überlappung':''}`;layer.append(label);
  }
  function drawEnemyImageSelection(layer,r){
    const layout=currentImageLayout(r);if(!layout)return;const left=(r.x+layout.x)*CELL,top=(r.y+layout.y)*CELL,right=left+layout.w*CELL,bottom=top+layout.h*CELL;
    const area=el('rect',{'data-enemy-image-move':'true',x:left,y:top,width:right-left,height:bottom-top,fill:'transparent',stroke:'#e27b19','stroke-width':2,'stroke-dasharray':'6 4','vector-effect':'non-scaling-stroke',style:'cursor:move'});area.addEventListener('pointerdown',e=>startEnemyImageDrag(e,r));layer.append(area);
    for(const [side,[x,y]] of Object.entries({nw:[left,top],ne:[right,top],se:[right,bottom],sw:[left,bottom]})){
      const cursor=({nw:'nwse',se:'nwse',ne:'nesw',sw:'nesw'})[side]+'-resize';
      const handle=el('rect',{class:'resize-handle','data-enemy-image-resize':side,x:x-6/zoom,y:y-6/zoom,width:12/zoom,height:12/zoom,rx:2/zoom,stroke:'#e27b19',style:`cursor:${cursor}`});handle.addEventListener('pointerdown',e=>startEnemyImageDrag(e,r,side));layer.append(handle);
    }
    const label=el('text',{x:(left+right)/2,y:top-12/zoom,'text-anchor':'middle','font-size':13/zoom,fill:'#b95e0c',stroke:'#fff','stroke-width':3/zoom,'paint-order':'stroke','pointer-events':'none'});label.textContent=`Gegnerbild · ${layout.w.toFixed(1)} × ${layout.h.toFixed(1)}`;layer.append(label);
  }
  function drawBackgroundSelection(layer){
    const r=background,left=r.x*CELL,top=r.y*CELL,right=(r.x+r.w)*CELL,bottom=(r.y+r.h)*CELL;
    const area=el('rect',{'data-background-move':'true',x:left,y:top,width:right-left,height:bottom-top,fill:'transparent',stroke:'#1673bd','stroke-width':2,'stroke-dasharray':'6 4','vector-effect':'non-scaling-stroke',style:'cursor:move'});
    area.addEventListener('pointerdown',e=>startBackgroundDrag(e));layer.append(area);
    const points={nw:[left,top],n:[(left+right)/2,top],ne:[right,top],e:[right,(top+bottom)/2],se:[right,bottom],s:[(left+right)/2,bottom],sw:[left,bottom],w:[left,(top+bottom)/2]};
    for(const [side,[x,y]] of Object.entries(points)){
      const cursor=({n:'ns',s:'ns',e:'ew',w:'ew',nw:'nwse',se:'nwse',ne:'nesw',sw:'nesw'})[side]+'-resize';
      const handle=el('rect',{class:'resize-handle','data-background-resize':side,x:x-6/zoom,y:y-6/zoom,width:12/zoom,height:12/zoom,rx:2/zoom,style:`cursor:${cursor}`});
      handle.addEventListener('pointerdown',e=>startBackgroundDrag(e,side));layer.append(handle);
    }
    const label=el('text',{x:(left+right)/2,y:top-12/zoom,'text-anchor':'middle','font-size':13/zoom,fill:'#14649b',stroke:'#fff','stroke-width':3/zoom,'paint-order':'stroke','pointer-events':'none'});label.textContent=`Hintergrund · ${r.w} × ${r.h}`;layer.append(label);
  }
  function startBackgroundDrag(e,side=null){ if(readOnly)return;
    if(e.button!==0)return;e.preventDefault();e.stopPropagation();
    if(spaceDown){drag={mode:'pan',pointerId:e.pointerId,clientX:e.clientX,clientY:e.clientY,panX,panY};}
    else drag={mode:side?'bg-resize':'bg-move',side,pointerId:e.pointerId,start:locate(e),origin:{x:background.x,y:background.y,w:background.w,h:background.h},before:snapshot(),invalid:false};
    board.setPointerCapture(e.pointerId);
  }
  function startEnemyImageDrag(e,r,side=null){ if(readOnly)return;
    if(e.button!==0)return;e.preventDefault();e.stopPropagation();
    if(spaceDown){drag={mode:'pan',pointerId:e.pointerId,clientX:e.clientX,clientY:e.clientY,panX,panY};board.setPointerCapture(e.pointerId);return;}
    const layout=currentImageLayout(r);if(!layout)return;
    const before=snapshot(),stored=r[enemyLayoutKey(r)]?{...r[enemyLayoutKey(r)]}:null;r[enemyLayoutKey(r)]={...layout};
    drag={mode:side?'image-resize':'image-move',id:r.id,side,key:enemyLayoutKey(r),pointerId:e.pointerId,start:locate(e),origin:{...layout},stored,before,changed:false};board.setPointerCapture(e.pointerId);render();
  }
  function editEnemyImage(id){const r=rooms.find(r=>r.id===id&&r[imageKey(r)]);if(!r)return;closeMenu();backgroundEdit=false;imageEditRoomId=id;selected.clear();activeId=null;render();}
  function editBackground(value){if(!background)return;closeMenu();imageEditRoomId=null;backgroundEdit=value;selected.clear();render();}
  function removeBackground(){if(!background)return;const before=snapshot();background=null;backgroundEdit=false;projectEpoch++;saveState(before);refreshBackgroundPanel();}
  function addRoom(type, at=null) { if(readOnly)return;
    closeMenu();backgroundEdit=false;imageEditRoomId=null;
    const [w,h]=DIM[type], centerX=(viewport.clientWidth/2-panX)/zoom/CELL, centerY=(viewport.clientHeight/2-panY)/zoom/CELL;
    const bx=Math.round(centerX-w/2), by=Math.round(centerY-h/2);
    let candidate=at?{id:nextId,type,x:Math.floor(at.x),y:Math.floor(at.y),w,h,number:null,start:false}:null;
    if(candidate&&collides(candidate)){toast('Hier würde das neue Feld ein anderes überlappen.');return;}
    for(let radius=0;radius<90&&!candidate;radius++) for(let dy=-radius;dy<=radius&&!candidate;dy++) for(let dx=-radius;dx<=radius&&!candidate;dx++) {
      if(radius && Math.max(Math.abs(dx),Math.abs(dy))!==radius)continue;
      const r={id:nextId,type,x:bx+dx,y:by+dy,w,h,number:null,start:false}; if(!collides(r))candidate=r;
    }
    if(!candidate){toast('Hier ist kein freier Platz zu finden. Ansicht verschieben.');return;}
    const before=snapshot();rooms.push(normalizeRoom(candidate));nextId++;selected=new Set([candidate.id]);activeId=candidate.id;saveState(before);
  }
  function startRoomDrag(e,id) { if(readOnly)return;
    if(e.button!==0||backgroundEdit)return;
    closeMenu(); e.preventDefault(); e.stopPropagation();
    if(spaceDown){drag={mode:'pan',pointerId:e.pointerId,clientX:e.clientX,clientY:e.clientY,panX,panY};board.setPointerCapture(e.pointerId);return;}
    if(e.shiftKey){if(selected.has(id))selected.delete(id);else selected.add(id);activeId=id;render();return;}
    if(!selected.has(id))selected=new Set([id]);
    activeId=id;
    drag={mode:'room',pointerId:e.pointerId,start:locate(e),origins:rooms.filter(r=>selected.has(r.id)).map(r=>({id:r.id,x:r.x,y:r.y})),before:snapshot(),invalid:false};
    board.setPointerCapture(e.pointerId);render();
  }
  function startResize(e,id,side){ if(readOnly)return;
    if(e.button!==0)return;
    if(spaceDown){startRoomDrag(e,id);return;}
    e.preventDefault();e.stopPropagation();closeMenu();
    const r=rooms.find(r=>r.id===id);
    drag={mode:'resize',id,side,pointerId:e.pointerId,start:locate(e),origin:{x:r.x,y:r.y,w:r.w,h:r.h},before:snapshot(),connections:connections(),invalid:false};
    board.setPointerCapture(e.pointerId);render();
  }
  function finishDrag(e) {
    if(!drag || e.pointerId!==drag.pointerId)return;
    const current=drag;drag=null;
    if(current.mode==='bg-move'||current.mode==='bg-resize'){
      if(current.invalid||e.type==='pointercancel')Object.assign(background,current.origin);else saveState(current.before);
    }
    if(current.mode==='image-move'||current.mode==='image-resize'){
      const r=rooms.find(r=>r.id===current.id);
      if(r){if(e.type==='pointercancel'||!current.changed)r[current.key]=current.stored?{...current.stored}:null;else saveState(current.before);}
    }
    if(current.mode==='room') {
      if(current.invalid || e.type==='pointercancel') {for(const o of current.origins){const r=rooms.find(r=>r.id===o.id);if(r){r.x=o.x;r.y=o.y;}}if(current.invalid)toast('Die Auswahl würde andere Felder überlappen.');}
      else {pruneDoors();saveState(current.before);}
    }
    if(current.mode==='resize'){
      const r=rooms.find(r=>r.id===current.id);
      if(current.invalid||e.type==='pointercancel'){Object.assign(r,current.origin);if(current.invalid)toast('Größe unverändert: Das Feld würde ein anderes überlappen.');}
      else{
        for(const key of ['imageLayout','defeatedImageLayout'])if(r[key])r[key]=fitImageLayout(r,r[key]);
        const after=new Map(connections().map(c=>[c.key,c]));
        // A closed door survives resizing when the same contact segment still exists.
        for(const old of current.connections){const now=after.get(old.key);if(closedDoors[old.key]&&(!now||now.orientation!==old.orientation||now.edge!==old.edge||Math.min(old.center+old.span/2,now.center+now.span/2)-Math.max(old.center-old.span/2,now.center-now.span/2)<1))delete closedDoors[old.key];}
        pruneDoors();saveState(current.before);
      }
    }
    if(current.mode==='select'&&e.type==='pointercancel')selected=new Set(current.base);
    if(board.hasPointerCapture(e.pointerId))board.releasePointerCapture(e.pointerId);
    render();
  }
  board.addEventListener('pointermove',e=>{
    if(!drag||e.pointerId!==drag.pointerId)return;
    if(drag.mode==='pan'){panX=drag.panX+e.clientX-drag.clientX;panY=drag.panY+e.clientY-drag.clientY;projectGrid();return;}
    const p=locate(e);
    if(drag.mode==='image-move'||drag.mode==='image-resize'){
      const r=rooms.find(r=>r.id===drag.id),o=drag.origin;if(!r)return;
      if(drag.mode==='image-move'){
        const dx=Math.round((p.x-drag.start.x)*4)/4,dy=Math.round((p.y-drag.start.y)*4)/4;
        const targetX=Math.round((o.x+dx)*4)/4,targetY=Math.round((o.y+dy)*4)/4;
        r[drag.key]={x:Math.max(-4,Math.min(targetX,r.w+4-o.w)),y:Math.max(-4,Math.min(targetY,r.h+4-o.h)),w:o.w,h:o.h};
      }else{
        const east=drag.side.includes('e'),south=drag.side.includes('s'),anchorX=east?o.x:o.x+o.w,anchorY=south?o.y:o.y+o.h,vx=east?o.w:-o.w,vy=south?o.h:-o.h;
        const px=p.x-r.x,py=p.y-r.y,raw=((px-anchorX)*vx+(py-anchorY)*vy)/(vx*vx+vy*vy);
        const maxScale=Math.min((east?r.w+4-anchorX:anchorX+4)/o.w,(south?r.h+4-anchorY:anchorY+4)/o.h),minScale=Math.max(.5/o.w,.5/o.h);
        const scale=Math.max(minScale,Math.min(maxScale,Math.round(raw*40)/40)),w=o.w*scale,h=o.h*scale;
        r[drag.key]={x:east?anchorX:anchorX-w,y:south?anchorY:anchorY-h,w,h};
      }
      drag.changed=true;render();return;
    }
    if(drag.mode==='bg-move'||drag.mode==='bg-resize'){
      const o=drag.origin,dx=Math.round(p.x-drag.start.x),dy=Math.round(p.y-drag.start.y),side=drag.side;Object.assign(background,o);
      if(drag.mode==='bg-move'){background.x=o.x+dx;background.y=o.y+dy;}
      else{
        if(side.includes('e'))background.w=Math.max(1,o.w+dx);
        if(side.includes('s'))background.h=Math.max(1,o.h+dy);
        if(side.includes('w')){background.w=Math.max(1,o.w-dx);background.x=o.x+o.w-background.w;}
        if(side.includes('n')){background.h=Math.max(1,o.h-dy);background.y=o.y+o.h-background.h;}
      }
      drag.invalid=background.w>4000||background.h>4000||Math.abs(background.x)>2000||Math.abs(background.y)>2000;render();return;
    }
    if(drag.mode==='resize'){
      const r=rooms.find(r=>r.id===drag.id),o=drag.origin,side=drag.side,min=minSize(r);
      const dx=Math.round(p.x-drag.start.x),dy=Math.round(p.y-drag.start.y);
      Object.assign(r,o);
      if(side.includes('e'))r.w=Math.max(min,o.w+dx);
      if(side.includes('s'))r.h=Math.max(min,o.h+dy);
      if(side.includes('w')){r.w=Math.max(min,o.w-dx);r.x=o.x+o.w-r.w;}
      if(side.includes('n')){r.h=Math.max(min,o.h-dy);r.y=o.y+o.h-r.h;}
      drag.invalid=collides(r)||r.w>4000||r.h>4000||Math.abs(r.x)>2000||Math.abs(r.y)>2000;render();return;
    }
    if(drag.mode==='select'){
      drag.end=p; const x1=Math.min(p.x,drag.start.x),y1=Math.min(p.y,drag.start.y),x2=Math.max(p.x,drag.start.x),y2=Math.max(p.y,drag.start.y);
      selected=new Set(drag.base);
      for(const r of rooms)if(r.x>=x1&&r.y>=y1&&r.x+r.w<=x2&&r.y+r.h<=y2)selected.add(r.id);
      render();return;
    }
    const dx=Math.round(p.x-drag.start.x),dy=Math.round(p.y-drag.start.y);
    for(const o of drag.origins){const r=rooms.find(r=>r.id===o.id);r.x=o.x+dx;r.y=o.y+dy;}
    drag.invalid=rooms.some(a=>selected.has(a.id)&&(Math.abs(a.x)>2000||Math.abs(a.y)>2000||rooms.some(b=>!selected.has(b.id)&&a.x<b.x+b.w&&a.x+a.w>b.x&&a.y<b.y+b.h&&a.y+a.h>b.y)));
    render();
  });
  board.addEventListener('pointerup',finishDrag);
  board.addEventListener('pointercancel',finishDrag);
  board.addEventListener('lostpointercapture',e=>{if(drag?.pointerId===e.pointerId)finishDrag({pointerId:e.pointerId,type:'pointercancel'});});
  board.addEventListener('pointerdown',e=>{
    if(e.button===1 || (e.button===0 && (spaceDown || e.target===board && e.altKey))){e.preventDefault();closeMenu();drag={mode:'pan',pointerId:e.pointerId,clientX:e.clientX,clientY:e.clientY,panX,panY};board.setPointerCapture(e.pointerId);return;}
    if(!backgroundEdit&&imageEditRoomId===null&&e.button===0 && (e.target===board||e.target.id==='gridPlane')){e.preventDefault();closeMenu();const p=locate(e);drag={mode:'select',pointerId:e.pointerId,start:p,end:p,base:e.shiftKey?[...selected]:[]};selected=new Set(drag.base);board.setPointerCapture(e.pointerId);render();}
  });
  board.addEventListener('contextmenu',e=>{e.preventDefault();if(!backgroundEdit&&imageEditRoomId===null&&(e.target===board||e.target.id==='gridPlane')){closeMenu();addRoom('normal',locate(e));}});
  board.addEventListener('wheel',e=>{e.preventDefault();const rect=board.getBoundingClientRect();zoomAt(zoom*(e.deltaY<0?1.12:1/1.12),e.clientX-rect.left,e.clientY-rect.top);},{passive:false});
  let spaceDown=false;
  document.addEventListener('keydown',e=>{
    if(layoutDialog.open){if(!fileDialog.open)layoutKey(e);return;}
    if(e.key==='Escape'&&!menu.hidden){e.preventDefault();e.target.blur();closeMenu();return;}
    if(document.getElementById('fileDialog').open || e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)return;
    if(drag){if(e.key==='Escape'){e.preventDefault();finishDrag({pointerId:drag.pointerId,type:'pointercancel'});}return;}
    if(e.code==='Space'){e.preventDefault();spaceDown=true;return;}
    const command=e.ctrlKey||e.metaKey;
    if(command && e.key.toLowerCase()==='z'){e.preventDefault();e.shiftKey?redo():undo();}
    else if(command && e.key.toLowerCase()==='y'){e.preventDefault();redo();}
    else if((e.key==='Delete'||e.key==='Backspace')&&(selected.size||backgroundEdit)&&imageEditRoomId===null){e.preventDefault();removeSelected();}
    else if(e.key==='Escape'){closeMenu();backgroundEdit=false;imageEditRoomId=null;selected.clear();render();}
  });
  document.addEventListener('keyup',e=>{if(e.code==='Space')spaceDown=false;});
  window.addEventListener('blur',()=>{spaceDown=false;if(drag)finishDrag({pointerId:drag.pointerId,type:'pointercancel'});});
  function removeSelected(){ if(readOnly)return;if(backgroundEdit){removeBackground();return;}if(!selected.size)return;closeMenu();const before=snapshot();rooms=rooms.filter(r=>!selected.has(r.id));selected.clear();pruneDoors();saveState(before);}
  function generateRandomNumbers(){ if(readOnly)return;
    closeMenu();
    const paths=rooms.filter(r=>r.type==='normal'),pending=paths.filter(r=>r.number===null);
    if(!pending.length){toast('Keine leeren Wegfelder vorhanden. Bestehende Zahlen bleiben unverändert.');return;}
    const neighbors=new Map(paths.map(r=>[r.id,[]]));
    for(let i=0;i<paths.length;i++)for(let j=i+1;j<paths.length;j++){
      // Geometry, not the open/closed flag, defines adjacency; corners do not count.
      if(connection(paths[i],paths[j])){neighbors.get(paths[i].id).push(paths[j].id);neighbors.get(paths[j].id).push(paths[i].id);}
    }
    // Shuffle the processing order, then sample uniformly from the allowed numbers.
    for(let i=pending.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[pending[i],pending[j]]=[pending[j],pending[i]];}
    const assignments=new Map(paths.filter(r=>r.number!==null).map(r=>[r.id,r.number]));
    for(const r of pending){
      const blocked=new Set(neighbors.get(r.id).map(id=>assignments.get(id)));
      const choices=[3,4,5,6,7,8,9,10,11].filter(n=>!blocked.has(n));
      // No partial update if a future field type/layout leaves no legal number.
      if(!choices.length){toast('Keine konfliktfreie Zahl verfügbar. Das Projekt bleibt unverändert.');return;}
      assignments.set(r.id,choices[Math.floor(Math.random()*choices.length)]);
    }
    const before=snapshot();
    for(const r of pending)r.number=assignments.get(r.id);
    saveState(before);
    toast(`${pending.length} leere Wegfelder befüllt (3–11). Mit einmal Rückgängig zurücksetzen.`);
  }
  function refreshNumberButtons(r){
    for(const button of numbers.querySelectorAll('button')){
      const n=button.dataset.number==='doubles'?'doubles':Number(button.dataset.number),state=isEnemy(r)?r.attacks.find(a=>a.number===n)?.state:((r.type==='crazy'?r.requirements.includes(n):r.number===n)?'active':null);
      button.classList.toggle('active',state==='active');button.classList.toggle('locked',state==='locked');
      button.setAttribute('aria-pressed',state==='locked'?'mixed':String(state==='active'));
      button.setAttribute('aria-label',`${n==='doubles'?'Pasch':n}: ${state==='active'?'aktiv':state==='locked'?'gesperrt':'nicht gewählt'}`);
      const diceColor=state==='locked'?'#9aa3ac':'#263849';if(n==='doubles')button.querySelector('svg').replaceChildren(...diceArt(28,9,18,diceColor).map(svgPrimitive));
      button.title=state==='active'?'Aktiv (schwarz)':state==='locked'?'Gesperrt (grau)':'Nicht gewählt';
    }
  }
  function openMenu(x,y,id){ if(readOnly)return;
    menuRoomId=id;const current=rooms.find(r=>r.id===id),enemy=isEnemy(current);
    document.getElementById('menuTitle').textContent=TYPE_NAMES[current.type]+' bearbeiten';
    document.getElementById('startField').checked=!!current.start;
    document.getElementById('dimmedFieldLabel').hidden=current.type!=='normal';
    document.getElementById('dimmedField').checked=!!current.dimmed;
    document.getElementById('trapForm').hidden=current.type!=='trap';document.getElementById('startField').parentElement.hidden=current.type!=='normal';if(current.type==='trap'){document.getElementById('trapKind').value=current.trapKind;document.getElementById('trapCost').value=current.trapCost;}
    document.getElementById('defeatedPreview').checked=defeatedPreviews.has(id);document.getElementById('defeatedStatus').textContent=current.defeatedImage?current.defeatedImage.name:'Noch kein besiegtes Bild';document.getElementById('removeDefeatedImage').disabled=!current.defeatedImage;document.getElementById('defeatedPreview').disabled=!current.defeatedImage;
    document.getElementById('enemyForm').hidden=!enemy;document.getElementById('numberHint').hidden=!enemy&&current.type!=='crazy';document.getElementById('numberHint').textContent=current.type==='crazy'?'Klick: Zahl in den möglichen Pool aufnehmen / entfernen.':current.type==='bonus'?'Klick: Anforderung auswählen / entfernen.':'Klick: aktiv (schwarz) → gesperrt (grau) → entfernen.';
    document.getElementById('noNumber').textContent=enemy?'Alle Angriffszahlen entfernen':current.type==='crazy'?'Alle Möglichkeiten entfernen':'Keine Zahl';
    document.getElementById('sizeHint').textContent=`${current.w} × ${current.h} Rasterfelder · ${resizable(current)?'Größe über Ziehpunkte ändern.':'Feste Größe.'}`;
    if(enemy){for(const [input,key] of [['enemyName','name'],['enemyHits','hits'],['rewardFirst','rewardFirst'],['rewardLater','rewardLater']])document.getElementById(input).value=current[key];}
    document.getElementById('editEnemyImage').textContent=defeatedPreviews.has(id)?'Besiegtes Bild positionieren / skalieren':'Bild positionieren / skalieren';
    document.getElementById('enemyImageStatus').textContent=current.image?`${current.image.name} · ${current.image.width} × ${current.image.height} Pixel`:'Noch kein Bild. Transparente PNGs sind besonders geeignet.';
    document.getElementById('editEnemyImage').disabled=!current[imageKey(current)];
    document.getElementById('removeEnemyImage').disabled=!current[imageKey(current)];
    refreshNumberButtons(current);menu.hidden=false;menu.scrollTop=0;
    positionMenu(x,y);
  }
  function positionMenu(x=parseFloat(menu.style.left)||8,y=parseFloat(menu.style.top)||8){if(menu.hidden)return;menu.style.left=`${Math.max(8,Math.min(x,window.innerWidth-menu.offsetWidth-8))}px`;menu.style.top=`${Math.max(8,Math.min(y,window.innerHeight-menu.offsetHeight-8))}px`;}
  function closeMenu(){menu.hidden=true;menuRoomId=null;}
  for(let n=2;n<=12;n++){const b=document.createElement('button');b.textContent=String(n);b.dataset.number=String(n);b.onclick=()=>setNumber(n);numbers.append(b);}
  const doublesButton=document.createElement('button');doublesButton.dataset.number='doubles';doublesButton.title='Pasch – zwei gleiche Würfel';const diceSymbol=el('svg',{viewBox:'0 0 56 18','aria-hidden':'true'});diceSymbol.append(...diceArt(28,9,18).map(svgPrimitive));doublesButton.append(diceSymbol);doublesButton.onclick=()=>setNumber('doubles');numbers.append(doublesButton);
  function setNumber(n){
    const r=rooms.find(item=>item.id===menuRoomId);if(!r)return;const before=snapshot();
    if(isEnemy(r)){
      if(n===null)r.attacks=[];
      else{const index=r.attacks.findIndex(a=>a.number===n);if(index<0)r.attacks.push({number:n,state:'active'});else if(r.type!=='bonus'&&r.attacks[index].state==='active')r.attacks[index].state='locked';else r.attacks.splice(index,1);r.attacks.sort(compareAttacks);}
      refreshNumberButtons(r);
    }else if(r.type==='crazy'){if(n===null)r.requirements=[];else if(r.requirements.includes(n))r.requirements=r.requirements.filter(v=>v!==n);else r.requirements.push(n);r.requirements.sort((a,b)=>numberOrder(a)-numberOrder(b));refreshNumberButtons(r);}
    else{r.number=n;closeMenu();}
    saveState(before);
  }
  document.getElementById('noNumber').onclick=()=>setNumber(null);
  document.getElementById('startField').onchange=e=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r)return;const before=snapshot();r.start=e.target.checked;if(r.start&&r.type==='normal'){r.dimmed=false;document.getElementById('dimmedField').checked=false;}saveState(before);};
  document.getElementById('dimmedField').onchange=e=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r||r.type!=='normal')return;const before=snapshot();r.dimmed=e.target.checked;if(r.dimmed){r.start=false;document.getElementById('startField').checked=false;}saveState(before);};
  for(const [input,key] of [['enemyName','name'],['enemyHits','hits'],['rewardFirst','rewardFirst'],['rewardLater','rewardLater']]){
    document.getElementById(input).onchange=e=>{
      const r=rooms.find(r=>r.id===menuRoomId);if(!r||!isEnemy(r))return;
      const value=key==='name'?e.target.value:Number(e.target.value);
      if(key!=='name'&&(!e.target.value||!e.target.checkValidity()||!Number.isInteger(value))){toast(key==='hits'?'Bitte 1 bis 100 ganze Treffer eingeben.':'Bitte 0 bis 999 Diamanten eingeben.');e.target.value=r[key];return;}
      const before=snapshot();r[key]=value;saveState(before);
    };
  }
  for(const key of ['trapKind','trapCost'])document.getElementById(key).onchange=e=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r||r.type!=='trap')return;const value=key==='trapCost'?Number(e.target.value):e.target.value;if(key==='trapCost'&&(!Number.isInteger(value)||value<1||value>99)){e.target.value=r[key];toast('Fallenkosten: 1 bis 99.');return;}const before=snapshot();r[key]=value;saveState(before);};
  document.getElementById('defeatedPreview').onchange=e=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r?.defeatedImage)return;e.target.checked?defeatedPreviews.add(r.id):defeatedPreviews.delete(r.id);document.getElementById('editEnemyImage').textContent=e.target.checked?'Besiegtes Bild positionieren / skalieren':'Bild positionieren / skalieren';document.getElementById('editEnemyImage').disabled=!r[imageKey(r)];render();invalidateLayoutBoard();};
  document.getElementById('defeatedImageInput').onchange=async e=>{const file=e.target.files?.[0];e.target.value='';const r=rooms.find(r=>r.id===menuRoomId),epoch=projectEpoch;if(!file||!r||!isEnemy(r))return;e.target.disabled=true;try{const image=await readImageFile(file,768);if(epoch!==projectEpoch||!rooms.includes(r))return;const before=snapshot();r.defeatedImage=image;r.defeatedImageLayout=null;saveState(before);document.getElementById('defeatedStatus').textContent=image.name;document.getElementById('removeDefeatedImage').disabled=false;document.getElementById('defeatedPreview').disabled=false;toast('Besiegtes Bild eingefügt.');}catch(error){toast(error.message);}finally{e.target.disabled=false;}};
  document.getElementById('removeDefeatedImage').onclick=()=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r)return;const before=snapshot();r.defeatedImage=null;r.defeatedImageLayout=null;defeatedPreviews.delete(r.id);saveState(before);};
  document.getElementById('closeMenu').onclick=closeMenu;
  function validateImage(asset){
    if(!asset||typeof asset.src!=='string'||asset.src.length>6500000||!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(asset.src)||!Number.isInteger(asset.width)||!Number.isInteger(asset.height)||asset.width<1||asset.height<1||asset.width>4096||asset.height>4096||typeof asset.name!=='string'||asset.name.length>200)throw Error('Ungültige Bilddaten');
    const prefix=asset.src.slice(0,asset.src.indexOf(',')),bytes=atob(asset.src.split(',')[1].slice(0,32));
    if(prefix.includes('/png')&&!bytes.startsWith('\x89PNG\r\n\x1a\n')||prefix.includes('/jpeg')&&!(bytes.charCodeAt(0)===255&&bytes.charCodeAt(1)===216)||prefix.includes('/webp')&&!(bytes.startsWith('RIFF')&&bytes.slice(8,12)==='WEBP'))throw Error('Bildformat und Dateiinhalte passen nicht zusammen');
    return {src:asset.src,width:asset.width,height:asset.height,name:asset.name};
  }
  function loadImageSource(src){
    const img=new Image(),promise=new Promise((resolve,reject)=>{
      const finish=error=>{clearTimeout(timer);img.onload=null;img.onerror=null;error?reject(error):resolve(img);};
      const timer=setTimeout(()=>finish(Error('Das Laden des Bildes dauert zu lange. Bitte erneut versuchen.')),15000);
      img.onload=()=>finish();img.onerror=()=>finish(Error('Bild konnte nicht gelesen werden'));img.src=src;
    });
    return {img,promise};
  }
  function decodedImage(asset){
    let cached=imageCache.get(asset.src);
    if(!cached){
      cached=loadImageSource(asset.src);imageCache.set(asset.src,cached);
      cached.promise.catch(()=>{if(imageCache.get(asset.src)===cached)imageCache.delete(asset.src);});
    }
    return cached.promise.then(img=>{if(img.naturalWidth!==asset.width||img.naturalHeight!==asset.height)throw Error('Bildabmessungen stimmen nicht mit der Datei überein');return img;});
  }
  async function readImageFile(file,maxDimension){
    if(!['image/png','image/jpeg','image/webp'].includes(file.type))throw Error('Bitte PNG, JPG oder WebP auswählen.');
    if(file.size>20*1024*1024)throw Error('Die Bilddatei darf höchstens 20 MB groß sein.');
    const url=URL.createObjectURL(file);
    try{
      const img=await loadImageSource(url).promise;if(!img.naturalWidth||img.naturalWidth*img.naturalHeight>40000000)throw Error('Bitte ein Bild mit höchstens 40 Megapixeln verwenden.');
      let scale=Math.min(1,maxDimension/img.naturalWidth,maxDimension/img.naturalHeight),src,width,height;
      for(let attempt=0;attempt<6;attempt++){
        width=Math.max(1,Math.round(img.naturalWidth*scale));height=Math.max(1,Math.round(img.naturalHeight*scale));
        const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;const ctx=canvas.getContext('2d');ctx.drawImage(img,0,0,width,height);
        src=canvas.toDataURL(file.type==='image/jpeg'?'image/jpeg':'image/png',.9);if(src.length<=6000000)break;scale*=.75;
      }
      const asset=validateImage({src,width,height,name:file.name.slice(0,200)});await decodedImage(asset);return asset;
    }finally{URL.revokeObjectURL(url);}
  }
  async function preloadImages(data){
    const unique=new Map();for(const r of data.rooms)for(const key of ['image','defeatedImage'])if(r[key])unique.set(r[key].src,r[key]);if(data.background)unique.set(data.background.image.src,data.background.image);for(const key of ['title','rule']){const img=data.printLayout?.[key]?.image;if(img)unique.set(img.src,img);}
    let bytes=0,pixels=0;for(const image of unique.values()){bytes+=image.src.length;pixels+=image.width*image.height;}
    if(bytes>40000000||pixels>50000000)throw Error('Zu viele große Bilder im Projekt. Bitte Bilder verkleinern.');
    // Decode sequentially to limit peak memory during import.
    for(const asset of unique.values())await decodedImage(asset);
  }
  document.getElementById('enemyImageInput').onchange=async e=>{
    const file=e.target.files?.[0];e.target.value='';if(!file)return;
    const r=rooms.find(r=>r.id===menuRoomId),epoch=projectEpoch;if(!r||!isEnemy(r))return;
    e.target.disabled=true;document.getElementById('enemyImageStatus').textContent='Bild wird eingelesen …';
    try{
      const asset=await readImageFile(file,768);await preloadImages({rooms:rooms.map(other=>other===r?{...r,image:asset}:other),background});
      if(epoch!==projectEpoch||!rooms.includes(r)){toast('Bildimport verworfen: Das Zielfeld wurde inzwischen geändert.');return;}
      const before=snapshot(),hadImage=!!r.image;r.image=asset;if(!hadImage)r.imageLayout=null;saveState(before);
      if(menuRoomId===r.id){document.getElementById('enemyImageStatus').textContent=`${asset.name} · ${asset.width} × ${asset.height} Pixel`;document.getElementById('editEnemyImage').disabled=false;document.getElementById('removeEnemyImage').disabled=false;positionMenu();}
      toast('Gegnerbild eingefügt.');
    }catch(error){document.getElementById('enemyImageStatus').textContent=error.message;toast(error.message);}finally{e.target.disabled=false;}
  };
  document.getElementById('editEnemyImage').onclick=()=>editEnemyImage(menuRoomId);
  document.getElementById('removeEnemyImage').onclick=()=>{const r=rooms.find(r=>r.id===menuRoomId);if(!r?.image)return;const before=snapshot();r.image=null;r.imageLayout=null;if(imageEditRoomId===r.id)imageEditRoomId=null;saveState(before);document.getElementById('enemyImageStatus').textContent='Bild entfernt.';document.getElementById('editEnemyImage').disabled=true;document.getElementById('removeEnemyImage').disabled=true;};
  function layoutBounds(list=rooms,bg=background){const all=(bg?[...list,bg]:[...list]).map(r=>({x:r.x,y:r.y,right:r.x+r.w,bottom:r.y+r.h}));for(const r of list)for(const key of ['imageLayout','defeatedImageLayout']){const l=r[key];if(l)all.push({x:r.x+l.x,y:r.y+l.y,right:r.x+l.x+l.w,bottom:r.y+l.y+l.h});}if(!all.length)return null;return {x:Math.min(...all.map(r=>r.x)),y:Math.min(...all.map(r=>r.y)),right:Math.max(...all.map(r=>r.right)),bottom:Math.max(...all.map(r=>r.bottom))};}
  function refreshBackgroundPanel(){
    const preview=document.getElementById('backgroundPreview');preview.hidden=!background;
    if(background){preview.src=background.image.src;document.getElementById('backgroundStatus').textContent=`${background.image.name} · ${background.w} × ${background.h} Rasterfelder`;}else{preview.removeAttribute('src');document.getElementById('backgroundStatus').textContent='Noch kein Hintergrundbild.';}
    document.getElementById('startBackgroundEdit').disabled=!background;document.getElementById('removeBackground').disabled=!background;
  }
  document.getElementById('backgroundSettings').onclick=()=>{refreshBackgroundPanel();showFilePanel('background','Hintergrundbild');};
  document.getElementById('editBackground').onclick=()=>editBackground(!backgroundEdit);
  document.getElementById('startBackgroundEdit').onclick=()=>{fileDialog.close();editBackground(true);};
  document.getElementById('removeBackground').onclick=removeBackground;
  document.getElementById('backgroundInput').onchange=async e=>{
    const file=e.target.files?.[0];e.target.value='';if(!file)return;const epoch=projectEpoch,previous=background;
    e.target.disabled=true;document.getElementById('backgroundStatus').textContent='Hintergrund wird eingelesen …';
    try{
      const asset=await readImageFile(file,2048);await preloadImages({rooms,background:{image:asset}});if(epoch!==projectEpoch||background!==previous){toast('Bildimport verworfen: Das Projekt wurde inzwischen geändert.');return;}
      const before=snapshot();
      if(background)background={...background,image:asset};
      else{
        const bounds=layoutBounds(rooms,null),ratio=asset.width/asset.height;
        const desiredWidth=bounds?Math.max(bounds.right-bounds.x+4,(bounds.bottom-bounds.y+4)*ratio):32;
        const w=Math.max(1,Math.min(4000,Math.round(desiredWidth))),h=Math.max(1,Math.min(4000,Math.round(w/ratio)));
        const cx=bounds?(bounds.x+bounds.right)/2:(viewport.clientWidth/2-panX)/zoom/CELL,cy=bounds?(bounds.y+bounds.bottom)/2:(viewport.clientHeight/2-panY)/zoom/CELL;
        background={x:Math.max(-2000,Math.min(2000,Math.round(cx-w/2))),y:Math.max(-2000,Math.min(2000,Math.round(cy-h/2))),w,h,image:asset};
      }
      saveState(before);refreshBackgroundPanel();fitAll();toast('Hintergrund eingefügt. Über „Hintergrund bearbeiten“ positionieren.');
    }catch(error){document.getElementById('backgroundStatus').textContent=error.message;}finally{e.target.disabled=false;}
  };
  // Commit focused fields before another click hides/replaces the menu.
  document.addEventListener('pointerdown',e=>{if(!menu.hidden&&!menu.contains(e.target)){if(menu.contains(document.activeElement))document.activeElement.blur();closeMenu();}},true);
  document.querySelectorAll('[data-add]').forEach(b=>b.onclick=()=>addRoom(b.dataset.add));
  document.getElementById('undo').onclick=undo;document.getElementById('redo').onclick=redo;
  document.getElementById('delete').onclick=removeSelected;
  document.getElementById('randomNumbers').onclick=generateRandomNumbers;
  document.getElementById('zoomIn').onclick=()=>zoomAt(zoom*1.25,viewport.clientWidth/2,viewport.clientHeight/2);
  document.getElementById('zoomOut').onclick=()=>zoomAt(zoom/1.25,viewport.clientWidth/2,viewport.clientHeight/2);
  document.getElementById('fit').onclick=fitAll;
  function fitAll(){const bounds=layoutBounds();if(!bounds){zoom=1;panX=viewport.clientWidth/2;panY=viewport.clientHeight/2;projectGrid();renderSelection();return;}const {x:x1,y:y1,right:x2,bottom:y2}=bounds;zoom=clampZoom(Math.min((viewport.clientWidth-90)/((x2-x1)*CELL),(viewport.clientHeight-90)/((y2-y1)*CELL)));panX=viewport.clientWidth/2-(x1+x2)/2*CELL*zoom;panY=viewport.clientHeight/2-(y1+y2)/2*CELL*zoom;projectGrid();renderSelection();}
  const fileDialog=document.getElementById('fileDialog');
  let projectURL=null;
  function showFilePanel(mode,title){closeMenu();document.getElementById('fileTitle').textContent=title;for(const id of ['save','load','image','background'])document.getElementById(id+'Panel').hidden=id!==mode;if(!fileDialog.open)fileDialog.showModal();}
  document.getElementById('closeFile').onclick=()=>fileDialog.close();
  document.getElementById('exportProject').onclick=()=>{
    const text=JSON.stringify(exportListener?exportListener():{format:documentFormat,rooms,closedDoors,nextId,background,printLayout,rules,allowedPowerups},null,2);
    document.getElementById('saveText').value=text;
    if(projectURL)URL.revokeObjectURL(projectURL);
    projectURL=URL.createObjectURL(new Blob([text],{type:'application/json'}));
    document.getElementById('projectDownload').href=projectURL;
    document.getElementById('nativeSave').hidden=typeof window.showSaveFilePicker!=='function';
    showFilePanel('save','Projekt auf dem PC speichern');
  };
  document.getElementById('nativeSave').onclick=async()=>{
    try{const handle=await window.showSaveFilePicker({suggestedName:'Dungeon_Layout.json',types:[{description:'Dungeon-Projekt',accept:{'application/json':['.json']}}]});const writable=await handle.createWritable();await writable.write(document.getElementById('saveText').value);await writable.close();toast('Projektdatei gespeichert.');}
    catch(error){if(error.name!=='AbortError')toast('Dateidialog hier nicht verfügbar. Bitte JSON herunterladen oder Projekttext kopieren.');}
  };
  document.getElementById('projectDownload').onclick=()=>toast('Download angefordert: Dungeon_Layout.json – bitte Downloads prüfen.');
  document.getElementById('copyProject').onclick=async()=>{
    const area=document.getElementById('saveText');area.focus();area.select();
    try{await navigator.clipboard.writeText(area.value);toast('Projekttext kopiert.');}
    catch{try{if(document.execCommand('copy')){toast('Projekttext kopiert.');return;}}catch{}toast('Projekttext ist markiert. Mit Strg+C kopieren.');}
  };
  document.getElementById('importProject').onclick=()=>{document.getElementById('loadFeedback').textContent='';showFilePanel('load','Projekt öffnen');};
  async function loadProject(text){
    const token=++loadToken,epoch=projectEpoch;
    try {const imported=upgradeDocument(JSON.parse(text)),data=validateProject(imported);document.getElementById('loadFeedback').textContent='Projekt und Bilder werden geladen …';await preloadImages(data);if(token!==loadToken||epoch!==projectEpoch)return;const before=snapshot();if(importListener)importListener(imported);projectEpoch++;documentFormat=data.format;rules=data.rules;allowedPowerups=data.allowedPowerups;defeatedPreviews.clear();rooms=data.rooms;closedDoors=data.closedDoors;background=data.background;printLayout=data.printLayout;invalidateLayoutBoard();backgroundEdit=false;imageEditRoomId=null;nextId=Math.max(...rooms.map(r=>r.id),0)+1;selected.clear();pruneDoors();saveState(before);render();fitAll();fileDialog.close();toast('Projekt geladen: '+rooms.length+' Felder.');}
    catch(err){if(token===loadToken)document.getElementById('loadFeedback').textContent='Projekt nicht geladen: '+err.message;}
  }
  document.getElementById('fileInput').onchange=async e=>{
    const file=e.target.files?.[0];e.target.value='';if(!file)return;
    try{await loadProject(await file.text());}catch(err){document.getElementById('loadFeedback').textContent='Datei konnte nicht gelesen werden: '+err.message;}
  };
  document.getElementById('loadTextButton').onclick=()=>loadProject(document.getElementById('loadText').value);
  function normalizeRoom(r){
    const dimmed=r.type==='normal'&&!!r.dimmed;
    const normalized={id:r.id,type:r.type,x:r.x,y:r.y,w:r.w??DIM[r.type][0],h:r.h??DIM[r.type][1],number:r.number??null,start:!!r.start&&!dimmed,dimmed};
    if(isEnemy(r))Object.assign(normalized,{number:null,name:r.name??'',hits:r.hits??4,attacks:(r.attacks??(r.number!=null?[{number:r.number,state:'active'}]:[])).map(a=>({...a})).sort(compareAttacks),rewardFirst:r.rewardFirst??0,rewardLater:r.rewardLater??0,image:r.image?validateImage(r.image):null,imageLayout:r.imageLayout?{x:r.imageLayout.x,y:r.imageLayout.y,w:r.imageLayout.w,h:r.imageLayout.h}:null});
    if(isEnemy(r)){normalized.defeatedImage=r.defeatedImage?validateImage(r.defeatedImage):null;normalized.defeatedImageLayout=r.defeatedImageLayout?{...r.defeatedImageLayout}:null;}
    if(r.type==='trap')Object.assign(normalized,{trapKind:r.trapKind??'diamonds',trapCost:r.trapCost??1});
    if(r.type==='crazy')normalized.requirements=[...(r.requirements || [])];
    return normalized;
  }
  function validateProject(data){
    if(!['dungeon-layout-v1','dungeon-layout-v2','dungeon-layout-v3','dungeon-layout-v4','dungeon-layout-v5','dungeon-layout-v6',FORMAT].includes(data?.format)||!Array.isArray(data.rooms)||data.rooms.length>3000||typeof data.closedDoors!=='object'||data.closedDoors===null||Array.isArray(data.closedDoors))throw Error('Ungültiges Projektformat');
    const ids=new Set(),normalized=[];
    for(const raw of data.rooms){
      if(!raw||!Number.isSafeInteger(raw.id)||raw.id<1||raw.id>=Number.MAX_SAFE_INTEGER||ids.has(raw.id)||!Object.hasOwn(DIM,raw.type)||!Number.isSafeInteger(raw.x)||!Number.isSafeInteger(raw.y)||Math.abs(raw.x)>2000||Math.abs(raw.y)>2000||!(raw.number==null||validNumber(raw.number)))throw Error('Ungültiges Feld');
      if(raw.type==='trap'&&(!['diamonds','life'].includes(raw.trapKind??'diamonds')||!Number.isInteger(raw.trapCost??1)||(raw.trapCost??1)<1||(raw.trapCost??1)>99))throw Error('Ungültige Fallenkosten');
      if(raw.type==='crazy'&&(!Array.isArray(raw.requirements??[])||(raw.requirements??[]).length>12||!(raw.requirements??[]).every(validNumber)||new Set(raw.requirements).size!==(raw.requirements??[]).length))throw Error('Ungültige Zufallszahlen');
      if(isEnemy(raw)){
        if(raw.name!==undefined&&(typeof raw.name!=='string'||raw.name.length>80))throw Error('Monstername: maximal 80 Zeichen');
        if(raw.hits!==undefined&&(!Number.isInteger(raw.hits)||raw.hits<1||raw.hits>100))throw Error('Treffer müssen zwischen 1 und 100 liegen');
        for(const key of ['rewardFirst','rewardLater'])if(raw[key]!==undefined&&(!Number.isInteger(raw[key])||raw[key]<0||raw[key]>999))throw Error('Belohnungen müssen zwischen 0 und 999 liegen');
        if(raw.attacks!==undefined){
          if(!Array.isArray(raw.attacks)||raw.attacks.length>12)throw Error('Ungültige Angriffszahlen');
          const used=new Set();for(const a of raw.attacks){if(!a||!validNumber(a.number)||used.has(a.number)||!['active','locked'].includes(a.state))throw Error('Ungültige Angriffszahl');used.add(a.number);}
        }
        if(raw.imageLayout!=null){const l=raw.imageLayout;if(!raw.image||!l||Array.isArray(l)||!['x','y','w','h'].every(k=>Number.isFinite(l[k]))||l.w<=0||l.h<=0)throw Error('Ungültige Position des Gegnerbildes');}
      }
      const r=normalizeRoom(raw),min=minSize(r);
      if(!Number.isInteger(r.w)||!Number.isInteger(r.h)||r.w<min||r.h<min||r.w>4000||r.h>4000||(!resizable(r)&&(r.w!==4||r.h!==4)))throw Error('Ungültige Feldgröße');
      if(r.imageLayout&&!imageLayoutWithinRoom(r,r.imageLayout))throw Error('Das Gegnerbild darf höchstens 4 Rasterfelder überstehen');
      if(r.defeatedImageLayout&&(!r.defeatedImage||!['x','y','w','h'].every(k=>Number.isFinite(r.defeatedImageLayout[k]))||!imageLayoutWithinRoom(r,r.defeatedImageLayout)))throw Error('Ungültige Position des besiegten Bildes');
      ids.add(r.id);normalized.push(r);
    }
    for(let i=0;i<normalized.length;i++)for(let j=i+1;j<normalized.length;j++){const a=normalized[i],b=normalized[j];if(a.x<b.x+b.w&&a.x+a.w>b.x&&a.y<b.y+b.h&&a.y+a.h>b.y)throw Error('Überlappende Felder');}
    const doors={};for(const [key,value] of Object.entries(data.closedDoors))if(/^\d+:\d+$/.test(key)&&value===true)doors[key]=true;
    let bg=null;if(data.background!=null){const b=data.background;if(!Number.isInteger(b.x)||!Number.isInteger(b.y)||Math.abs(b.x)>2000||Math.abs(b.y)>2000||!Number.isInteger(b.w)||!Number.isInteger(b.h)||b.w<1||b.h<1||b.w>4000||b.h>4000)throw Error('Ungültige Hintergrundgröße');bg={x:b.x,y:b.y,w:b.w,h:b.h,image:validateImage(b.image)};}
    return {format:data.format,rooms:normalized,closedDoors:doors,background:bg,printLayout:validatePrintLayout(data.printLayout),rules:structuredClone(data.rules??newRules()),allowedPowerups:[...(data.allowedPowerups??['extraLife','redDice','torch'])]};
  }
  document.getElementById('newProject').onclick=()=>{if((rooms.length||background||printLayout.name||printLayout.title.image||printLayout.rule.image)&&!confirm('Wirklich ein neues, leeres Projekt beginnen? Das aktuelle Layout bleibt über Rückgängig erreichbar.'))return;const before=snapshot();projectEpoch++;documentFormat=FORMAT;rules=newRules();defeatedPreviews.clear();rooms=[];closedDoors={};background=null;printLayout=defaultPrintLayout();invalidateLayoutBoard();backgroundEdit=false;imageEditRoomId=null;nextId=1;selected.clear();saveState(before);fitAll();};
  document.getElementById('exportImage').onclick=async e=>{
    if(!rooms.length&&!background){toast('Für einen PNG-Export zuerst Felder oder einen Hintergrund hinzufügen.');return;}
    const data=JSON.parse(snapshot()),button=e.currentTarget;button.disabled=true;
    try{
    await preloadImages(data);const bounds=layoutBounds(data.rooms,data.background);
    const x1=bounds.x*CELL-35,y1=bounds.y*CELL-35,x2=bounds.right*CELL+35,y2=bounds.bottom*CELL+35;
    const width=x2-x1,height=y2-y1,scale=Math.min(2,8192/width,8192/height,Math.sqrt(24000000/(width*height)));
    const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.ceil(width*scale));canvas.height=Math.max(1,Math.ceil(height*scale));
    const ctx=canvas.getContext('2d');if(!ctx)throw Error('Bildfläche konnte nicht erstellt werden.');
    ctx.scale(scale,scale);ctx.translate(-x1,-y1);ctx.fillStyle='#fff';ctx.fillRect(x1,y1,width,height);
    if(data.background){const b=data.background;ctx.drawImage(imageCache.get(b.image.src).img,b.x*CELL,b.y*CELL,b.w*CELL,b.h*CELL);}
    for(const r of data.rooms){
      ctx.fillStyle=r.dimmed?'#d9dde1':r.start?'#d9efc5':COLORS[r.type][0];ctx.fillRect(r.x*CELL,r.y*CELL,r.w*CELL,r.h*CELL);
      if(!isEnemy(r))for(const primitive of roomArt(r))paintPrimitive(ctx,primitive);
    }
    for(const primitive of wallArt(data.rooms,data.closedDoors))paintPrimitive(ctx,primitive);
    for(const r of data.rooms.filter(isEnemy))for(const primitive of roomArt(r,'image'))paintPrimitive(ctx,primitive);
    for(const r of data.rooms.filter(isEnemy))for(const primitive of roomArt(r,'info'))paintPrimitive(ctx,primitive);
    const url=canvas.toDataURL('image/png');if(url==='data:,')throw Error('Bild ist zu groß.');
    document.getElementById('pngPreview').src=url;document.getElementById('imageDownload').href=url;
    document.getElementById('imageDownload').download='Dungeon_Layout.png';
    document.getElementById('imageInfo').textContent=`Gesamtes Spielfeld inklusive Hintergrund · ${canvas.width} × ${canvas.height} Pixel. Ohne Raster, Durchgangsknöpfe und Auswahlmarkierungen.`;
    showFilePanel('image','Spielfeld als Bild speichern');
    }catch(error){toast('PNG konnte nicht erstellt werden: '+error.message);}finally{button.disabled=false;}
  };
  function paintPrimitive(ctx,primitive){
    const a=primitive.attrs;ctx.save();if(primitive.matrix)ctx.transform(...primitive.matrix);ctx.fillStyle=a.fill&&a.fill!=='none'?a.fill:'transparent';ctx.strokeStyle=a.stroke||'transparent';ctx.lineWidth=a['stroke-width']||1;ctx.lineJoin=a['stroke-linejoin']||'round';ctx.lineCap=a['stroke-linecap']||'butt';
    if(primitive.tag==='image'){
      const img=imageCache.get(a.href)?.img;if(img)ctx.drawImage(img,a.x,a.y,a.width,a.height);
    }else if(primitive.tag==='text'){
      ctx.font=`${a['font-weight']} ${a['font-size']}px ${a['font-family']}`;ctx.textAlign=({start:'left',end:'right',middle:'center'})[a['text-anchor']];ctx.textBaseline='middle';ctx.fillText(primitive.text,a.x,a.y);
    }else{
      let path;
      if(primitive.tag==='path')path=new Path2D(a.d);
      else{path=new Path2D();if(primitive.tag==='circle')path.arc(a.cx,a.cy,a.r,0,Math.PI*2);else path.roundRect(a.x,a.y,a.width,a.height,a.rx||0);}
      if(a.fill&&a.fill!=='none')ctx.fill(path);if(a.stroke)ctx.stroke(path);
    }
    ctx.restore();
  }
  const observer=new ResizeObserver(()=>{projectGrid();positionMenu();});observer.observe(viewport);
  async function boot(){
    document.getElementById('app').inert=true;
    try{let saved=null;// Online lädt der Host die richtige Karte; kein gemeinsames Offline-Backup.
if(saved){const raw=JSON.parse(saved),state=validateProject({...raw,format:raw.format||'dungeon-layout-v1',closedDoors:raw.closedDoors||{}});await preloadImages(state);rooms=state.rooms;closedDoors=state.closedDoors;background=state.background;printLayout=state.printLayout;nextId=Math.max(...rooms.map(r=>r.id),0)+1;pruneDoors();}}
    catch(e){storageNotice('Browsersicherung konnte nicht geladen werden: '+e.message+'. Bitte Projektdatei öffnen.');}
    finally{fitAll();render();document.getElementById('app').inert=false;document.documentElement.dataset.ready='true';}
  }
  // Print layout is separate from world/grid coordinates. All artwork is embedded.
  function defaultPrintLayout(){return {format:'auto',padding:24,name:'',board:{x:0,y:0,scale:1},title:{image:null,x:0,y:0,scale:1},rule:{image:null,x:0,y:0,scale:1}};}
  function validatePrintLayout(raw){
    const value=defaultPrintLayout();if(raw==null)return value;
    if(typeof raw!=='object'||Array.isArray(raw))throw Error('Ungültiges Drucklayout');
    if(raw.format!==undefined&&!['auto','portrait','landscape'].includes(raw.format))throw Error('Ungültiges Seitenformat');
    value.format=raw.format??value.format;
    if(raw.padding!==undefined&&(!Number.isFinite(raw.padding)||raw.padding<8||raw.padding>100))throw Error('Ungültiger Rahmenabstand');
    value.padding=raw.padding??value.padding;
    if(raw.name!==undefined&&(typeof raw.name!=='string'||raw.name.length>80))throw Error('Levelname: maximal 80 Zeichen');value.name=raw.name??'';
    for(const key of ['board','title','rule']){
      const src=raw[key];if(src==null)continue;if(typeof src!=='object'||Array.isArray(src))throw Error('Ungültige Layoutposition');
      for(const axis of ['x','y']){if(src[axis]!==undefined&&(!Number.isFinite(src[axis])||Math.abs(src[axis])>2))throw Error('Ungültiger Layoutversatz');value[key][axis]=src[axis]??0;}
      if(src.scale!==undefined&&(!Number.isFinite(src.scale)||src.scale<.1||src.scale>(key==='board'?2:3)))throw Error('Ungültige Layoutskalierung');value[key].scale=src.scale??1;
      if(key!=='board')value[key].image=src.image==null?null:validateImage(src.image);
    }
    return value;
  }
  let printLayout=defaultPrintLayout(),layoutTarget=null,layoutDrag=null,layoutFrame=0,layoutBoardCache=null,layoutPreparing=false;
  const layoutDialog=document.getElementById('layoutDialog'),layoutCanvas=document.getElementById('layoutCanvas'),layoutStage=document.getElementById('layoutStage');
  const layoutControls={format:document.getElementById('layoutFormat'),padding:document.getElementById('layoutPadding'),name:document.getElementById('layoutName'),board:document.getElementById('layoutBoardScale'),title:document.getElementById('layoutTitleScale'),rule:document.getElementById('layoutRuleScale')};
  function invalidateLayoutBoard(){layoutBoardCache=null;}
  function paintBoard(ctx,data){const previous=canonicalPaint;canonicalPaint=true;try{
    if(data.background){const b=data.background;ctx.drawImage(imageCache.get(b.image.src).img,b.x*CELL,b.y*CELL,b.w*CELL,b.h*CELL);}
    for(const r of data.rooms){ctx.fillStyle=r.dimmed?'#d9dde1':r.start?'#d9efc5':COLORS[r.type][0];ctx.fillRect(r.x*CELL,r.y*CELL,r.w*CELL,r.h*CELL);if(!isEnemy(r))for(const p of roomArt(r))paintPrimitive(ctx,p);}
    for(const p of wallArt(data.rooms,data.closedDoors))paintPrimitive(ctx,p);
    for(const r of data.rooms.filter(isEnemy))for(const p of roomArt(r,'image'))paintPrimitive(ctx,p);
    for(const r of data.rooms.filter(isEnemy))for(const p of roomArt(r,'info'))paintPrimitive(ctx,p);
    }finally{canonicalPaint=previous;}
  }
  function prepareBoardCache(){
    if(layoutBoardCache)return layoutBoardCache;
    const bounds=layoutBounds(),b=bounds?{x:bounds.x*CELL-8,y:bounds.y*CELL-8,w:(bounds.right-bounds.x)*CELL+16,h:(bounds.bottom-bounds.y)*CELL+16}:{x:0,y:0,w:960,h:700};
    const scale=Math.min(2,6000/b.w,6000/b.h,Math.sqrt(12000000/(b.w*b.h))),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.ceil(b.w*scale));canvas.height=Math.max(1,Math.ceil(b.h*scale));
    const ctx=canvas.getContext('2d');if(!ctx)throw Error('Spielfeldvorschau konnte nicht erstellt werden');ctx.scale(scale,scale);ctx.translate(-b.x,-b.y);paintBoard(ctx,{rooms,closedDoors,background});
    layoutBoardCache={canvas,width:b.w,height:b.h,empty:!rooms.length&&!background};return layoutBoardCache;
  }
  function layoutGeometry(){
    const source=prepareBoardCache(),W=1600,margin=28,gap=20,sideW=250,mainW=W-2*margin-gap-sideW;
    const specials=rooms.filter(r=>printGoals().some(g=>g.cellIds?.includes(r.id))).sort((a,b)=>a.y-b.y||a.x-b.x||a.id-b.id);
    const scorePlan=printScorePlan(rooms,rules,allowedPowerups),scoreWidth=mainW-2*228-30;
    const footerH=Math.max(148,Math.min(700,Math.max(Math.ceil(specials.length/5)*29+54,scoreTrackRows(scorePlan,Math.floor((scoreWidth-32)/25))*25+40)));
    const contentH=mainW*source.height/source.width+2*printLayout.padding;
    const H=printLayout.format==='portrait'?W*Math.SQRT2:printLayout.format==='landscape'?W/Math.SQRT2:Math.max(1080,Math.min(4200,contentH+footerH+2*margin+gap));
    const bodyH=H-2*margin-footerH-gap;
    const frame={x:margin,y:margin,w:mainW,h:bodyH},pad=printLayout.padding;
    const boardArea={x:frame.x+pad,y:frame.y+pad,w:frame.w-2*pad,h:frame.h-2*pad};
    const footerY=margin+bodyH+gap,specialW=228,special1={x:margin,y:footerY,w:specialW,h:footerH},special2={x:margin+specialW+12,y:footerY,w:specialW,h:footerH};
    const score={x:special2.x+specialW+18,y:footerY,w:mainW-2*specialW-30,h:footerH};
    const sideX=margin+mainW+gap,titleH=310,title={x:sideX,y:H-margin-titleH,w:sideW,h:titleH};
    const status={x:sideX,y:margin,w:sideW,h:Math.max(100,title.y-margin-gap)};
    let font=32,lines=wrapText(printLayout.name||'DEIN LEVEL',title.w-26,font);while(lines.length>3&&font>14){font--;lines=wrapText(printLayout.name||'DEIN LEVEL',title.w-26,font);}
    const titleTextH=Math.max(68,lines.length*font*1.15+30);
    return {W,H,frame,board:boardArea,special1,special2,score,scorePlan,status,titleCard:title,title:{x:title.x+10,y:title.y+titleTextH,w:title.w-20,h:title.h-titleTextH-10},rule:{x:special2.x+12,y:special2.y+80,w:special2.w-24,h:Math.max(20,special2.h-120)},specials,titleLines:lines,titleFont:font,titleTextH};
  }
  function fittedRect(source,area,transform={x:0,y:0,scale:1}){
    const k=Math.min(area.w/source.width,area.h/source.height)*transform.scale,w=source.width*k,h=source.height*k;
    return {x:area.x+(area.w-w)/2+transform.x*area.w,y:area.y+(area.h-h)/2+transform.y*area.h,w,h};
  }
  function layoutObject(key,g){const src=key==='board'?prepareBoardCache():printLayout[key].image;return src?fittedRect(src,g[key],printLayout[key]):null;}
  function withClip(ctx,area,fn){ctx.save();ctx.beginPath();ctx.rect(area.x,area.y,area.w,area.h);ctx.clip();fn();ctx.restore();}
  function inkText(ctx,text,x,y,size=20,align='center',color='#2f342f',weight=600){ctx.fillStyle=color;ctx.textAlign=align;ctx.textBaseline='middle';ctx.font=`${weight} ${size}px Georgia, serif`;ctx.fillText(text,x,y);}
  function panel(ctx,r){ctx.fillStyle='#f5f3e9';ctx.strokeStyle='#555d54';ctx.lineWidth=1.7;ctx.beginPath();ctx.roundRect(r.x,r.y,r.w,r.h,5);ctx.fill();ctx.stroke();}
  function paintFrame(ctx,r){
    ctx.strokeStyle='#30382f';ctx.lineJoin='round';
    for(const [offset,width] of [[0,3],[6,1.5],[10,1]]){ctx.lineWidth=width;ctx.beginPath();ctx.roundRect(r.x+offset,r.y+offset,r.w-2*offset,r.h-2*offset,14);ctx.stroke();}
    for(const [x,y] of [[r.x,r.y],[r.x+r.w,r.y],[r.x,r.y+r.h],[r.x+r.w,r.y+r.h]]){
      ctx.fillStyle='#eeecdf';ctx.fillRect(x-12,y-12,24,24);ctx.save();ctx.translate(x,y);ctx.rotate(Math.PI/4);ctx.fillStyle='#30382f';ctx.fillRect(-9,-9,18,18);ctx.strokeStyle='#eeecdf';ctx.lineWidth=1;ctx.strokeRect(-6,-6,12,12);ctx.restore();
    }
  }
  function paintReward(ctx,r,reward={first:3,later:1}){
    const y=r.y+r.h-18;ctx.strokeStyle='#687064';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(r.x,r.y+r.h-34);ctx.lineTo(r.x+r.w,r.y+r.h-34);ctx.stroke();
    const center=r.x+r.w/2;inkText(ctx,String(reward.first),center-53,y,22);inkText(ctx,'/',center,y,22);inkText(ctx,String(reward.later),center+23,y,22);
    for(const dx of [-28,47])for(const p of iconArt('diamond',center+dx,y,23,21))paintPrimitive(ctx,p);
  }
  function printGoals(){return rules.version===2?rules.goals:[{type:'allType',fieldType:'special',cellIds:rooms.filter(r=>r.type==='special').map(r=>r.id),reward:{first:3,later:1}},{...(rules.customGoal||{type:'none',cellIds:[]}),reward:{first:3,later:1}}];}
  function paintGoal(ctx,r,g,index){panel(ctx,r);if(g.type!=='none')paintReward(ctx,r,g.reward);const area={x:r.x+12,y:r.y+10,w:r.w-24,h:r.h-55};
    const lines=wrapText(goalText(g,rooms),area.w,13);lines.slice(0,4).forEach((line,i)=>inkText(ctx,line,area.x+area.w/2,area.y+10+i*16,13));
    if(index===1&&printLayout.rule.image)return;
    const fields=(g.cellIds||[]).map(id=>rooms.find(r=>r.id===id)).filter(Boolean),top=area.y+Math.min(4,lines.length)*16+10;
    const cols=Math.max(1,Math.ceil(Math.sqrt(fields.length))),rows=Math.ceil(fields.length/cols),size=Math.min(38,area.w/(cols*1.5),(area.y+area.h-top)/Math.max(1,rows)/1.3);
    if(size<7){inkText(ctx,`${fields.length} Zielfelder`,area.x+area.w/2,area.y+area.h-12,12);return;}
    fields.forEach((f,i)=>{const x=area.x+i%cols*area.w/cols,y=top+Math.floor(i/cols)*size*1.3;ctx.fillStyle=COLORS[f.type]?.[0]||'white';ctx.strokeStyle=COLORS[f.type]?.[1]||'#536473';ctx.lineWidth=1;ctx.fillRect(x,y,size,size);ctx.strokeRect(x,y,size,size);if(f.number==='doubles'){for(const p of diceArt(x+size/2,y+size/2,size*.26))paintPrimitive(ctx,p);}else inkText(ctx,f.number??`#${f.id}`,x+size/2,y+size/2,Math.max(8,size*.37));ctx.strokeRect(x+size+3,y+size*.32,size*.25,size*.25);});
  }
  function paintLayout(ctx,g,editing=false){
    ctx.fillStyle='#eeecdf';ctx.fillRect(0,0,g.W,g.H);
    const source=prepareBoardCache(),b=layoutObject('board',g);
    withClip(ctx,g.board,()=>{ctx.fillStyle='white';ctx.fillRect(g.board.x,g.board.y,g.board.w,g.board.h);if(!source.empty)ctx.drawImage(source.canvas,b.x,b.y,b.w,b.h);else if(editing)inkText(ctx,'Dein Spielfeld erscheint hier',g.board.x+g.board.w/2,g.board.y+g.board.h/2,24,'center','#a1a69b');});
    paintFrame(ctx,g.frame);
    const trackTools={panel,text:inkText.bind(null,ctx),art:(...args)=>{for(const p of iconArt(...args))paintPrimitive(ctx,p);}};
    paintPrintStatus(ctx,g.status,allowedPowerups,trackTools);paintPrintScore(ctx,g.score,g.scorePlan,trackTools);
    panel(ctx,g.titleCard);inkText(ctx,'REALM',g.titleCard.x+g.titleCard.w/2,g.titleCard.y+19,15,'center','#718979');
    if(printLayout.name||editing)g.titleLines.forEach((line,i)=>inkText(ctx,line,g.titleCard.x+g.titleCard.w/2,g.titleCard.y+43+i*g.titleFont*1.15,g.titleFont));
    const goals=printGoals();paintGoal(ctx,g.special1,goals[0],0);paintGoal(ctx,g.special2,goals[1],1);
    for(const key of ['title','rule']){const image=printLayout[key].image,rect=layoutObject(key,g);withClip(ctx,g[key],()=>{if(image){const img=imageCache.get(image.src)?.img;if(img?.complete)ctx.drawImage(img,rect.x,rect.y,rect.w,rect.h);}else if(editing){inkText(ctx,key==='title'?'Titelbild hochladen':'Regelbild hochladen',g[key].x+g[key].w/2,g[key].y+g[key].h/2,16,'center','#969e90',400);}});}
    if(editing&&layoutTarget){const rect=layoutObject(layoutTarget,g);ctx.save();ctx.strokeStyle='#177ab5';ctx.lineWidth=2;ctx.setLineDash([7,5]);const area=g[layoutTarget];ctx.strokeRect(area.x,area.y,area.w,area.h);ctx.setLineDash([]);if(rect){withClip(ctx,area,()=>{ctx.strokeRect(rect.x,rect.y,rect.w,rect.h);for(const p of rectCorners(rect)){ctx.fillStyle='white';ctx.fillRect(p.x-6,p.y-6,12,12);ctx.strokeRect(p.x-6,p.y-6,12,12);}});}ctx.restore();}
  }
  function rectCorners(r){return [{x:r.x,y:r.y},{x:r.x+r.w,y:r.y},{x:r.x+r.w,y:r.y+r.h},{x:r.x,y:r.y+r.h}];}
  function syncLayoutControls(){
    layoutControls.format.value=printLayout.format;layoutControls.padding.value=printLayout.padding;document.getElementById('layoutPaddingValue').textContent=printLayout.padding+' px';
    if(document.activeElement!==layoutControls.name)layoutControls.name.value=printLayout.name;
    for(const key of ['board','title','rule'])layoutControls[key].value=Math.round(printLayout[key].scale*100);
    document.getElementById('layoutBoardScaleValue').textContent=Math.round(printLayout.board.scale*100)+' %';
    document.getElementById('layoutSpecialCount').textContent='Beide Bonusaufgaben und Belohnungen werden aus den Spielregeln übernommen.';
    document.querySelectorAll('[data-layout-target]').forEach(b=>{b.classList.toggle('active',b.dataset.layoutTarget===layoutTarget);b.disabled=b.dataset.layoutTarget!=='board'&&!printLayout[b.dataset.layoutTarget].image;});
    document.querySelectorAll('[data-layout-reset],[data-layout-remove]').forEach(b=>b.disabled=!printLayout[b.dataset.layoutReset||b.dataset.layoutRemove].image);
    layoutControls.title.disabled=!printLayout.title.image;layoutControls.rule.disabled=!printLayout.rule.image;
    document.getElementById('layoutUndo').disabled=!history.length;document.getElementById('layoutRedo').disabled=!future.length;
  }
  function drawLayoutPreview(){
    layoutFrame=0;if(!layoutDialog.open||layoutPreparing)return;
    try{
      const g=layoutGeometry(),mode=document.getElementById('layoutView').value,availableW=Math.max(150,layoutStage.clientWidth-56),availableH=Math.max(150,layoutStage.clientHeight-56);
      const display=mode==='100'?1:mode==='width'?availableW/g.W:Math.min(availableW/g.W,availableH/g.H);
      const pixel=Math.min(2,window.devicePixelRatio||1),scale=Math.min(display*pixel,4096/g.W,4096/g.H);
      const w=Math.max(1,Math.round(g.W*scale)),h=Math.max(1,Math.round(g.H*scale));if(layoutCanvas.width!==w||layoutCanvas.height!==h){layoutCanvas.width=w;layoutCanvas.height=h;}
      layoutCanvas.style.width=g.W*display+'px';layoutCanvas.style.height=g.H*display+'px';
      const ctx=layoutCanvas.getContext('2d');ctx.setTransform(layoutCanvas.width/g.W,0,0,layoutCanvas.height/g.H,0,0);paintLayout(ctx,g,true);syncLayoutControls();
      const rect=layoutObject('board',g),area=g.board,cut=rect.x<area.x-.1||rect.y<area.y-.1||rect.x+rect.w>area.x+area.w+.1||rect.y+rect.h>area.y+area.h+.1;
      document.getElementById('layoutMessage').textContent=cut?'Hinweis: Spielfeld wird am Rahmen beschnitten. „Vollständig einpassen“ zeigt alles.':g.specials.length>30?'Viele Spezialfelder: Bitte Lesbarkeit in der Druckgröße prüfen.':'';
    }catch(error){document.getElementById('layoutMessage').textContent=error.message;}
  }
  function requestLayoutPreview(){if(layoutDialog.open&&!layoutFrame)layoutFrame=requestAnimationFrame(drawLayoutPreview);}
  function ensureLayoutAssets(){return Promise.resolve();}
  async function openPrintLayout(){
    if(drag)return;closeMenu();backgroundEdit=false;imageEditRoomId=null;selected.clear();render();layoutTarget=null;invalidateLayoutBoard();layoutPreparing=true;
    layoutDialog.showModal();document.getElementById('layoutMessage').textContent='Drucklayout wird vorbereitet …';
    try{await ensureLayoutAssets();await preloadImages({rooms,background,printLayout});}catch(e){document.getElementById('layoutMessage').textContent=e.message;layoutDialog.close();toast('Drucklayout konnte nicht geöffnet werden: '+e.message);}finally{layoutPreparing=false;requestLayoutPreview();}
  }
  function commitLayout(before){saveState(before);requestLayoutPreview();}
  const layoutTransactions=new Map();
  function finishLayoutInput(input){const before=layoutTransactions.get(input);if(before){layoutTransactions.delete(input);commitLayout(before);}}
  function flushLayoutInputs(){for(const input of [...layoutTransactions.keys()])finishLayoutInput(input);}
  for(const [key,input] of Object.entries(layoutControls)){
    input.addEventListener('input',()=>{if(!layoutTransactions.has(input))layoutTransactions.set(input,snapshot());
      if(key==='name')printLayout.name=input.value.slice(0,80);else if(key==='format')printLayout.format=input.value;else if(key==='padding')printLayout.padding=Number(input.value);else printLayout[key].scale=Number(input.value)/100;
      requestLayoutPreview();});
    input.addEventListener('change',()=>finishLayoutInput(input));input.addEventListener('blur',()=>finishLayoutInput(input));
  }
  document.getElementById('openLayout').onclick=openPrintLayout;
  document.getElementById('closeLayout').onclick=()=>{flushLayoutInputs();layoutDialog.close();};
  layoutDialog.addEventListener('close',()=>{flushLayoutInputs();cancelLayoutDrag();layoutTarget=null;render();});
  layoutDialog.addEventListener('cancel',e=>{if(layoutTarget||layoutDrag){e.preventDefault();cancelLayoutDrag();layoutTarget=null;requestLayoutPreview();}});
  document.getElementById('layoutView').onchange=requestLayoutPreview;
  document.getElementById('layoutBoardReset').onclick=()=>{const before=snapshot();printLayout.board={x:0,y:0,scale:1};layoutTarget='board';commitLayout(before);};
  document.querySelectorAll('[data-layout-target]').forEach(b=>b.onclick=()=>{flushLayoutInputs();layoutTarget=b.dataset.layoutTarget;requestLayoutPreview();});
  document.querySelectorAll('[data-layout-reset]').forEach(b=>b.onclick=()=>{const key=b.dataset.layoutReset,before=snapshot();Object.assign(printLayout[key],{x:0,y:0,scale:1});layoutTarget=key;commitLayout(before);});
  document.querySelectorAll('[data-layout-remove]').forEach(b=>b.onclick=()=>{const key=b.dataset.layoutRemove,before=snapshot();printLayout[key]={image:null,x:0,y:0,scale:1};layoutTarget=null;projectEpoch++;commitLayout(before);});
  for(const [key,id] of [['title','layoutTitleInput'],['rule','layoutRuleInput']])document.getElementById(id).onchange=async e=>{
    const input=e.target,file=input.files?.[0];input.value='';if(!file)return;const epoch=projectEpoch,previous=printLayout[key];input.disabled=true;
    try{const image=await readImageFile(file,1600);await preloadImages({rooms,background,printLayout:{...printLayout,[key]:{...printLayout[key],image}}});if(epoch!==projectEpoch||previous!==printLayout[key]){toast('Bildimport verworfen: Das Projekt wurde inzwischen geändert.');return;}
      const before=snapshot();printLayout[key]={image,x:0,y:0,scale:1};layoutTarget=key;commitLayout(before);
    }catch(error){toast('Bild konnte nicht geladen werden: '+error.message);}finally{input.disabled=false;}
  };
  function layoutPoint(e){const box=layoutCanvas.getBoundingClientRect(),g=layoutGeometry();return {x:(e.clientX-box.left)*g.W/box.width,y:(e.clientY-box.top)*g.H/box.height};}
  function inside(p,r){return p.x>=r.x&&p.x<=r.x+r.w&&p.y>=r.y&&p.y<=r.y+r.h;}
  function cancelLayoutDrag(){if(!layoutDrag)return;Object.assign(printLayout[layoutDrag.key],layoutDrag.origin);if(layoutCanvas.hasPointerCapture(layoutDrag.pointerId))layoutCanvas.releasePointerCapture(layoutDrag.pointerId);layoutDrag=null;requestLayoutPreview();}
  layoutCanvas.addEventListener('pointerdown',e=>{
    if(e.button!==0||layoutPreparing)return;flushLayoutInputs();const p=layoutPoint(e),g=layoutGeometry();
    let key=layoutTarget&&inside(p,g[layoutTarget])?layoutTarget:['title','rule','board'].find(k=>inside(p,g[k])&&(k==='board'||printLayout[k].image));
    if(!key){layoutTarget=null;requestLayoutPreview();return;}layoutTarget=key;const rect=layoutObject(key,g);if(!rect){requestLayoutPreview();return;}
    const hit=14*g.W/layoutCanvas.getBoundingClientRect().width,corner=rectCorners(rect).findIndex(c=>Math.hypot(c.x-p.x,c.y-p.y)<hit);
    layoutDrag={key,origin:{x:printLayout[key].x,y:printLayout[key].y,scale:printLayout[key].scale},start:p,rect,area:g[key],corner,before:snapshot(),pointerId:e.pointerId};
    layoutCanvas.setPointerCapture(e.pointerId);e.preventDefault();requestLayoutPreview();
  });
  layoutCanvas.addEventListener('pointermove',e=>{
    if(!layoutDrag)return;const d=layoutDrag,p=layoutPoint(e),target=printLayout[d.key];
    if(d.corner<0){target.x=Math.max(-2,Math.min(2,d.origin.x+(p.x-d.start.x)/d.area.w));target.y=Math.max(-2,Math.min(2,d.origin.y+(p.y-d.start.y)/d.area.h));}
    else{const center={x:d.rect.x+d.rect.w/2,y:d.rect.y+d.rect.h/2},oldDistance=Math.hypot(d.start.x-center.x,d.start.y-center.y),newDistance=Math.hypot(p.x-center.x,p.y-center.y);target.scale=Math.max(.1,Math.min(d.key==='board'?2:3,d.origin.scale*newDistance/Math.max(1,oldDistance)));}
    requestLayoutPreview();
  });
  layoutCanvas.addEventListener('pointerup',e=>{if(!layoutDrag)return;const before=layoutDrag.before;layoutDrag=null;if(layoutCanvas.hasPointerCapture(e.pointerId))layoutCanvas.releasePointerCapture(e.pointerId);commitLayout(before);});
  layoutCanvas.addEventListener('pointercancel',cancelLayoutDrag);layoutCanvas.addEventListener('lostpointercapture',cancelLayoutDrag);
  window.addEventListener('blur',cancelLayoutDrag);
  function layoutKey(e){
    if(e.target instanceof HTMLInputElement||e.target instanceof HTMLSelectElement||e.target instanceof HTMLTextAreaElement)return;
    const command=e.ctrlKey||e.metaKey;
    if(command&&e.key.toLowerCase()==='z'){e.preventDefault();cancelLayoutDrag();flushLayoutInputs();e.shiftKey?redo():undo();return;}
    if(command&&e.key.toLowerCase()==='y'){e.preventDefault();cancelLayoutDrag();flushLayoutInputs();redo();return;}
    if(layoutTarget&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();const before=snapshot(),g=layoutGeometry(),target=printLayout[layoutTarget],amount=e.shiftKey?10:1;const axis=e.key==='ArrowLeft'||e.key==='ArrowRight'?'x':'y',step=amount/(axis==='x'?g[layoutTarget].w:g[layoutTarget].h)*(e.key==='ArrowLeft'||e.key==='ArrowUp'?-1:1);target[axis]=Math.max(-2,Math.min(2,target[axis]+step));commitLayout(before);}
  }
  document.getElementById('layoutUndo').onclick=()=>{flushLayoutInputs();undo();};document.getElementById('layoutRedo').onclick=()=>{flushLayoutInputs();redo();};
  document.getElementById('layoutSave').onclick=()=>{flushLayoutInputs();document.getElementById('exportProject').click();};
  async function exportPrintCanvas(){
    flushLayoutInputs();await ensureLayoutAssets();await preloadImages({rooms,background,printLayout});const g=layoutGeometry(),scale=Math.min(2,8192/g.W,8192/g.H,Math.sqrt(20000000/(g.W*g.H))),canvas=document.createElement('canvas');canvas.width=Math.ceil(g.W*scale);canvas.height=Math.ceil(g.H*scale);const ctx=canvas.getContext('2d');if(!ctx)throw Error('Bildfläche konnte nicht erstellt werden');ctx.scale(scale,scale);paintLayout(ctx,g,false);return canvas;
  }
  document.getElementById('layoutPNG').onclick=async e=>{
    const button=e.currentTarget;button.disabled=true;
    try{const canvas=await exportPrintCanvas(),url=canvas.toDataURL('image/png');if(url==='data:,')throw Error('Bild ist zu groß');document.getElementById('pngPreview').src=url;document.getElementById('imageDownload').href=url;document.getElementById('imageDownload').download='Dungeon_Spielbogen.png';document.getElementById('imageInfo').textContent=`Vollständiger Spielbogen · ${canvas.width} × ${canvas.height} Pixel. Ohne Raster, Platzhalter und Bedienelemente.`;showFilePanel('image','Spielbogen als PNG speichern');}
    catch(error){toast('Export fehlgeschlagen: '+error.message);}finally{button.disabled=false;}
  };
  let printOpenLayout=false;
  function endLayoutPrint(){document.body.classList.remove('printing-layout');if(printOpenLayout){printOpenLayout=false;if(!layoutDialog.open)layoutDialog.showModal();requestLayoutPreview();}}
  window.addEventListener('afterprint',endLayoutPrint);
  document.getElementById('layoutPrint').onclick=async e=>{
    const button=e.currentTarget;button.disabled=true;
    try{const canvas=await exportPrintCanvas(),img=document.getElementById('layoutPrintImage');img.src=canvas.toDataURL('image/png');await img.decode();let style=document.getElementById('layoutPrintPageStyle');if(!style){style=document.createElement('style');style.id='layoutPrintPageStyle';document.head.append(style);}style.textContent=`@page { size: A4 ${canvas.width>canvas.height?'landscape':'portrait'}; margin: 7mm; }`;
      printOpenLayout=layoutDialog.open;layoutDialog.close();document.body.classList.add('printing-layout');await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));window.print();
    }catch(error){endLayoutPrint();toast('Druck konnte nicht geöffnet werden: '+error.message);}finally{button.disabled=false;}
  };
  new ResizeObserver(requestLayoutPreview).observe(layoutStage);

  window.DungeonEditor=Object.freeze({
    getDocument:()=>JSON.parse(snapshot()),
    onChange:fn=>{changeListener=fn;},onImport:fn=>{importListener=fn;},onExport:fn=>{exportListener=fn;},onSave:fn=>{saveListener=fn;},
    setReadOnly:value=>{
      if(modeApplied&&readOnly===Boolean(value))return;modeApplied=true;
      readOnly=Boolean(value);closeMenu();document.body.classList.toggle('online-readonly',readOnly);
      for(const node of document.querySelectorAll('[data-add],#newProject,#importProject,#randomNumbers,#undo,#redo,#layoutUndo,#layoutRedo,#backgroundSettings,#editBackground,#delete'))node.disabled=readOnly;
      for(const node of document.querySelectorAll('.layout-controls input,.layout-controls button,.layout-controls select:not(#layoutView)'))node.disabled=readOnly;
    },
    load:async raw=>{
      const state=validateProject(raw);await preloadImages(state);projectEpoch++;documentFormat=state.format;rules=state.rules;allowedPowerups=state.allowedPowerups;defeatedPreviews.clear();rooms=state.rooms;closedDoors=state.closedDoors;background=state.background;printLayout=state.printLayout;
      nextId=Math.max(...rooms.map(r=>r.id),0)+1;selected.clear();history=[];future=[];backgroundEdit=false;imageEditRoomId=null;invalidateLayoutBoard();pruneDoors();render();fitAll();
    },
    setRules:(next,powers)=>{if(readOnly)return;const before=snapshot();rules=structuredClone(next);allowedPowerups=[...powers];saveState(before);},
    // Read-only art for the game. Uses the exact same placement as PNG/print.
    getGameArt:()=>{canonicalPaint=true;try{return rooms.map(r=>({id:String(r.id),alive:isEnemy(r)?roomArt(r,'image')[0]?.attrs:null,defeated:isEnemy(r)&&r.defeatedImage?roomArt({...r,image:r.defeatedImage,imageLayout:r.defeatedImageLayout},'image')[0]?.attrs:null,
      numbers:r.type==='crazy'?Object.fromEntries(r.requirements.map(n=>[String(n),roomArt({...r,type:'normal',number:n})])):null}));}finally{canonicalPaint=false;}},
    exportPreview:async()=>{await preloadImages({rooms,background,printLayout});const b=layoutBounds();if(!b)return null;const width=(b.right-b.x)*CELL+16,height=(b.bottom-b.y)*CELL+16,k=Math.min(1,640/width,640/height),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.ceil(width*k));canvas.height=Math.max(1,Math.ceil(height*k));const ctx=canvas.getContext('2d');ctx.scale(k,k);ctx.translate(-b.x*CELL+8,-b.y*CELL+8);ctx.fillStyle='white';ctx.fillRect(b.x*CELL-8,b.y*CELL-8,width,height);canonicalPaint=true;try{paintBoard(ctx,{rooms,background,closedDoors});}finally{canonicalPaint=false;}return {src:canvas.toDataURL('image/png'),width:canvas.width,height:canvas.height,name:'Kartenvorschau'};},
    fit:fitAll,
  });
  document.addEventListener('keydown',event=>{if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==='s'){event.preventDefault();if(saveListener)saveListener();}},true);
  document.addEventListener('pointerdown',event=>{if(readOnly&&event.target.closest('.layout-controls,#layoutCanvas,#backgroundPanel')){event.preventDefault();event.stopImmediatePropagation();}},true);
  document.addEventListener('click',event=>{if(readOnly&&event.target.closest('.layout-controls button'))event.stopImmediatePropagation();},true);
  boot();
})();
