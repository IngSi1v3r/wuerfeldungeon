export const COSMETICS=Object.freeze({
 diceStyle:{label:'Würfeldesign',default:'ivory',choices:{ivory:'Elfenbein',forest:'Waldgrün',midnight:'Mitternacht',amber:'Bernstein'}},
 cupStyle:{label:'Würfelbecher',default:'leather',choices:{leather:'Leder',wood:'Holz',runic:'Runenbecher'}},
 campStyle:{label:'Lagerhintergrund',default:'forest',choices:{forest:'Feenwald',dawn:'Morgenlicht',moon:'Mondhain',autumn:'Herbstwald'}},
 diceAnimation:{label:'Würfelanimation',default:'normal',choices:{none:'Keine',short:'Kurz · 2 Sekunden',normal:'Normal · 4 Sekunden',long:'Lang · 6 Sekunden'}},
});
export const cosmeticDefaults=()=>Object.fromEntries(Object.entries(COSMETICS).map(([key,s])=>[key,s.default]));
export const cosmeticValue=(prefs,key)=>Object.hasOwn(COSMETICS[key].choices,prefs?.[key])?prefs[key]:COSMETICS[key].default;
