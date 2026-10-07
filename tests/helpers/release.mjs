import {compileDocument,goalDefault,upgradeDocument} from '../../web/js/maps/features.js';
import {emptyDocument} from '../../web/js/maps/model.js';
export function releaseFixture(type='chest'){
 const d=upgradeDocument(emptyDocument());
 const field=(id,type,x,y,number,more={})=>({id,type,x,y,w:4,h:4,number,start:false,dimmed:false,...more});
 d.rooms=[field(1,type,0,0,6,{start:true,dimmed:true}),
  field(2,'monster',4,0,null,{w:8,h:8,name:'Höhlentroll',hits:2,attacks:[{number:8,state:'active'}],rewardFirst:3,rewardLater:1,image:null,imageLayout:null}),
  field(3,'normal',12,0,7),field(4,'normal',16,0,9)];
 d.nextId=5;d.rules.goals=[goalDefault(),goalDefault()];
 return compileDocument(d);
}

