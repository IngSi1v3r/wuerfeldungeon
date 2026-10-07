import {readFile} from 'node:fs/promises';
import {createRuneHitsDatabase} from './rune-hits.mjs';
import {compileDocument,goalDefault,upgradeDocument} from '../../web/js/maps/features.js';
import {emptyDocument,connections} from '../../web/js/maps/model.js';

export const playtestMigration='030_playtest_polish.sql';
export async function createPlaytestDatabase(){
 const db=await createRuneHitsDatabase();
 await db.exec(await readFile(new URL('../../supabase/migrations/'+playtestMigration,import.meta.url),'utf8'));
 return db;
}
export function portalFixture(adjacent=false,closed=false){
 const d=upgradeDocument(emptyDocument()),field=(id,type,x,number,extra={})=>({id,type,x,y:0,w:4,h:4,number,start:false,dimmed:false,...extra});
 d.rooms=[field(1,'normal',0,5,{start:true}),field(2,'portal',4,6)];
 if(!adjacent)d.rooms.push(field(3,'normal',8,7));
 const target=adjacent?10:4,x=adjacent?8:40;
 d.rooms.push(field(target,'portal',x,6),field(5,'normal',x+4,8),
  field(6,'monster',x+8,null,{w:8,h:8,name:'Portalwächter',hits:2,attacks:[{number:8,state:'active'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}),
  field(7,'normal',x+16,9));
 if(closed)d.closedDoors['2:10']=true;
 d.nextId=11;d.rules.goals=[goalDefault(),goalDefault()];
 return compileDocument(d);
}
export function portalDefinition(d=portalFixture(),frozen=false){
 return {document:d,rules:d.rules,graph:[...connections(d),...(frozen?d.rules.portalPairs:[])]};
}

