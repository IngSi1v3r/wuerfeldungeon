export const ADVENTURER_VERSION=2;
export const ADVENTURERS=Object.freeze([
 {id:'berserker',name:'Berserkerin',symbol:'⚔',color:'#d96355',description:'Sucht Kämpfe, drückt aufs Tempo und setzt ihre Axt früh ein.',weights:{points:1,combat:1.5,exploration:1,goals:.9,safety:.75,resources:.65,contest:.6,noise:0}},
 {id:'warden',name:'Wächter',symbol:'🛡',color:'#67b7ce',description:'Plant vorsichtig, spart Hilfsmittel und vermeidet gefährliche Fallen.',weights:{points:1,combat:1,exploration:1,goals:1,safety:1.8,resources:1.6,contest:.4,noise:0}},
 {id:'treasure',name:'Schatzjägerin',symbol:'♦',color:'#dfb653',description:'Bevorzugt Diamanten, Schatzkisten und lohnende Bonusaufgaben.',weights:{points:1.4,combat:.85,exploration:1,goals:1.3,safety:1.1,resources:1,contest:.7,noise:0}},
 {id:'rival',name:'Rivale',symbol:'♜',color:'#b58cdb',description:'Beobachtet bei offenen Karten andere Kämpfer und versucht, Erstbelohnungen zu sichern.',weights:{points:1.1,combat:1.1,exploration:1,goals:1,safety:1,resources:.8,contest:2.4,noise:0}},
 {id:'lucky',name:'Glücksritter',symbol:'✦',color:'#8bb967',description:'Spielt risikofreudig; ein kleiner Zufallsanteil sorgt für Überraschungen.',weights:{points:1,combat:1.05,exploration:1.15,goals:1,safety:.7,resources:.7,contest:.8,noise:1.8}}
]);
const balanced={id:'balanced',name:'Abenteurer',symbol:'⚑',color:'#9dc589',weights:{points:1,combat:1,exploration:1,goals:1,safety:1,resources:1,contest:1,noise:0}};
export function adventurerCharacter(id){return ADVENTURERS.find(c=>c.id===id)||balanced;}
export const ADVENTURER_COLORS=['#d96355','#67b7ce','#dfb653','#b58cdb','#8bb967','#ee9b58','#e68baa','#86bdab'];
export const ADVENTURER_MARKS=['cross','pencil','weave','spiral','claws','runes','stars','waves'];
