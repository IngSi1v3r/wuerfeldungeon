// Gemeinsame Vektoren für Zeichenfläche, Spielansicht, PNG und Drucklayout.
export function fieldSymbolArt(type,cx,cy,size=36,value=3){
 const scale=size/100,matrix=[scale,0,0,scale,cx-size/2,cy-size/2],art=[];
 const add=(tag,attrs)=>art.push({tag,attrs:{...attrs,[type==='rune'?'data-rune-icon':type==='crazy'?'data-crazy-icon':'data-exact-pasch']:true},matrix});
 const path=(d,fill,stroke,width=3)=>add('path',{d,fill,stroke,'stroke-width':width,'stroke-linecap':'round','stroke-linejoin':'round'});
 if(type==='rune'){
  path('M 50 4 L 84 20 L 92 52 L 78 83 L 48 96 L 17 80 L 7 46 L 22 18 Z','#e9e0f3','#9277a8',3);
  path('M 23 25 L 47 14 L 73 25 M 17 49 L 25 76 L 47 86','none','#faf7ff',4);
  path('M 50 77 L 50 24 M 28 34 L 50 53 L 72 34 M 38 72 L 50 61 L 62 72','none','#51396d',8);
 }else if(type==='crazy'){
  path('M 16 38 C 21 9 65 5 82 28 M 73 16 L 84 29 L 67 31','none','#7b568f',6);
  path('M 85 63 C 78 92 35 95 17 72 M 27 84 L 15 72 L 32 69','none','#7b568f',6);
  path('M 29 30 L 66 25 L 77 65 L 39 74 Z','#f8f1ff','#523d68',4);
  path('M 30 30 L 48 43 L 77 38 M 48 43 L 54 71','none','#b5a4c5',3);
  for(const [x,y] of [[40,43],[48,57],[64,47],[66,60]])add('circle',{cx:x,cy:y,r:3.2,fill:'#654477'});
 }else if(type==='doubleSum'){
  const pips={1:[[25,50]],2:[[16,40],[34,60]],3:[[16,40],[25,50],[34,60]],4:[[16,40],[34,40],[16,60],[34,60]],5:[[16,40],[34,40],[25,50],[16,60],[34,60]],6:[[16,38],[34,38],[16,50],[34,50],[16,62],[34,62]]}[value]||[];
  for(const dx of [0,50]){add('rect',{x:6+dx,y:30,width:38,height:40,rx:7,fill:'#fff8e7',stroke:'#8e6a2c','stroke-width':3});for(const [x,y] of pips)add('circle',{cx:x+dx,cy:y,r:3,fill:'#5d492e'});}
  path('M 46 45 L 54 45 M 46 55 L 54 55','none','#8e6a2c',3);
 }
 return art;
}

export function fieldSymbolNode(type,size=24,value=3){
 const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');
 for(const [k,v] of Object.entries({viewBox:'0 0 100 100',width:size,height:size,'aria-hidden':'true',class:'field-symbol'}))svg.setAttribute(k,String(v));
 for(const p of fieldSymbolArt(type,50,50,100,value)){const n=document.createElementNS(ns,p.tag);for(const [k,v] of Object.entries(p.attrs))n.setAttribute(k,String(v));svg.append(n);}
 return svg;
}
