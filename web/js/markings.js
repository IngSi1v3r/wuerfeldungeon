export const STARTER_MARKINGS=Object.freeze(['cross','pencil','weave']);
export const MARKING_LABELS=Object.freeze({cross:'Großes X',pencil:'Bleistift',weave:'Schraffur',waves:'Wellenlinien',spiral:'Spirale',solid:'Ausgemalt',seal:'Abenteurersiegel',stars:'Sternensiegel',runes:'Runenkreis',claws:'Krallenspuren'});

// Dieselben Vektorstriche für Shop-Vorschau und tatsächlichen Spielplan.
export function markingPrimitives(style,x,y,w,h){
 const path=(d,more={})=>({tag:'path',attrs:{d,stroke:'#26332d','stroke-width':3,opacity:.78,fill:'none','stroke-linecap':'round','stroke-linejoin':'round',...more}});
 if(style==='solid')return [{tag:'rect',attrs:{x,y,width:w,height:h,rx:5,fill:'#25352e',opacity:.72}}];
 if(style==='cross')return [path(`M ${x} ${y} L ${x+w} ${y+h} M ${x+w} ${y} L ${x} ${y+h}`,{'stroke-width':5,opacity:.88})];
 if(style==='waves'){const lines=[];for(let dy=6;dy<h;dy+=12)lines.push(path(`M ${x} ${y+dy} Q ${x+w/4} ${y+dy-8} ${x+w/2} ${y+dy} T ${x+w} ${y+dy}`));return lines;}
 if(style==='pencil'){const lines=[{tag:'rect',attrs:{x,y,width:w,height:h,rx:4,fill:'#526058',opacity:.16}}];for(let dy=8;dy<h;dy+=10)lines.push(path(`M ${x+3} ${y+dy} L ${x+w-3} ${y+dy-5}`,{'stroke-width':2.8,opacity:.72}));return lines;}
 const cx=x+w/2,cy=y+h/2,r=Math.min(w,h)*.44;
 const wash={tag:'rect',attrs:{x,y,width:w,height:h,rx:5,fill:style==='claws'?'#803c32':'#465572',opacity:.16}};
 if(style==='stars'){
  const star=(sx,sy,radius)=>{const pts=Array.from({length:10},(_,i)=>{const a=-Math.PI/2+i*Math.PI/5,d=i%2?radius*.43:radius;return `${sx+Math.cos(a)*d} ${sy+Math.sin(a)*d}`;});return path(`M ${pts.join(' L ')} Z`,{stroke:'#54446b','stroke-width':4,opacity:.9});};
  return [wash,star(cx,cy,r),star(x+w*.15,y+h*.2,r*.2),star(x+w*.85,y+h*.8,r*.2)];
 }
 if(style==='runes')return [wash,{tag:'circle',attrs:{cx,cy,r,fill:'none',stroke:'#285d63','stroke-width':4,opacity:.9}},path(`M ${cx} ${cy-r*.78} L ${cx+r*.55} ${cy} L ${cx} ${cy+r*.78} L ${cx-r*.55} ${cy} Z M ${cx-r*.85} ${cy} H ${cx+r*.85} M ${cx} ${cy-r} V ${cy+r}`,{stroke:'#285d63','stroke-width':4,opacity:.9})];
 if(style==='claws')return [wash,...[.16,.42,.68].map(p=>path(`M ${x+w*p} ${y+h*.1} Q ${x+w*(p+.05)} ${y+h*.4} ${x+w*(p+.1)} ${y+h*.45} L ${x+w*(p+.05)} ${y+h*.53} Q ${x+w*(p+.16)} ${y+h*.66} ${x+w*(p+.17)} ${y+h*.9}`,{stroke:'#793b32','stroke-width':6,opacity:.88}))];
 if(style==='spiral'){const pts=[];for(let i=0;i<=96;i++){const t=i/96,a=t*Math.PI*6,d=r*(1-t*.9);pts.push(`${cx+Math.cos(a)*d} ${cy+Math.sin(a)*d}`);}return [wash,path(`M ${pts.join(' L ')}`,{stroke:'#385c58','stroke-width':4.5,opacity:.9})];}
 if(style==='weave'){const lines=[];for(let dy=8;dy<h;dy+=12)lines.push(path(`M ${x} ${y+dy} L ${x+w} ${y+dy-5}`,{'stroke-width':3.5}),path(`M ${x+w*dy/h} ${y} L ${x+w*dy/h-6} ${y+h}`,{'stroke-width':2}));return [wash,...lines];}
 if(style==='seal')return [wash,{tag:'circle',attrs:{cx,cy,r,fill:'none',stroke:'#775229','stroke-width':4,opacity:.92}},path(`M ${cx-r*.5} ${cy} L ${cx-r*.1} ${cy+r*.4} L ${cx+r*.6} ${cy-r*.5}`,{stroke:'#775229','stroke-width':6,opacity:.95})];
 return markingPrimitives('cross',x,y,w,h);
}

export function markingPreview(style){
 const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox','0 0 96 96');svg.setAttribute('class','mark-preview-svg');svg.setAttribute('aria-hidden','true');
 const number=document.createElementNS(ns,'text');for(const [k,v] of Object.entries({x:48,y:54,'text-anchor':'middle','font-size':28,'font-weight':700,fill:'#294039'}))number.setAttribute(k,v);number.textContent='7';svg.append(number);
 for(const p of markingPrimitives(style,9,9,78,78)){const n=document.createElementNS(ns,p.tag);for(const [k,v] of Object.entries(p.attrs))n.setAttribute(k,v);svg.append(n);}return svg;
}
