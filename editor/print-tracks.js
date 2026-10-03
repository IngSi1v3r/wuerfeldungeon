// Druckleisten werden aus der Karte berechnet, ohne eingescannte Vorlagen.
export const LIFE_PENALTIES = Object.freeze([0,0,-1,-2,-4,-6,-9,-12,-16,-20,'tot']);
const amount = value => Math.max(0, Number.isFinite(Number(value)) ? Math.floor(Number(value)) : 0);

export function printScorePlan(rooms = [], rules = {}, powers = []) {
  const goldSacks = rooms.filter(r => r.type === 'goldSack').length;
  const goldCoins = rooms.filter(r => r.type === 'goldCoin').length;
  let diamonds = rooms.filter(r => r.type === 'diamond').length;
  for (const room of rooms) {
    if (['monster','miniboss','bonus'].includes(room.type)) diamonds += Math.max(amount(room.rewardFirst),amount(room.rewardLater));
    if (room.type === 'boss') diamonds += Math.max(amount(room.rewardFirst),amount(room.rewardLater)+Math.floor(amount(room.hits)/3));
  }
  const goals = rules.version === 2 ? rules.goals || [] : [
    {type:rooms.some(r => r.type === 'special') ? 'allType' : 'none',reward:rules.specialReward || {first:3,later:1}},
    {...rules.customGoal,reward:{first:3,later:1}},
  ];
  for (const goal of goals) if (goal?.type && goal.type !== 'none') diamonds += Math.max(amount(goal.reward?.first),amount(goal.reward?.later));
  if (powers.includes('extraLife') && rooms.some(r => r.type === 'chest')) diamonds++;
  return {
    maximumDiamonds:diamonds,
    tracks:[
      ...(goldSacks ? [{type:'goldSack',label:'Goldsäcke · je 2 Punkte',count:goldSacks}] : []),
      ...(goldCoins ? [{type:'goldCoin',label:'Goldmünzen · je 1 Punkt',count:goldCoins}] : []),
      {type:'diamond',label:'Diamanten · je 3 Punkte',count:Math.max(20,Math.ceil(diamonds/10)*10)},
    ],
  };
}

export function scoreTrackRows(plan,columns) {
  return plan.tracks.reduce((sum,track)=>sum+1+Math.ceil(track.count/Math.max(1,columns)),0);
}

export function paintPrintScore(ctx,area,plan,{panel,text,art}) {
  panel(ctx,area);
  const columns=Math.max(1,Math.floor((area.w-32)/25));
  const rows=scoreTrackRows(plan,columns),step=Math.min(25,(area.h-40)/Math.max(1,rows));
  const box=Math.min(19,step*.76),left=area.x+16;
  text('PUNKTE',area.x+area.w/2,area.y+20,14);
  let y=area.y+42;
  for(const track of plan.tracks){
    art(track.type,left+10,y-4,21,19);
    text(track.label,left+28,y-3,Math.max(9,Math.min(13,step*.62)),'left');
    y+=step*.68;
    for(let i=0;i<track.count;i++){
      const col=i%columns,row=Math.floor(i/columns),x=left+col*(area.w-32)/columns;
      ctx.fillStyle='#fffef8';ctx.strokeStyle='#586858';ctx.lineWidth=1.3;
      ctx.fillRect(x,y+row*step,box,box);ctx.strokeRect(x,y+row*step,box,box);
    }
    y+=Math.ceil(track.count/columns)*step+step*.32;
  }
}

const PRINT_POWERS = Object.freeze({
  extraLife:{name:'Extraleben',detail:'+3 Leben · +1 Diamant',uses:0},
  redDice:{name:'Roter Würfel',detail:'+3 Verwendungen',uses:3},
  torch:{name:'Fackel',detail:'2 Verwendungen',uses:2},
  axe:{name:'Doppelhit',detail:'2 Verwendungen',uses:2},
  binocular:{name:'Fernglas',detail:'Sichtweite 3 · dauerhaft',uses:1},
  horn:{name:'Horn des Tiefenrufs',detail:'Monsterblick · 10 s',uses:1},
});

export function paintPrintStatus(ctx,area,powers,{panel,text,art}) {
  const life={x:area.x,y:area.y,w:82,h:area.h},power={x:area.x+92,y:area.y,w:area.w-92,h:area.h};
  panel(ctx,life);panel(ctx,power);
  text('LEBEN',life.x+life.w/2,life.y+24,14);
  const extra=powers.includes('extraLife')?3:0,labels=[...Array(extra).fill(0),...LIFE_PENALTIES];
  const step=Math.min(38,(life.h-84)/labels.length),box=Math.min(27,step*.8),first=life.y+56;
  labels.forEach((label,i)=>{
    ctx.save();ctx.strokeStyle=label==='tot'?'#874335':'#586858';ctx.fillStyle='#fffef8';ctx.lineWidth=1.5;
    if(i<extra)ctx.setLineDash([3,3]);
    ctx.fillRect(life.x+13,first+i*step,box,box);ctx.strokeRect(life.x+13,first+i*step,box,box);ctx.restore();
    text(String(label),life.x+50,first+i*step+box/2+1,12,'left',label==='tot'?'#874335':'#40533e');
  });
  if(extra){text('+3 mit',life.x+life.w/2,first+labels.length*step+14,9);text('Extraleben',life.x+life.w/2,first+labels.length*step+27,9);}
  text('POWERUPS',power.x+power.w/2,power.y+24,14);
  art('chest',power.x+power.w/2,power.y+58,58,41);
  const known=powers.filter(key=>PRINT_POWERS[key]);
  const stepPower=Math.min(112,(power.h-180)/Math.max(1,known.length));
  let y=power.y+102;
  for(const key of known){
    const info=PRINT_POWERS[key];ctx.strokeStyle='#586858';ctx.lineWidth=1.3;ctx.strokeRect(power.x+11,y-9,11,11);
    const lines=key==='horn'?['Horn des','Tiefenrufs']:[info.name];
    lines.forEach((line,i)=>text(line,power.x+29,y+i*14,12,'left'));
    text(info.detail,power.x+power.w/2,y+lines.length*14+5,10);
    const box=18,gap=7,x=power.x+(power.w-info.uses*(box+gap)+gap)/2;
    for(let i=0;i<info.uses;i++)ctx.strokeRect(x+i*(box+gap),y+lines.length*14+16,box,box);
    y+=stepPower;
  }
  if(!known.length)text('Keine Powerups',power.x+power.w/2,y,12);
  text('Roter Würfel · Start',power.x+power.w/2,power.y+power.h-58,11);
  for(let i=0;i<3;i++){ctx.strokeStyle='#8b5145';ctx.lineWidth=1.4;ctx.strokeRect(power.x+power.w/2-34+i*25,power.y+power.h-43,18,18);}
}
