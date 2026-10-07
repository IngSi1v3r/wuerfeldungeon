import test from 'node:test';
import assert from 'node:assert/strict';
import {diceCombinations,sortRequirements,activeAttacks,lifePenalty,elapsedChoiceSeconds,roomLabel} from '../web/js/games/rules.js';
test('Kombinationen verwenden zwei unterschiedliche Würfel; Pasch und Summen bleiben eindeutig',()=>{
 assert.deepEqual(diceCombinations([2,4,4,5],true),['6','7','8','9','doubles']);
 assert.deepEqual(diceCombinations([1,1,1,4],false),['2','doubles']);assert.deepEqual(diceCombinations([1,1,1,4],true),['2','5','doubles']);
 assert.deepEqual(diceCombinations([6,6,6,6],true),['12','doubles']);assert.deepEqual(diceCombinations([1,7,3,4],true),[]);assert.deepEqual(diceCombinations(null),[]);
 assert.deepEqual(sortRequirements(['doubles','10','3','10','7']),['3','7','10','doubles']);
});
test('Gesperrte Zahlen werden durch alternative X-Felder freigeschaltet; Zahlen-/String-IDs passen',()=>{
 const room={id:5,attacks:[{number:8,state:'active'},{number:9,state:'locked'},{number:'doubles',state:'locked'}]},rules={unlocks:[{targetCellId:5,sourceCellId:4,number:9},{targetCellId:5,sourceCellId:7,number:9}]};
 assert.deepEqual(activeAttacks(room,rules,{reached:[]}),['8']);assert.deepEqual(activeAttacks(room,rules,{reached:['7']}),['8','9']);
 assert.match(roomLabel({id:2,type:'normal',number:'doubles'}),/Pasch/);
});
test('Lebensmalus ist die letzte Stufe, mit drei zusätzlichen Nullfeldern',()=>{
 const expected=[0,0,0,-1,-2,-4,-6,-9,-12,-16,-20,-20];
 for(let lostLives=0;lostLives<=11;lostLives++){assert.equal(lifePenalty({lostLives}),expected[lostLives]);assert.equal(lifePenalty({lostLives:lostLives+3,extraLives:3}),expected[lostLives]);}
});
test('Wartezeit verwendet Serverzeit und bleibt während der Pause stehen',()=>{
 const g={phase:'choosing',status:'playing',choiceStartedAt:'2026-10-01T10:00:00Z'};
 assert.equal(elapsedChoiceSeconds(g,Date.parse('2026-10-01T10:00:25Z'),5000),30);
 assert.equal(elapsedChoiceSeconds({...g,status:'paused',pausedAt:'2026-10-01T10:00:20Z'},Date.parse('2026-10-01T11:00:00Z')),20);
});
