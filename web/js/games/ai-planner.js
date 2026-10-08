import {analyzeAiTurn} from './ai.js';
// Ein Worker hält Zeichnen, Zoomen und Bedienelemente während der Suche frei.
export function adventurerPlanner(){
 let worker=null,closed=false,serial=0;const pending=new Map();
 function finishWorker(){worker?.terminate();worker=null;}
 function fallback(){finishWorker();for(const [id,p] of pending){clearTimeout(p.timer);pending.delete(id);try{p.resolve(analyzeAiTurn(p.context));}catch(e){p.reject(e);}}}
 try{if(typeof Worker!=='undefined'){worker=new Worker(new URL('./ai-worker.js',import.meta.url),{type:'module'});worker.onmessage=({data})=>{const p=pending.get(data.id);if(!p)return;pending.delete(data.id);clearTimeout(p.timer);if(data.error)p.reject(Error(data.error));else p.resolve(data.result);};worker.onerror=fallback;}}catch{worker=null;}
 return {analyze(context){if(closed)return Promise.reject(Error('Planung beendet'));if(!worker)return Promise.resolve().then(()=>analyzeAiTurn(context));const id=++serial;return new Promise((resolve,reject)=>{const timer=setTimeout(fallback,20000);pending.set(id,{resolve,reject,context,timer});worker.postMessage({id,context});});},cleanup(){closed=true;finishWorker();for(const p of pending.values()){clearTimeout(p.timer);p.reject(Error('Planung beendet'));}pending.clear();}};
}
