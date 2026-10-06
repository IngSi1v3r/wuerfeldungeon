// Sicht folgt offenen Verbindungen, niemals Pixelabständen. Unbesiegte Gegner
// sind sichtbar, beenden aber den Blick entlang des jeweiligen Weges.
export const blocksSight=room=>['monster','boss','miniboss'].includes(room?.type);
export function graphEdges(definition){
 const edges=Array.isArray(definition.graph)?definition.graph:definition.graph?.edges||[];
 return [...edges,...(definition.rules?.portalPairs||[])].map(e=>e.map(String));
}
// Portalverbindungen bleiben für Bewegung und Aufgaben erhalten. Sicht kann
// erst nach dem Erreichen eines Portals hindurchgehen; ein echter Durchgang
// zwischen zwei benachbarten Portalen bleibt dagegen normal sichtbar.
export function sightEdges(definition,state={}){
 const reached=new Set((state.reached||[]).map(String)),rooms=new Map(definition.document.rooms.map(r=>[String(r.id),r])),blocked=new Set();
 const key=(a,b)=>[String(a),String(b)].sort().join(':');
 for(const [a,b] of definition.rules?.portalPairs||[]){
  if(reached.has(String(a))||reached.has(String(b)))continue;
  const left=rooms.get(String(a)),right=rooms.get(String(b)),door=[a,b].sort((x,y)=>Number(x)-Number(y)).join(':');
  const physical=left&&right&&definition.document.closedDoors?.[door]!==true&&
   (((left.x+left.w===right.x||right.x+right.w===left.x)&&Math.min(left.y+left.h,right.y+right.h)-Math.max(left.y,right.y)>=1)||
    ((left.y+left.h===right.y||right.y+right.h===left.y)&&Math.min(left.x+left.w,right.x+right.w)-Math.max(left.x,right.x)>=1));
  if(!physical)blocked.add(key(a,b));
 }
 return graphEdges(definition).filter(([a,b])=>!blocked.has(key(a,b)));
}
export function visibleCells(definition,state={},radius=state.powerups?.includes('binocular')?3:2){
 const rooms=definition.document.rooms,byId=new Map(rooms.map(r=>[String(r.id),r])),reached=new Set((state.reached||[]).map(String)),dist=new Map(),queue=[];
 for(const r of rooms)if(reached.has(String(r.id))||r.start&&!blocksSight(r)){dist.set(String(r.id),0);queue.push(String(r.id));}
 const neighbors=new Map();for(const [a,b] of sightEdges(definition,state)){if(!neighbors.has(a))neighbors.set(a,[]);if(!neighbors.has(b))neighbors.set(b,[]);neighbors.get(a).push(b);neighbors.get(b).push(a);}
 for(let i=0;i<queue.length;i++){const id=queue[i],d=dist.get(id);if(d>=radius||blocksSight(byId.get(id))&&!reached.has(id))continue;
  for(const n of neighbors.get(id)||[])if(!dist.has(n)){dist.set(n,d+1);queue.push(n);}
 }
 return [...dist.keys()];
}
export function hornIsActive(state,now=Date.now()){const expiry=Date.parse(state?.hornUntil||'');return Number.isFinite(expiry)&&expiry>now;}
export function viewVisibility(definition,state,base,now=Date.now()){
 const cells=new Set((base||visibleCells(definition,state)).map(String));
 if(hornIsActive(state,now))for(const r of definition.document.rooms)if(blocksSight(r))cells.add(String(r.id));
 return [...cells];
}
