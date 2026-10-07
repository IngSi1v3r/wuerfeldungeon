import {readFile} from 'node:fs/promises';
import {createStabilityDatabase} from './stability.mjs';
import {emptyDocument} from '../../web/js/maps/model.js';
import {upgradeDocument,goalDefault} from '../../web/js/maps/features.js';

export async function createUpgradedDatabase(){
 const db=await createStabilityDatabase();
 for(const name of ['014_editor_upgrade.sql','016_game_rules.sql'])await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`,import.meta.url),'utf8'));
 return db;
}
export function modernFixture(){
 const d=upgradeDocument(emptyDocument()),field=(id,type,x,y,number=7,more={})=>({id,type,x,y,w:4,h:4,number,start:false,dimmed:false,...more});
 const enemy=(name,hits,attacks,w=8,h=8,rewardFirst=3,rewardLater=1)=>({name,hits,attacks:attacks.map(number=>({number,state:'active'})),w,h,rewardFirst,rewardLater,image:null,imageLayout:null});
 d.rooms=[field(1,'normal',0,0,6,{start:true}),field(2,'normal',4,0,7,{dimmed:true}),field(3,'monster',8,0,null,enemy('Troll',2,[8])),
  field(4,'portal',0,4,9),field(5,'portal',40,0,9),field(6,'crazy',44,0,null,{requirements:[3,8,'doubles']}),field(7,'trap',48,0,5,{trapKind:'diamonds',trapCost:2}),
  field(8,'bonus',52,0,null,enemy('Steinrätsel',2,[6],8,8,2,0)),field(9,'goldSack',60,0),field(10,'goldCoin',64,0),field(11,'rune',40,4,9),
  field(12,'boss',8,8,null,enemy('Drache',12,[8],16,8,6,0)),field(13,'chest',4,4,6),field(14,'diamond',44,4,9),
  field(15,'trap',44,8,9,{trapKind:'life',trapCost:2}),field(16,'normal',48,8,6),field(17,'normal',0,8,8)];
 d.nextId=18;d.allowedPowerups=['extraLife','redDice','torch','axe','binocular'];d.rules.goals=[goalDefault(),goalDefault()];return d;
}
