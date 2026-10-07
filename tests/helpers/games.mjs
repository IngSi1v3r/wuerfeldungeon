import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createDatabase,callRpc,TEST_ACCESS_CODE} from './database.mjs';
import {emptyDocument} from '../../web/js/maps/model.js';

export function gameFixture() {
 const d=emptyDocument();d.printLayout.name='Lava Mine';
 d.rooms=[{id:1,type:'normal',x:0,y:0,w:4,h:4,number:5,start:true,dimmed:false},
  {id:2,type:'normal',x:4,y:0,w:4,h:4,number:'doubles',start:false,dimmed:false},
  {id:3,type:'special',x:0,y:4,w:4,h:4,number:9,start:false,dimmed:false},
  {id:4,type:'diamond',x:4,y:4,w:4,h:8,number:6,start:false,dimmed:false},
  {id:5,type:'monster',x:8,y:0,w:8,h:8,number:null,start:false,dimmed:false,name:'Höhlentroll',hits:4,attacks:[{number:7,state:'active'},{number:9,state:'locked'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null},
  {id:6,type:'boss',x:8,y:8,w:16,h:8,number:null,start:false,dimmed:false,name:'Glutdrache',hits:12,attacks:[{number:8,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}];
 d.nextId=7;d.rules.unlocks=[{sourceCellId:3,targetCellId:5,number:9}];return d;
}
export async function createGamesDatabase({broadcasts=true}={}) {
 const db=await createDatabase();
 await db.exec(await readFile(new URL('../../supabase/migrations/004_phase2.sql',import.meta.url),'utf8'));
 if(broadcasts)await db.exec(`create schema realtime;create table realtime.test_signals(id bigint generated always as identity,payload jsonb,event text,topic text,is_private boolean);
  create function realtime.send(payload jsonb,event text,topic text,private boolean default true) returns void language sql as $$insert into realtime.test_signals(payload,event,topic,is_private) values(payload,event,topic,private)$$;`);
 await db.exec(await readFile(new URL('../../supabase/migrations/006_phase3.sql',import.meta.url),'utf8'));return db;
}
export async function register(db,name) {
 return callRpc(db,'register_player',{p_username:name.toLowerCase(),p_display_name:name,p_password:'testing42',p_access_code:TEST_ACCESS_CODE});
}
export const userRpc=(db,user,name,args={})=>callRpc(db,name,{p_session_token:user.session.token,...args});
export async function publishFixture(db,user,name='Lava Mine',doc=gameFixture()) {
 const rpc=(method,args)=>userRpc(db,user,method,args),created=await rpc('create_map',{p_name:name,p_document:doc});
 if(!created.ok)throw Error(JSON.stringify(created));const map=created.map,editor=randomUUID();
 await rpc('acquire_map_lock',{p_map_id:map.id,p_editor_id:editor});
 const result=await rpc('publish_map',{p_map_id:map.id,p_editor_id:editor,p_expected_revision:map.revision,p_accept_warnings:true});
 if(!result.ok)throw Error(JSON.stringify(result));return result.map;
}
