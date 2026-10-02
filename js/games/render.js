// Unveränderte Teilansichten behalten ihre DOM-Knoten. Damit bleiben Bilder,
// Fokus und laufende Würfelanimationen auch bei Realtime/Polling stabil.
const keys=new WeakMap();
export function renderSection(node,key,build) {
 const next=JSON.stringify(key);
 if(keys.get(node)===next)return false;
 const children=[build()].flat(Infinity).filter(child=>child!==null&&child!==undefined&&child!==false);
 node.replaceChildren(...children);keys.set(node,next);return true;
}
