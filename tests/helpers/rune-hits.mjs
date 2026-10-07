import {readFile} from 'node:fs/promises';
import {createShopDatabase} from './shop.mjs';
import {compileDocument,goalDefault,upgradeDocument} from '../../web/js/maps/features.js';
import {emptyDocument} from '../../web/js/maps/model.js';

export const runeHitsMigration='028_free_starters_and_rune_hits.sql';
export async function createRuneHitsDatabase(){
 const db=await createShopDatabase();
 for(const name of ['020_round_two.sql','022_print_and_cosmetics.sql','024_original_map_rules.sql','026_release_1_0_0.sql',runeHitsMigration])await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`,import.meta.url),'utf8'));
 return db;
}
export function runeHitsFixture(){
 const d=upgradeDocument(emptyDocument()),field=(id,type,x,y,number,extra={})=>({id,type,x,y,w:4,h:4,number,start:false,dimmed:false,...extra});
 d.rooms=[field(1,'normal',0,0,5,{start:true}),field(2,'rune',4,0,6,{runeEffect:'hits',runeHits:3}),field(3,'rune',4,4,7,{runeEffect:'hits',runeHits:3}),
  field(4,'monster',8,0,null,{w:8,h:8,name:'Höhlentroll',hits:2,attacks:[{number:8,state:'active'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}),
  field(5,'boss',16,0,null,{w:16,h:8,name:'Runenwächter',hits:6,attacks:[{number:9,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}),
  field(6,'rune',0,4,11)];
 d.nextId=7;d.rules.goals=[goalDefault(),goalDefault()];return compileDocument(d);
}
