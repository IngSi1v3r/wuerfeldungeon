import {analyzeAiTurn} from './ai.js';
self.addEventListener('message',event=>{const {id,context}=event.data;try{self.postMessage({id,result:analyzeAiTurn(context)});}catch(error){self.postMessage({id,error:String(error.message||error)});}});
