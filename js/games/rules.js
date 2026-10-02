// Darstellungshilfen. Die verbindliche Zugprüfung findet in PostgreSQL statt.
export const ENEMY_TYPES=new Set(['monster','miniboss','boss']);
export function sortRequirements(values=[]) {
 return [...new Set(values.map(String))].sort((a,b)=>a==='doubles'?1:b==='doubles'?-1:Number(a)-Number(b));
}
export function diceCombinations(dice,includeRed=false) {
 if(!Array.isArray(dice)||dice.length!==4||dice.some(v=>!Number.isInteger(v)||v<1||v>6))return [];
 const values=[],length=includeRed?4:3;
 for(let i=0;i<length;i++)for(let j=i+1;j<length;j++){values.push(String(dice[i]+dice[j]));if(dice[i]===dice[j])values.push('doubles');}
 return sortRequirements(values);
}
export function activeAttacks(room,rules,state) {
 const reached=new Set((state?.reached||[]).map(String));
 return (room.attacks||[]).filter(a=>a.state==='active'||(rules?.unlocks||[]).some(u=>String(u.targetCellId)===String(room.id)&&String(u.number)===String(a.number)&&reached.has(String(u.sourceCellId)))).map(a=>String(a.number));
}
export function lifePenalty(state) {
 const effective=Math.max(0,(state?.lostLives||0)-(state?.extraLives||0));
 return [0,0,0,-1,-2,-4,-6,-9,-12,-16,-20,-20][Math.min(11,effective)];
}
export const pointsSoFar=state=>(state?.diamonds||0)*3+lifePenalty(state);
export const requirementLabel=value=>value==='doubles'?'⚄ = ⚄':String(value);
export function roomLabel(room) {
 const type={normal:'Wegfeld',diamond:'Diamantfeld',chest:'Schatzkiste',special:'Spezialfeld',monster:'Monster',boss:'Boss',miniboss:'Mini-Boss'}[room.type]||'Feld';
 return `${type} ${room.name||`#${room.id}`}${room.number!=null?` · ${room.number==='doubles'?'Pasch':room.number}`:''}`;
}
export function elapsedChoiceSeconds(game,now=Date.now(),offset=0) {
 if(!game?.choiceStartedAt||(game.phase!=='choosing'&&!game.participants?.some(p=>p.hasPendingPowerup)))return 0;
 const end=game.status==='paused'?Date.parse(game.pausedAt):now+offset;
 return Math.max(0,Math.floor((end-Date.parse(game.choiceStartedAt))/1000));
}

export function gameWaitKind(game) {
 if(game?.participants?.some(p=>p.active&&p.hasPendingPowerup)||game?.phase==='choosing')return 'turn';
 return game?.phase==='waiting_roll'&&game.rollWaitStartedAt?'roll':null;
}
export function elapsedWaitSeconds(game,now=Date.now(),offset=0) {
 const kind=gameWaitKind(game),start=kind==='roll'?game.rollWaitStartedAt:kind==='turn'?game.choiceStartedAt:null;
 if(!start)return 0;
 const end=game.status==='paused'?Date.parse(game.pausedAt):now+offset;
 return Math.max(0,Math.floor((end-Date.parse(start))/1000));
}

export function cellReachable(definition,state,cellId){
 const id=String(cellId),reached=new Set((state?.reached||[]).map(String)),room=definition.document.rooms.find(r=>String(r.id)===id);
 if(!room||reached.has(id))return false;
 if(room.type==='normal'&&room.start)return true;
 return (Array.isArray(definition.graph)?definition.graph:definition.graph?.edges||[]).some(e=>String(e[0])===id&&reached.has(String(e[1]))||String(e[1])===id&&reached.has(String(e[0])));
}
