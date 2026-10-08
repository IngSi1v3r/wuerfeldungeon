import {adventurerPlanner} from './ai-planner.js';
import {GameCommands} from './commands.js';

// Der Browser schlägt vor; PostgreSQL prüft jeden Zug erneut. Das Protokoll
// wird in derselben Transaktion wie der angenommene Zug geschrieben.
export function aiController({api,gameId,onChange=async()=>{},onError=()=>{},onAnalysis=()=>{},delay=()=>750,enabled=()=>true,stepMode=()=>false}){
 let closed=false,timer=null,running=false,lastContext=null,permittedRound=0,lastPreview=null;
 const commands=new GameCommands(api),planner=adventurerPlanner(),cache=new Map();
 const stale=new Set(['GAME_ROUND_CHANGED','GAME_STATE_CHANGED','GAME_TURN_DONE','GAME_ALREADY_ROLLED','GAME_CLOSED','GAME_PAUSED','GAME_CHEST_INVALID']);
 function schedule(ms=750){if(!closed){clearTimeout(timer);timer=setTimeout(tick,ms);}}
 async function tick(){
  if(closed||running)return;if(!enabled()||navigator.onLine===false){schedule(1000);return;}running=true;let changed=false,ended=false;
  try{
   const context=await api.authRpc('get_ai_context',{p_game_id:gameId});if(closed)return;lastContext=context;ended=['finished','cancelled'].includes(context.status);
   if(context.status==='playing'){
    const previewKey=JSON.stringify([context.round,context.phase,context.bots.map(b=>[b.playerId,b.revision,b.pendingChest,b.claims])]),plans=[];
    for(const bot of context.bots){if(closed||!enabled())break;
     if(bot.canRoll){plans.push({bot,analysis:{action:{kind:'roll'},depth:0,candidates:[]}});continue;}
     const key=JSON.stringify([bot.playerId,bot.round,bot.revision,bot.claims,bot.tasks,bot.opponents,bot.pendingChest]);
     if(!cache.has(key))cache.set(key,await planner.analyze(bot));if(closed)return;plans.push({bot,analysis:cache.get(key)});
    }
    if(cache.size>64)cache.clear();
    if(previewKey!==lastPreview){lastPreview=previewKey;onAnalysis({round:context.round,phase:context.phase,plans});}
    const hold=stepMode()&&context.phase==='choosing'&&permittedRound<context.round;
    if(hold){await onChange(context);return;}
    for(const {bot,analysis} of plans){
     if(closed||!enabled())break;
     // In Schrittansicht kann die Freigabe noch während der Planung entfallen.
     if(stepMode()&&context.phase==='choosing'&&permittedRound<context.round)break;
     const action=analysis.action;if(!action)continue;
     const args={p_game_id:gameId,p_bot_id:bot.playerId,p_round:bot.round,p_state_revision:bot.revision,p_kind:action.kind,
      p_cell_id:action.kind==='powerup'?String(bot.pendingChest):action.cellId||null,p_middle_cell_id:action.middleCellId||null,
      p_use_red:Boolean(action.useRed),p_use_axe:Boolean(action.useAxe),p_powerup:action.powerup||null,p_analysis:action.kind==='roll'?{}:analysis};
     try{await commands.run('perform_adventurer_action',args);changed=true;}catch(error){if(!stale.has(error.code))throw error;break;}
     if(action.kind==='roll')break;
    }
   }
   if(changed||ended)await onChange(context);
  }catch(error){if(!closed)onError(error);}
  finally{running=false;if(!closed&&!ended)schedule(Math.max(30,Number(delay())||750));}
 }
 schedule(200);
 return {wake:()=>schedule(50),advance(){permittedRound=lastContext?.round||0;schedule(30);},hold(){permittedRound=0;schedule(30);},cleanup(){closed=true;clearTimeout(timer);planner.cleanup();cache.clear();}};
}
