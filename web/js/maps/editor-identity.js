// Eine stabile ID überlebt einen Reload. Web Locks verhindern gleichzeitig,
// dass ein duplizierter Tab mit kopiertem sessionStorage dieselbe ID benutzt.
// Die eigentliche Kartensperre bleibt immer in PostgreSQL.
export async function editorIdentity(playerId,mapId) {
  const key=`wuerfeldungeon.editor.${playerId}:${mapId}`;
  let previous=null,finish,held=false;
  try {previous=sessionStorage.getItem(key);} catch { /* Speicher gesperrt. */ }
  const releasePromise=new Promise(resolve=>{finish=resolve;});
  const available=Boolean(navigator.locks?.request);
  async function claim(id) {
    return new Promise(resolve=>{
      navigator.locks.request(`wuerfeldungeon-editor-${id}`,{ifAvailable:true},async lock=>{
        if(!lock){resolve(false);return;}
        held=true;resolve(true);await releasePromise;
      }).catch(()=>resolve(false));
    });
  }
  let id=previous&&/^[a-f0-9-]{36}$/.test(previous)&&available&&await claim(previous)?previous:crypto.randomUUID();
  if(available&&!held)await claim(id);
  let persistent=false;
  try {sessionStorage.setItem(key,id);persistent=available&&held;} catch { /* Zufällige Identität, Lease bleibt Rückfall. */ }
  return {id,persistent,release:()=>{finish();try{if(sessionStorage.getItem(key)===id)sessionStorage.removeItem(key);}catch{}}};
}
