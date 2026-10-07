import {chooseAiAction} from './ai.js';
import {GameCommands} from './commands.js';

// Der Hostbrowser entscheidet. PostgreSQL kontrolliert Revision, Runde,
// Berechtigung und den kompletten Zug. Mehrere Tabs können keinen Doppelzug
// auslösen; ein veralteter Vorschlag wird verworfen und frisch berechnet.
export function aiController({api,gameId,onChange=async()=>{},onError=()=>{},delay=()=>750,enabled=()=>true}){
 let closed=false,timer=null,running=false;
 const commands=new GameCommands(api);
 const stale=new Set(['GAME_ROUND_CHANGED','GAME_STATE_CHANGED','GAME_TURN_DONE','GAME_ALREADY_ROLLED','GAME_CLOSED','GAME_PAUSED','GAME_CHEST_INVALID']);
 function schedule(ms=750){if(!closed){clearTimeout(timer);timer=setTimeout(tick,ms);}}
 async function tick(){
  if(closed||running)return;
  if(!enabled()||navigator.onLine===false){schedule(1000);return;}
  running=true;let changed=false,ended=false;
  try{
   const context=await api.authRpc('get_ai_context',{p_game_id:gameId});if(closed)return;
   ended=['finished','cancelled'].includes(context.status);
   if(context.status==='playing')for(const bot of context.bots){
    if(closed||!enabled())break;
    const action=bot.canRoll?{kind:'roll'}:chooseAiAction(bot);if(!action)continue;
    const args={p_game_id:gameId,p_bot_id:bot.playerId,p_round:bot.round,p_state_revision:bot.revision,p_kind:action.kind,
     p_cell_id:action.kind==='powerup'?String(bot.pendingChest):action.cellId||null,p_middle_cell_id:action.middleCellId||null,
     p_use_red:Boolean(action.useRed),p_use_axe:Boolean(action.useAxe),p_powerup:action.powerup||null};
    try{await commands.run('perform_ai_action',args);changed=true;}catch(error){if(!stale.has(error.code))throw error;break;}
    // Nach dem Wurf werden die neu entstandenen Aktionen frisch geladen.
    if(action.kind==='roll')break;
   }
   if(changed||ended)await onChange(context);
  }catch(error){if(!closed)onError(error);}
  finally{running=false;if(!closed&&!ended)schedule(Math.max(30,Number(delay())||750));}
 }
 schedule(200);
 return {wake:()=>schedule(50),cleanup(){closed=true;clearTimeout(timer);}};
}
