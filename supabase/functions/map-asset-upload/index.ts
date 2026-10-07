// Einzeldatei für die Dashboard-Function "map-asset-upload". Verify JWT: AUS.
// Eigener Sitzungsschlüssel UND eigene Editor-Sperre werden serverseitig geprüft.
const MAX_BYTES=8388608;
type EnvReader=(name:string)=>string|undefined;
type Dependencies={env?:EnvReader;fetcher?:typeof fetch;uuid?:()=>string};
class RpcError extends Error {}
function serverKey(env:EnvReader) {
  try {const keys=JSON.parse(env('SUPABASE_SECRET_KEYS') || '{}');if(typeof keys.default==='string')return keys.default;const key=Object.values(keys).find(v=>typeof v==='string');if(typeof key==='string')return key;} catch { /* Legacy. */ }
  return env('SUPABASE_SERVICE_ROLE_KEY') || env('SUPABASE_SECRET_KEY');
}
export function validImage(bytes:Uint8Array,mime:string) {
  if(mime==='image/png')return bytes.length>=24 && String.fromCharCode(...bytes.slice(0,8))==='\x89PNG\r\n\x1a\n' && String.fromCharCode(...bytes.slice(12,16))==='IHDR';
  if(mime==='image/jpeg')return bytes.length>=4 && bytes[0]===255 && bytes[1]===216 && bytes[2]===255;
  return mime==='image/webp' && bytes.length>=16 && String.fromCharCode(...bytes.slice(0,4))==='RIFF' && String.fromCharCode(...bytes.slice(8,12))==='WEBP' && ['VP8 ','VP8L','VP8X'].includes(String.fromCharCode(...bytes.slice(12,16)));
}
export function createHandler({env=name=>Deno.env.get(name),fetcher=fetch,uuid=()=>crypto.randomUUID()}:Dependencies={}) {
  return async(request:Request)=>{
    const origin=request.headers.get('origin') || '',allowed=(env('ALLOWED_ORIGINS') || '').split(',').map(v=>v.trim()).filter(Boolean);
    const cors={'Access-Control-Allow-Origin':allowed.length?(allowed.includes(origin)?origin:'null'):'*','Access-Control-Allow-Headers':'content-type, apikey, x-session-token','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Cache-Control':'no-store'};
    const reply=(status:number,error:string|null,extra:Record<string,unknown>={})=>Response.json(error?{ok:false,error,...extra}:{ok:true,...extra},{status,headers:cors});
    if(allowed.length&&origin&&!allowed.includes(origin))return reply(403,'ORIGIN_DENIED');
    if(request.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
    if(request.method!=='POST')return reply(405,'METHOD_NOT_ALLOWED');
    const token=request.headers.get('x-session-token');
    if(!token || !/^[a-f0-9]{64}$/.test(token))return reply(401,'SESSION_INVALID');
    if(Number(request.headers.get('content-length'))>MAX_BYTES+100000)return reply(413,'MAP_IMAGE_TOO_LARGE');
    const base=(env('SUPABASE_URL') || '').replace(/\/$/,''),key=serverKey(env);
    if(!base||!key)return reply(503,'MAP_UPLOAD_NOT_CONFIGURED');
    const headers:Record<string,string>={apikey:key};if(!key.startsWith('sb_secret_'))headers.Authorization=`Bearer ${key}`;
    async function rpc(name:string,body:Record<string,unknown>) {
      const response=await fetcher(`${base}/rest/v1/rpc/${name}`,{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
      const data=await response.json();if(!response.ok)throw new RpcError(data.message==='SESSION_INVALID'?'SESSION_INVALID':'DATABASE_ERROR');return data;
    }
    async function remove(path:string) {try {await fetcher(`${base}/storage/v1/object/map-assets`,{method:'DELETE',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({prefixes:[path]}),signal:AbortSignal.timeout(5000)});} catch { /* Erreichbare Bilder nicht durch unklaren Commit löschen. */ }}
    try {
      const session=await rpc('validate_player_session',{p_session_token:token});if(!session.ok)return reply(401,'SESSION_INVALID');
      let form;try {form=await request.formData();} catch {return reply(400,'MAP_IMAGE_INVALID');}
      const mapId=form.get('mapId'),editorId=form.get('editorId'),file=form.get('file');
      if(typeof mapId!=='string'||typeof editorId!=='string'||![mapId,editorId].every(v=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(v)))return reply(400,'MAP_IMAGE_INVALID');
      const auth=await rpc('app_authorize_map_asset',{p_session_token:token,p_map_id:mapId,p_editor_id:editorId});if(!auth.ok)return reply(409,auth.error);
      if(!(file instanceof Blob)||!file.size||!['image/png','image/jpeg','image/webp'].includes(file.type))return reply(400,'MAP_IMAGE_INVALID');
      if(file.size>MAX_BYTES)return reply(413,'MAP_IMAGE_TOO_LARGE');
      const bytes=new Uint8Array(await file.arrayBuffer());if(!validImage(bytes,file.type))return reply(400,'MAP_IMAGE_INVALID');
      const extension=file.type==='image/png'?'png':file.type==='image/jpeg'?'jpg':'webp',path=`${mapId}/${uuid()}.${extension}`;
      const response=await fetcher(`${base}/storage/v1/object/map-assets/${path}`,{method:'POST',headers:{...headers,'Content-Type':file.type,'x-upsert':'false'},body:bytes,signal:AbortSignal.timeout(40000)});
      if(!response.ok)return reply(502,'MAP_UPLOAD_FAILED');
      let result;
      try {result=await rpc('app_finish_map_asset',{p_session_token:token,p_map_id:mapId,p_editor_id:editorId,p_path:path,p_mime:file.type,p_bytes:bytes.length});}
      catch(error) {if(error instanceof RpcError)await remove(path);throw error;}
      if(!result.ok){await remove(path);return reply(409,result.error || 'MAP_UPLOAD_FAILED');}
      return reply(200,null,{path:result.path});
    } catch(error) {return error instanceof Error&&error.message==='SESSION_INVALID'?reply(401,'SESSION_INVALID'):reply(503,'MAP_UPLOAD_UNAVAILABLE');}
  };
}
if(typeof Deno!=='undefined')Deno.serve(createHandler());
