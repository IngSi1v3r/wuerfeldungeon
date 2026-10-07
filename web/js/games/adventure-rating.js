// Formelversion 1. Anzeige wird gerundet, Rangfolge verwendet den vollen Wert.
export const RATING_VERSION=1;
export const C3=107/36, C4=521/108;
export function redDiceFactor(every=1){
 const q=Math.max(1,Number(every)||1);
 return C4/(C3+(C4-C3)/q);
}
export function adventureRating({points,rounds,effort,expectedPoints,redEvery=1}){
 if(!(rounds>0&&effort>0&&expectedPoints>0))return null;
 return 100*(2*points/expectedPoints+redDiceFactor(redEvery)*effort/rounds)/3;
}
export function mapBenchmarks(definition,players=1,powerups=definition.allowedPowerups||[]){
 const rooms=definition.document.rooms,n=Math.max(1,players);
 let effort=0,base=0,firstBonus=0;
 for(const r of rooms){
  const enemy=['monster','boss','miniboss','bonus'].includes(r.type);
  effort+=enemy?Math.max(1,r.hits||1):1;
  if(enemy){
   const later=(r.rewardLater||0)+(['boss','miniboss'].includes(r.type)?Math.floor((r.hits||1)/3):0);
   base+=3*later;firstBonus+=3*((r.rewardFirst||0)-later);
  }else base+=({diamond:3,goldSack:2,goldCoin:1})[r.type]||0;
 }
 if(rooms.some(r=>r.type==='chest')&&powerups.includes('extraLife'))base+=3;
 const goals=definition.rules?.goals||[
  {type:'allType',fieldType:'special',reward:{first:3,later:1}},
  {...definition.rules?.customGoal,reward:{first:3,later:1}}
 ];
 for(const g of goals){
  const ids=g.type==='allType'?rooms.filter(r=>r.type===g.fieldType):g.cellIds||[];
  if(!g.type||g.type==='none'||g.type!=='collectDiamonds'&&!ids.length)continue;
  base+=3*(g.reward?.later||0);firstBonus+=3*((g.reward?.first||0)-(g.reward?.later||0));
 }
 return {effort,basePoints:base,firstBonusPoints:firstBonus,expectedPoints:base+firstBonus/n};
}
