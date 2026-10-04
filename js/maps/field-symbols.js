// Gemeinsame Vektoren für Zeichenfläche, Spielansicht, PNG und Drucklayout.
export function fieldSymbolArt(type,cx,cy,size=36,value=3){
 const scale=size/100,matrix=[scale,0,0,scale,cx-size/2,cy-size/2],art=[];
 const marker=({rune:'data-rune-icon',crazy:'data-crazy-icon',portal:'data-portal-icon',doubleSum:'data-exact-pasch'})[type]||'data-field-icon';
 const add=(tag,attrs)=>art.push({tag,attrs:{...attrs,[marker]:true},matrix});
 const path=(d,fill,stroke,width=3)=>add('path',{d,fill,stroke,'stroke-width':width,'stroke-linecap':'round','stroke-linejoin':'round'});
 if(type==='rune'){
  path('M 50 4 L 84 20 L 92 52 L 78 83 L 48 96 L 17 80 L 7 46 L 22 18 Z','#e9e0f3','#9277a8',3);
  path('M 23 25 L 47 14 L 73 25 M 17 49 L 25 76 L 47 86','none','#faf7ff',4);
  path('M 50 77 L 50 24 M 28 34 L 50 53 L 72 34 M 38 72 L 50 61 L 62 72','none','#51396d',8);
 }else if(type==='crazy'){
  path('M 16 38 C 21 9 65 5 82 28 M 73 16 L 84 29 L 67 31','none','#7b568f',6);
  path('M 85 63 C 78 92 35 95 17 72 M 27 84 L 15 72 L 32 69','none','#7b568f',6);
  // One clearly readable die face, with a consistent top and right side.
  path('M 27 30 L 39 22 L 76 22 L 64 30 Z','#e1d5ed','#523d68',3);
  path('M 64 30 L 76 22 L 76 62 L 64 73 Z','#b59acb','#523d68',3);
  add('rect',{x:25,y:30,width:39,height:43,rx:6,fill:'#fffaff',stroke:'#523d68','stroke-width':3});
  for(const [x,y] of [[35,41],[54,41],[44.5,51.5],[35,62],[54,62]])add('circle',{cx:x,cy:y,r:3,fill:'#654477'});
  for(const [x,y] of [[69,39],[69,53],[69,63]])add('circle',{cx:x,cy:y,r:1.8,fill:'#513967'});
 }else if(type==='portal'){
  add('circle',{cx:50,cy:50,r:42,fill:'#e6f8ef',stroke:'#46958b','stroke-width':3});
  add('circle',{cx:50,cy:50,r:35,fill:'#174e60',stroke:'#8ae0d0','stroke-width':3});
  path('M 22 52 C 19 28 50 16 69 31 C 88 48 73 78 50 77 C 26 77 22 48 39 38 C 58 27 78 48 65 63 C 53 77 34 62 42 49 C 50 35 67 49 57 57 C 51 64 43 56 50 51','none','#9eeddc',5);
  path('M 23 36 Q 32 19 49 18 M 72 70 Q 62 84 44 82','none','#f4fffa',3);
  add('circle',{cx:50,cy:52,r:5,fill:'#d0fff0'});
  for(const [x,y,r] of [[13,22,2],[85,32,2.5],[18,81,2.5],[82,80,1.5]])add('circle',{cx:x,cy:y,r,fill:'#548f97'});
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
