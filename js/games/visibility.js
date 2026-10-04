// Sicht folgt offenen Verbindungen, niemals Pixelabständen. Unbesiegte Gegner
// sind sichtbar, beenden aber den Blick entlang des jeweiligen Weges.
export const blocksSight=room=>['monster','boss','miniboss'].includes(room?.type);
export function graphEdges(definition){
 const edges=Array.isArray(definition.graph)?definition.graph:definition.graph?.edges||[];
 return [...edges,...(definition.rules?.portalPairs||[])].map(e=>e.map(String));
}
export function visibleCells(definition,state={},radius=state.powerups?.includes('binocular')?3:2){
 const rooms=definition.document.rooms,byId=new Map(rooms.map(r=>[String(r.id),r])),reached=new Set((state.reached||[]).map(String)),dist=new Map(),queue=[];
 for(const r of rooms)if(reached.has(String(r.id))||r.start&&!blocksSight(r)){dist.set(String(r.id),0);queue.push(String(r.id));}
 const neighbors=new Map();for(const [a,b] of graphEdges(definition)){if(!neighbors.has(a))neighbors.set(a,[]);if(!neighbors.has(b))neighbors.set(b,[]);neighbors.get(a).push(b);neighbors.get(b).push(a);}
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
