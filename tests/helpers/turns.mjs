import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createGamesDatabase,userRpc,publishFixture} from './games.mjs';
import {emptyDocument} from '../../web/js/maps/model.js';

export function playFixture() {
 const d=emptyDocument(),field=(id,type,x,y,number,w=4,h=4,more={})=>({id,type,x,y,w,h,number,start:false,dimmed:false,...more});
 d.rooms=[field(1,'normal',0,0,5,4,4,{start:true}),field(2,'normal',4,0,7),field(3,'diamond',8,0,8,4,8),field(4,'special',4,4,9),
  field(5,'monster',12,0,null,8,8,{name:'Höhlentroll',hits:2,attacks:[{number:8,state:'active'},{number:9,state:'locked'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}),
  field(6,'boss',20,0,null,16,8,{name:'Glutdrache',hits:3,attacks:[{number:8,state:'active'}],rewardFirst:6,rewardLater:0,image:null,imageLayout:null}),
  field(7,'normal',0,4,6,4,4,{dimmed:true}),field(8,'normal',0,8,'doubles'),field(9,'chest',8,8,10,4,8),field(10,'normal',40,0,12,4,4,{start:true}),
  field(11,'miniboss',12,8,null,8,4,{name:'Kobold',hits:1,attacks:[{number:10,state:'active'}],rewardFirst:2,rewardLater:0,image:null,imageLayout:null})];
 d.closedDoors={'1:7':true};d.nextId=12;d.rules.unlocks=[{sourceCellId:4,targetCellId:5,number:9}];return d;
}
export async function createPlayDatabase(options) {
 const db=await createGamesDatabase(options);await db.exec(await readFile(new URL('../../supabase/migrations/008_phase4.sql',import.meta.url),'utf8'));return db;
}
// Nur in der isolierten Testdatenbank. Es gibt keinen Seed-/Würfel-RPC in der App.
export async function installTestDice(db) {
 await db.exec(`create table dungeon_private.test_dice(dice jsonb,idx int);insert into dungeon_private.test_dice values('[2,3,4,5]',0);
  create or replace function dungeon_private.roll_die() returns integer language plpgsql volatile set search_path='' as $$declare n int;begin
   select (dice->>(idx%4))::int into n from dungeon_private.test_dice;update dungeon_private.test_dice set idx=idx+1;return n;end;$$;`);
}
export async function forceDice(db,dice) {await db.query('update dungeon_private.test_dice set dice=$1,idx=0',[JSON.stringify(dice)]);}
export async function newPlayGame(db,users,settings={},map=null) {
 map||=await publishFixture(db,users[0],`Testkarte ${randomUUID().slice(0,8)}`,playFixture());
 const created=await userRpc(db,users[0],'create_game',{p_map_version_id:map.versionId,p_name:'Mine',p_settings:{maxPlayers:8,cards:'hidden',hints:true,...settings},p_password:'',p_request_id:randomUUID()});
 for(const user of users.slice(1))await userRpc(db,user,'join_game',{p_game_id:created.gameId,p_password:'',p_request_id:randomUUID()});
 const g=(await userRpc(db,users[0],'get_game',{p_game_id:created.gameId})).game;
 const result=await userRpc(db,users[0],'start_game',{p_game_id:g.id,p_expected_revision:g.revision,p_request_id:randomUUID()});if(!result.ok)throw Error(JSON.stringify(result));return g.id;
}
export async function seedState(db,game,user,patch) {await db.query('update dungeon_game_player_states set state=state||$1::jsonb where game_id=$2 and player_id=$3',[JSON.stringify(patch),game,user.profile.id]);}
