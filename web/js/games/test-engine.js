import {diceCombinations,activeAttacks,ENEMY_TYPES,lifePenalty,pointsSoFar} from './rules.js';
import {graphEdges,visibleCells,viewVisibility} from './visibility.js';
import {goalTargetIds,goalRequiredCount} from '../maps/features.js';
// Bewusst nur Arbeitsspeicher: keine API, kein localStorage, keine Chronik.
export class TestGame {
 constructor(definition){this.definition=structuredClone(definition);this.reset();}
 reset(){this.round=0;this.phase='waiting_roll';this.dice=null;this.requirements={};this.traps=new Map();this.state={reached:[],monsterHits:{},diamonds:0,goldPoints:0,lostLives:0,extraLives:0,powerups:[],redUses:3,torchUses:0,axeUses:0,hornUses:0,pendingChests:[],firstKills:[],taskRewards:{}};this.finished=false;this.eliminated=false;}
 get rooms(){return this.definition.document.rooms;}
 room(id){return this.rooms.find(r=>String(r.id)===String(id));}
 reached(id){return this.state.reached.includes(String(id));}
 neighbor(a,b){return graphEdges(this.definition).some(e=>e.includes(String(a))&&e.includes(String(b)));}
 reachable(id){const r=this.room(id);return !!r&&!this.reached(id)&&(r.start&&!['monster','boss','miniboss'].includes(r.type)||this.state.reached.some(a=>this.neighbor(a,id)));}
 options(){return diceCombinations(this.dice,true,this.rooms.some(r=>r.type==='doubleSum'));}
 availablePowers(fog=true){return (this.definition.allowedPowerups||[]).filter(p=>!this.state.powerups.includes(p)&&(fog||!['binocular','horn'].includes(p)));}
 attacks(r,state=this.state){return activeAttacks(r,this.definition.rules,state);}
 matches(r,state=this.state){return (ENEMY_TYPES.has(r.type)?this.attacks(r,state):[String(r.type==='crazy'?this.requirements[r.id]:r.type==='doubleSum'?`doubles:${r.number}`:r.number)]).some(n=>this.options().includes(n));}
 actions(middle=null){
 if(this.phase!=='choosing'||this.finished||this.eliminated||this.state.pendingChests.length)return [];
 const preview=middle==null?this.state:{...this.state,reached:[...new Set([...this.state.reached,String(middle),...this.portalPartners(middle)])]};
 return this.rooms.filter(r=>!this.reached(r.id)&&this.matches(r,preview)&&(middle==null?this.reachable(r.id):this.reachable(middle)&&!ENEMY_TYPES.has(this.room(middle)?.type)&&this.linkAfterMiddle(middle,r.id))).map(r=>({cellId:String(r.id),middleCellId:middle==null?null:String(middle),redOnly:false}));
 }
 linkAfterMiddle(middle,target){const mids=[String(middle),...this.portalPartners(middle)];return !mids.includes(String(target))&&mids.some(id=>this.neighbor(id,target));}
 torchActions(){return this.state.torchUses>0?this.rooms.filter(r=>this.reachable(r.id)&&!ENEMY_TYPES.has(r.type)).flatMap(r=>this.actions(r.id)):[];}
 roll(dice=Array.from({length:4},()=>1+crypto.getRandomValues(new Uint32Array(1))[0]%6)){
 if(this.phase!=='waiting_roll'||this.finished||this.eliminated||this.state.pendingChests.length)throw Error('Zuerst den aktuellen Zug abschließen.');
 this.round++;this.dice=dice;this.phase='choosing';for(const r of this.rooms)if(r.type==='crazy'){const values=r.requirements||[];this.requirements[r.id]=values[Math.floor(Math.random()*values.length)];}
 const automatic=!this.actions().length&&!this.torchActions().length;if(automatic)this.loseLife();return {automatic,dice};
 }
 portalPartners(id){return (this.definition.rules?.portalPairs||[]).filter(e=>e.map(String).includes(String(id))).flatMap(e=>e.map(String).filter(n=>n!==String(id)));}
 reach(id){
 id=String(id);if(this.reached(id))return;const r=this.room(id);if(!r)return;this.state.reached.push(id);
 if(r.type==='diamond')this.state.diamonds++;
 if(r.type==='goldSack')this.state.goldPoints+=2;if(r.type==='goldCoin')this.state.goldPoints++;
 if(r.type==='chest'&&this.availablePowers().length)this.state.pendingChests.push(id);
 if(r.type==='trap'){if(this.traps.has(id)&&this.traps.get(id)<this.round){if(r.trapKind==='life')this.state.lostLives+=r.trapCost;else this.state.diamonds-=r.trapCost;}else if(!this.traps.has(id))this.traps.set(id,this.round);}
 for(const effect of this.definition.rules?.bossHits||[])if(String(effect.sourceCellId)===id){const boss=this.room(effect.targetCellId);if(boss?.type==='boss')this.hitEnemy(boss,effect.hits);}
 for(const n of this.portalPartners(id))this.reach(n);
 }
 hitEnemy(r,amount=1){
 const id=String(r.id);if(this.reached(id))return false;
 const hits=Math.min(r.hits,(this.state.monsterHits[id]||0)+amount);this.state.monsterHits[id]=hits;
 if(hits<r.hits)return false;
 this.reach(id);this.state.diamonds+=r.rewardFirst||0;this.state.firstKills.push(id);
 this.state.enemyCompletionRounds={...this.state.enemyCompletionRounds,[id]:this.round};return true;
 }
 play(id,{cheat=false,middle=null,axe=false}={}){
 const r=this.room(id);if(!r)throw Error('Feld nicht gefunden.');
 if(this.reached(id))return {unchanged:true};
 if(!cheat){if(!this.actions(middle).some(a=>a.cellId===String(id)))throw Error('Dieses Feld ist mit dem aktuellen Wurf nicht erreichbar.');if(middle!=null&&this.state.torchUses<1)throw Error('Keine Fackel mehr verfügbar.');if(axe&&(!ENEMY_TYPES.has(r.type)||this.state.axeUses<1))throw Error('Die Axt des Doppelschlags benötigt einen Gegner und eine freie Verwendung.');}
 const killsBefore=this.state.firstKills.length;
 if(middle!=null){this.reach(middle);this.state.torchUses--;}
 if(ENEMY_TYPES.has(r.type)){this.hitEnemy(r,axe?2:1);if(axe)this.state.axeUses--;}
 else this.reach(id);
 const defeated=this.state.firstKills.length>killsBefore;
 this.awardTasks();this.eliminated=this.state.lostLives>=11+this.state.extraLives;
 if(!cheat){this.phase='waiting_roll';this.finished=this.rooms.filter(r=>['monster','boss','miniboss'].includes(r.type)).every(r=>this.reached(r.id));}
 return {defeated,cheat};
 }
 connected(a,b){if(!this.reached(a)||!this.reached(b))return false;const seen=new Set([String(a)]),queue=[String(a)];for(const id of queue)for(const [x,y] of graphEdges(this.definition)){const n=x===id?y:y===id?x:null;if(n&&this.reached(n)&&!seen.has(n)){seen.add(n);queue.push(n);}}return seen.has(String(b));}
 awardTasks(){
 const goals=this.definition.rules?.goals||[{type:'allType',fieldType:'special',reward:{first:3,later:1}},{...this.definition.rules?.customGoal,reward:{first:3,later:1}}];
 for(let pass=0;pass<2;pass++)goals.forEach((g,i)=>{if(!g||g.type==='none'||this.state.taskRewards[i]!=null)return;const ids=goalTargetIds(g,this.rooms).map(String),need=goalRequiredCount(g,this.rooms);
 const done=g.type==='collectDiamonds'?this.state.diamonds>=g.diamonds:g.type==='connect'?ids.length===2&&this.connected(...ids):need>0&&ids.filter(id=>this.reached(id)&&(g.type!=='firstEnemies'||this.state.firstKills.includes(id))).length>=need;
 if(done){this.state.taskRewards[i]=g.reward.first;this.state.diamonds+=g.reward.first;}});
 }
 loseLife(){if(this.phase!=='choosing'||this.actions().length)throw Error('Es ist noch ein normaler Zug möglich.');this.state.lostLives++;this.phase='waiting_roll';this.eliminated=this.state.lostLives>=11+this.state.extraLives;}
 choosePower(type){if(!this.state.pendingChests.length||!this.availablePowers().includes(type))throw Error('Dieses Powerup ist nicht verfügbar.');this.state.pendingChests.shift();this.enablePower(type);if(!this.availablePowers().length)this.state.pendingChests=[];}
 enablePower(type,on=true){const s=this.state;if(!on){s.powerups=s.powerups.filter(p=>p!==type);if(type==='extraLife'){s.extraLives=0;s.diamonds--;}if(type==='redDice')s.redUses=3;if(type==='torch')s.torchUses=0;if(type==='axe')s.axeUses=0;if(type==='horn'){s.hornUses=0;delete s.hornUntil;}return;}
 const fresh=!s.powerups.includes(type);if(fresh)s.powerups.push(type);
 if(type==='extraLife'){s.extraLives=3;if(fresh)s.diamonds++;this.eliminated=s.lostLives>=14;}
 if(type==='redDice')s.redUses+=3;if(type==='torch')s.torchUses=2;if(type==='axe')s.axeUses=2;if(type==='horn')s.hornUses=1;
 }
 horn(){if(!this.state.hornUses)throw Error('Das Horn hat keine freie Verwendung.');this.state.hornUses--;this.state.hornUntil=new Date(Date.now()+10000).toISOString();}
 view(fog){return {state:this.state,roundRequirements:this.requirements,traps:[...this.traps].map(([cellId,round])=>({cellId,armed:round<this.round})),visibleCells:viewVisibility(this.definition,this.state,visibleCells(this.definition,this.state)),fog};}
 score(){return {points:pointsSoFar(this.state),penalty:lifePenalty(this.state)};}
}
