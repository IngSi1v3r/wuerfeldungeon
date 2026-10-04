import {CONFIG} from '../config.js';

export const POWERUPS=Object.freeze({extraLife:'Extraleben',redDice:'Roter Würfel',torch:'Fackel',axe:'Axt des Doppelschlags',binocular:'Fernglas',horn:'Das Horn des Nebeljägers'});
export const ENEMIES=['monster','miniboss','boss'];
export const defaultRules=()=>({version:1,unlocks:[],customGoal:{type:'none',cellIds:[],diamonds:3},specialReward:{first:3,later:1}});
export const emptyDocument=()=>({format:'dungeon-layout-v6',rooms:[],closedDoors:{},nextId:1,background:null,printLayout:{format:'auto',padding:24,name:'',board:{x:0,y:0,scale:1},title:{image:null,x:0,y:0,scale:1},rule:{image:null,x:0,y:0,scale:1}},rules:defaultRules(),allowedPowerups:['extraLife','redDice','torch']});
export function imagesIn(document) {
  return [...(document.rooms || []).flatMap(r=>[r.image,r.defeatedImage]),document.previewImage,document.background?.image,document.printLayout?.title?.image,document.printLayout?.rule?.image].filter(Boolean);
}
export function assetPath(src) {
  return typeof src==='string' && /^asset:[a-f0-9-]{36}\/[a-f0-9-]{36}\.(png|jpg|webp)$/.test(src) ? src.slice(6) : null;
}
export function assetUrl(src) {const path=assetPath(src);if (!path) throw Error('Ungültige Bildreferenz.');return `${CONFIG.supabaseUrl}/storage/v1/object/public/map-assets/${path}`;}
export function imageBlob(src) {
  const match=/^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+/]+={0,2})$/.exec(src || '');
  if (!match || src.length>6500000) throw Error('Bitte PNG, JPG oder WebP verwenden.');
  const binary=atob(match[2]);return new Blob([Uint8Array.from(binary,c=>c.charCodeAt(0))],{type:match[1]});
}
export async function blobDataUrl(blob) {
  return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Bild konnte nicht gelesen werden.'));reader.readAsDataURL(blob);});
}
export function downloadJson(doc,name) {
  const url=URL.createObjectURL(new Blob([JSON.stringify(doc,null,2)],{type:'application/json'}));
  const anchor=document.createElement('a');anchor.href=url;anchor.download=`${(name || 'Dungeon_Layout').replace(/[^\p{L}\p{N} _-]/gu,'_')}.json`;document.body.append(anchor);anchor.click();anchor.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
}
// Der Editor arbeitet weiterhin mit eingebetteten Bildern. Nur an der
// Datenbankgrenze werden Referenzen aufgelöst bzw. erzeugt. So bleiben alle
// vorhandenen Canvas-/Druckexporte unabhängig von fremden Bild-URLs.
export class MapAssets {
  constructor(api,mapId,editorId) {this.api=api;this.mapId=mapId;this.editorId=editorId;this.byData=new Map();this.byReference=new Map();}
  async hydrate(document) {
    const copy=structuredClone(document),unique=new Map(imagesIn(copy).map(img=>[img.src,img]));
    for (const [src] of unique) {
      if (!assetPath(src)) {imageBlob(src);continue;}
      if (!this.byReference.has(src)) {
        const response=await fetch(assetUrl(src),{credentials:'omit',signal:AbortSignal.timeout(25000)});
        if (!response.ok) throw Error('Ein Kartenbild ist nicht erreichbar. Bitte erneut laden.');
        const blob=await response.blob();if (blob.size>8388608 || !['image/png','image/jpeg','image/webp'].includes(blob.type)) throw Error('Ungültige Kartenbilddatei.');
        const data=await blobDataUrl(blob);this.byReference.set(src,data);this.byData.set(data,src);
      }
    }
    for (const img of imagesIn(copy)) if (assetPath(img.src)) img.src=this.byReference.get(img.src);
    return copy;
  }
  async store(document) {
    const copy=structuredClone(document);
    for (const img of imagesIn(copy)) {
      if (assetPath(img.src)) continue;
      if (!this.byData.has(img.src)) {
        const result=await this.api.uploadMapAsset(imageBlob(img.src),this.mapId,this.editorId);
        const reference=`asset:${result.path}`;if (!assetPath(reference)) throw Error('Ungültige Antwort beim Bild-Upload.');
        this.byData.set(img.src,reference);this.byReference.set(reference,img.src);
      }
      img.src=this.byData.get(img.src);
    }
    return copy;
  }
}

// Dieser Graph dient nur UI/Tests. Beim Veröffentlichen berechnet PostgreSQL
// denselben Graph selbst, unabhängig von Daten aus dem Browser.
export function connections(document) {
  const edges=[],rooms=document.rooms || [];
  for (let i=0;i<rooms.length;i++) for (let j=i+1;j<rooms.length;j++) {
    const a=rooms[i],b=rooms[j],key=[a.id,b.id].sort((x,y)=>x-y).join(':');
    const vertical=(a.x+a.w===b.x || b.x+b.w===a.x) && Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y)>=1;
    const horizontal=(a.y+a.h===b.y || b.y+b.h===a.y) && Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x)>=1;
    if ((vertical||horizontal) && document.closedDoors?.[key]!==true) edges.push([String(a.id),String(b.id)].sort());
  }
  return edges;
}
