import {readFile} from 'node:fs/promises';
import {createPlaytestDatabase} from './playtest-polish.mjs';
import {compileDocument,goalDefault,upgradeDocument} from '../../web/js/maps/features.js';
import {emptyDocument} from '../../web/js/maps/model.js';

export async function createSoloDatabase(){
 const db=await createPlaytestDatabase();
 await db.exec(await readFile(new URL('../../supabase/migrations/032_solo_ai_highscores.sql',import.meta.url),'utf8'));
 return db;
}
export function soloFixture(){
 const d=upgradeDocument(emptyDocument()),field=(id,type,x,number,extra={})=>({id,type,x,y:0,w:4,h:4,number,start:false,dimmed:false,...extra});
 d.rooms=[field(1,'normal',0,5,{start:true}),field(2,'chest',4,6),field(3,'diamond',8,7),
  field(4,'monster',12,null,{w:8,h:8,name:'Testtroll',hits:2,attacks:[{number:8,state:'active'}],rewardFirst:3,rewardLater:1}),
  field(5,'boss',20,null,{w:16,h:8,name:'Testdrache',hits:3,attacks:[{number:9,state:'active'}],rewardFirst:6,rewardLater:0})];
 d.allowedPowerups=['extraLife','redDice','torch','axe','binocular','horn'];d.rules.goals=[goalDefault(),goalDefault()];d.nextId=6;return compileDocument(d);
}
