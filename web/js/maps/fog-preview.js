import {boardPreview} from '../games/board-preview.js';
import {connections} from './model.js';
import {visibleCells} from '../games/visibility.js';
import {h} from '../dom.js';
let queue=Promise.resolve();const cache=new Map();
export function fogMiniature(api,map,definition=null){
 // Never briefly show the full stored PNG when fog is selected.
 const node=h('div',{class:'map-preview-wrap fog-preview','aria-label':'Nebelvorschau'},h('span',{class:'muted'},'☁ Nebelvorschau …'));
 const key=`${map.id}:${map.versionId||map.revision||''}`;
 if(!cache.has(key)){
  const job=queue.catch(()=>{}).then(async()=>{
   const d=definition||await api.authRpc('get_map',{p_map_id:map.id}).then(r=>({document:r.map.document,rules:r.map.document.rules,graph:connections(r.map.document)}));
   return new Promise((resolve,reject)=>{
    const host=h('div');host.style.cssText='position:fixed;left:-10000px;top:0;width:1000px;height:800px;visibility:hidden';document.body.append(host);
    const timer=setTimeout(()=>{preview.cleanup();host.remove();reject(Error('Vorschau nicht verfügbar.'));},25000);
    const preview=boardPreview(api,d,{prefix:'fog-preview',onReady:()=>{clearTimeout(timer);const svg=preview.thumbnail({state:{reached:[]},fog:true,visibleCells:visibleCells(d,{reached:[]}),interactive:false,hints:false});svg.setAttribute('xmlns','http://www.w3.org/2000/svg');svg.setAttribute('width','640');svg.setAttribute('height','400');const src='data:image/svg+xml;base64,'+btoa(unescape(encodeURIComponent(new XMLSerializer().serializeToString(svg))));preview.cleanup();host.remove();resolve(src);}});
    preview.update({state:{reached:[]},fog:true,visibleCells:visibleCells(d,{reached:[]}),interactive:false});host.append(preview.element);
   });
  });queue=job;cache.set(key,job);job.catch(()=>cache.delete(key));if(cache.size>40)cache.delete(cache.keys().next().value);
 }
 cache.get(key).then(src=>{if(node.isConnected)node.replaceChildren(h('img',{class:'map-miniature map-preview-image',src,alt:'Karte mit Sicht der ersten Runde'}));}).catch(()=>{node.textContent='☁ Nebelvorschau nicht verfügbar';});return node;
}
