// Ein eigener Datensatz je Spieler und Karte, auch für große eingebettete
// Bilder. Kein gemeinsames Standalone-Backup, das andere Karten überschreibt.
export class MapRecovery {
  constructor(playerId,mapId) {this.key=`${playerId}:${mapId}`;this.queue=Promise.resolve();}
  async transaction(mode,action) {
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('wuerfeldungeon-map-recovery',1);r.onupgradeneeded=()=>r.result.createObjectStore('maps');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});
    try {return await new Promise((resolve,reject)=>{const tx=db.transaction('maps',mode),req=action(tx.objectStore('maps'));tx.oncomplete=()=>resolve(req.result);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);});}
    finally {db.close();}
  }
  read() {return this.transaction('readonly',store=>store.get(this.key));}
  write(value) {const copy=structuredClone(value);this.queue=this.queue.catch(()=>{}).then(()=>this.transaction('readwrite',store=>store.put(copy,this.key)));return this.queue;}
  clear() {this.queue=this.queue.catch(()=>{}).then(()=>this.transaction('readwrite',store=>store.delete(this.key)));return this.queue;}
}
