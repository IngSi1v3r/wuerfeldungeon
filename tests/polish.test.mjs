import test from 'node:test';
import assert from 'node:assert/strict';
import {printScorePlan,paintPrintScore,paintPrintStatus,LIFE_PENALTIES} from '../web/editor/print-tracks.js';
import {DungeonAudio} from '../web/js/audio.js';
import {modernFixture} from './helpers/game-upgrade.mjs';

test('Druckleisten: Gold nur bei vorhandenen Feldern; genau ein Kästchen pro Fund',()=>{
 const d=modernFixture(),before=JSON.stringify(d),p=printScorePlan(d.rooms,d.rules,d.allowedPowerups);
 assert.equal(p.maximumDiamonds,13);assert.deepEqual(p.tracks.map(t=>[t.type,t.count]),[['goldSack',1],['goldCoin',1],['diamond',20]]);
 const noGold=printScorePlan(d.rooms.filter(r=>!['goldSack','goldCoin'].includes(r.type)),d.rules,d.allowedPowerups);
 assert.equal(noGold.tracks.length,1);assert.equal(JSON.stringify(d),before);
});
test('Druckleisten: Bossgruppen, spätere Belohnung, hohe Bonusziele und Extraleben einrechnen',()=>{
 const d=modernFixture();d.rooms.find(r=>r.type==='boss').rewardFirst=1;d.rooms.find(r=>r.type==='boss').rewardLater=2;
 d.rules.goals=[{type:'connect',cellIds:[1,11],reward:{first:35,later:40}},{type:'none',reward:{first:99,later:99}}];
 const p=printScorePlan(d.rooms,d.rules,d.allowedPowerups);assert.equal(p.maximumDiamonds,53);assert.equal(p.tracks.at(-1).count,60);
 assert.equal(printScorePlan(d.rooms,d.rules,[]).maximumDiamonds,52);
});
test('Saubere Vektorleisten passen vollständig in die Druckbereiche',()=>{
 const boxes=[],texts=[],ctx={fillRect(){},strokeRect(x,y,w,h){boxes.push({x,y,w,h});},save(){},restore(){},setLineDash(){}};
 const helpers={panel(){},text:(label,x,y)=>texts.push({label,x,y}),art(){}};
 const p=printScorePlan(modernFixture().rooms,modernFixture().rules,['extraLife']);
 paintPrintScore(ctx,{x:10,y:20,w:746,h:200},p,helpers);assert.equal(boxes.length,22);
 assert.ok(boxes.every(b=>b.x>=10&&b.y>=20&&b.x+b.w<=756&&b.y+b.h<=220));
 boxes.length=0;texts.length=0;paintPrintStatus(ctx,{x:1100,y:20,w:250,h:850},['extraLife','horn','torch'],helpers);
 assert.deepEqual(texts.filter(t=>/^0$|^-\d+$|^tot$/.test(t.label)).map(t=>t.label),[0,0,0,...LIFE_PENALTIES].map(String));
 assert.ok(texts.some(t=>t.label==='Das Horn des')&&texts.some(t=>t.label==='Nebeljägers'));assert.ok(boxes.every(b=>b.x>=1100&&b.x+b.w<=1350&&b.y>=20&&b.y+b.h<=870));
});
test('Hintergrundklang wechselt Akkorde, erzeugt keine Rauschschleife und stoppt unabhängig von Effekten',()=>{
 const frequencies=[],timers=[];let noiseSources=0;
 const param=()=>({value:0,setValueAtTime(v){this.value=v;},exponentialRampToValueAtTime(){},linearRampToValueAtTime(){},cancelScheduledValues(){},setTargetAtTime(){}});
 const node=()=>({connect(){},disconnect(){}}),c={currentTime:0,sampleRate:500,destination:node(),createGain:()=>({...node(),gain:param()}),createConvolver:()=>node(),createBiquadFilter:()=>({...node(),frequency:param(),Q:param()}),createBuffer:(channels,len)=>({getChannelData:()=>new Float32Array(len)}),createBufferSource:()=>{noiseSources++;return node();},createOscillator:()=>({...node(),frequency:{...param(),setValueAtTime(v){frequencies.push(v);}},start(){},stop(){}})};
 const previousSet=globalThis.setTimeout,previousClear=globalThis.clearTimeout;
 globalThis.setTimeout=(fn,ms)=>{const t={fn,ms};timers.push(t);return t;};globalThis.clearTimeout=()=>{};
 try{
  const a=new DungeonAudio();a.context=c;a.unlocked=true;a.configure({sound:false,music:true});assert.equal(a.ambient.length,1);assert.equal(noiseSources,0);
  const first=frequencies.slice();c.currentTime=17;timers.find(t=>t.ms>=15000).fn();assert.notDeepEqual(frequencies.slice(first.length,first.length+3),first.slice(0,3));
  a.configure({music:false});assert.equal(a.ambient.length,0);assert.equal(a.ambientTimer,null);assert.equal(a.preferences.sound,false);
 }finally{globalThis.setTimeout=previousSet;globalThis.clearTimeout=previousClear;}
});
