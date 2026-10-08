import {MapAssets} from './model.js';

// Older published maps have no stored PNG. Render their frozen document using
// the same editor renderer, without writing or changing the published version.
const cache=new Map();let queue=Promise.resolve();
export function renderedPreview(api,map) {
  const key=`${map.id}:${map.versionId || map.revision || ''}`;
  if(cache.has(key))return cache.get(key);
  const job=queue.catch(()=>{}).then(async()=>{
    const response=await api.authRpc('get_map',{p_map_id:map.id});
    const doc=await new MapAssets(api,map.id,null).hydrate(response.map.document);
    const frame=document.createElement('iframe');frame.src='./editor/index.html';frame.tabIndex=-1;frame.setAttribute('aria-hidden','true');
    frame.style.cssText='position:fixed;left:-10000px;top:0;width:1000px;height:800px;visibility:hidden;pointer-events:none';document.body.append(frame);
    try {
      const editor=await new Promise((resolve,reject)=>{
        let attempts=0;const timer=setInterval(()=>{
          if(frame.contentDocument?.documentElement?.dataset.ready==='true'){clearInterval(timer);resolve(frame.contentWindow.DungeonEditor);}
          else if(++attempts>250){clearInterval(timer);reject(Error('Vorschau konnte nicht geladen werden.'));}
        },40);
      });
      editor.setReadOnly(true);await editor.load(doc);return await editor.exportPreview();
    } finally {frame.remove();}
  });
  queue=job;cache.set(key,job);job.catch(()=>cache.delete(key));
  if(cache.size>60)cache.delete(cache.keys().next().value);
  return job;
}
