import {readFile} from 'node:fs/promises';
import {createPlayDatabase} from './turns.mjs';
import {emptyDocument} from '../../web/js/maps/model.js';
export async function createClassicDatabase(options){const db=await createPlayDatabase(options);await db.exec(await readFile(new URL('../../supabase/migrations/010_phase5.sql',import.meta.url),'utf8'));return db;}
export function classicFixture(){
 const d=emptyDocument(),field=(id,type,x,y,number,w=4,h=4,more={})=>({id,type,x,y,number,w,h,start:false,dimmed:false,...more});
 d.rooms=[field(1,'normal',0,0,5,4,4,{start:true}),field(2,'chest',4,0,7),field(3,'diamond',8,0,8),field(4,'special',12,0,9),
 field(5,'monster',16,0,null,8,8,{name:'Troll',hits:2,attacks:[{number:8,state:'active'},{number:9,state:'locked'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}),
 field(6,'boss',24,0,null,16,8,{name:'Drache',hits:12,attacks:[{number:8,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}),
 field(7,'chest',4,4,6),field(8,'chest',8,4,10),field(9,'chest',12,4,11),field(10,'normal',0,4,12),field(11,'normal',0,8,'doubles')];
 d.rules.unlocks=[{sourceCellId:4,targetCellId:5,number:9}];d.rules.customGoal={type:'collectDiamonds',cellIds:[],diamonds:4};
 d.allowedPowerups=['extraLife','redDice','torch','axe'];d.nextId=12;return d;
}
