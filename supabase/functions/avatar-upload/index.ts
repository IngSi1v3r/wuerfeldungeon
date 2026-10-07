// Einzeldatei: im Supabase Dashboard als Function "avatar-upload" einsetzen.
// "Verify JWT" ausschalten: Wir prüfen stattdessen unseren Sitzungsschlüssel.
// Keine zusätzlichen npm-Pakete oder Spieler-Supabase-Accounts nötig.

const MAX_FILE_BYTES = 524288;
const MAX_REQUEST_BYTES = 600000;

type EnvReader = (name: string) => string | undefined;
type Dependencies = {env?: EnvReader; fetcher?: typeof fetch; uuid?: () => string};
class RpcError extends Error { confirmedFailure = true; }

function serverKey(env: EnvReader) {
  const named = env('SUPABASE_SECRET_KEYS');
  if (named) {
    try {
      const keys = JSON.parse(named);
      const values = Object.values(keys);
      if (typeof keys.default === 'string') return keys.default;
      const key = values.find(value => typeof value === 'string');
      if (key) return key;
    } catch { /* Ältere Projekte haben stattdessen den einzelnen Schlüssel. */ }
  }
  return env('SUPABASE_SERVICE_ROLE_KEY') || env('SUPABASE_SECRET_KEY');
}

export function isWebP(bytes: Uint8Array) {
  return bytes.length >= 16 &&
    String.fromCharCode(...bytes.slice(0,4)) === 'RIFF' &&
    String.fromCharCode(...bytes.slice(8,12)) === 'WEBP' &&
    ['VP8 ', 'VP8L', 'VP8X'].includes(String.fromCharCode(...bytes.slice(12,16)));
}

export function createHandler({
  env = name => Deno.env.get(name),
  fetcher = fetch,
  uuid = () => crypto.randomUUID(),
}: Dependencies = {}) {
  return async (request: Request) => {
    const origin = request.headers.get('origin') || '';
    const allowed = (env('ALLOWED_ORIGINS') || '').split(',').map(value => value.trim()).filter(Boolean);
    const cors = {
      'Access-Control-Allow-Origin': allowed.length ? (allowed.includes(origin) ? origin : 'null') : '*',
      'Access-Control-Allow-Headers': 'content-type, apikey, x-session-token',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Vary': 'Origin',
      'Cache-Control': 'no-store',
    };
    const reply = (status: number, error: string | null, extra: Record<string, unknown> = {}) => new Response(
      JSON.stringify(error ? {ok:false,error,...extra} : {ok:true,...extra}),
      {status,headers:{...cors,'Content-Type':'application/json; charset=utf-8'}},
    );
    if (allowed.length && origin && !allowed.includes(origin)) return reply(403,'ORIGIN_DENIED');
    if (request.method === 'OPTIONS') return new Response(null,{status:204,headers:cors});
    if (request.method !== 'POST') return reply(405,'METHOD_NOT_ALLOWED');
    const token = request.headers.get('x-session-token');
    if (!token || !/^[a-f0-9]{64}$/.test(token)) return reply(401,'SESSION_INVALID');
    if (Number(request.headers.get('content-length')) > MAX_REQUEST_BYTES) return reply(413,'AVATAR_TOO_LARGE');

    const base = (env('SUPABASE_URL') || '').replace(/\/$/,'');
    const key = serverKey(env);
    if (!base || !key) return reply(503,'UPLOAD_NOT_CONFIGURED');
    const serviceHeaders: Record<string, string> = {apikey:key};
    // Legacy service_role ist ein JWT. Neue sb_secret_-Schlüssel sind es NICHT.
    if (!key.startsWith('sb_secret_')) serviceHeaders.Authorization = `Bearer ${key}`;
    async function rpc(name: string, body: Record<string, unknown>) {
      const response = await fetcher(`${base}/rest/v1/rpc/${name}`,{
        method:'POST',headers:{...serviceHeaders,'Content-Type':'application/json'},
        body:JSON.stringify(body),signal:AbortSignal.timeout(15000),
      });
      const result = await response.json();
      if (!response.ok) {
        throw new RpcError(result.message === 'SESSION_INVALID' ? 'SESSION_INVALID' : 'DATABASE_ERROR');
      }
      return result;
    }
    async function removeObject(path: string) {
      try {
        await fetcher(`${base}/storage/v1/object/avatars`,{
          method:'DELETE',headers:{...serviceHeaders,'Content-Type':'application/json'},
          body:JSON.stringify({prefixes:[path]}),signal:AbortSignal.timeout(5000),
        });
      } catch { /* Ein ungenutztes Bild ist besser als ein verlorenes Profil. */ }
    }
    try {
      const session = await rpc('validate_player_session',{p_session_token:token});
      if (!session.ok || !session.profile?.id) return reply(401,'SESSION_INVALID');
      if (request.headers.get('content-type')?.startsWith('application/json')) {
        let body;
        try {body = await request.json();} catch {return reply(400,'AVATAR_INVALID');}
        if (body.action !== 'remove' || !Number.isSafeInteger(body.revision) || body.revision < 1) return reply(400,'AVATAR_INVALID');
        const result = await rpc('remove_player_avatar',{p_session_token:token,p_expected_revision:body.revision});
        if (!result.ok) return reply(409,result.error || 'DATABASE_ERROR');
        if (result.oldPath) await removeObject(result.oldPath);
        return reply(200,null,{profile:result.profile});
      }
      let form;
      try { form = await request.formData(); } catch { return reply(400,'AVATAR_INVALID'); }
      const file = form.get('file');
      if (!(file instanceof Blob) || file.type !== 'image/webp' || !file.size) return reply(400,'AVATAR_INVALID');
      if (file.size > MAX_FILE_BYTES) return reply(413,'AVATAR_TOO_LARGE');
      const bytes = new Uint8Array(await file.arrayBuffer());
      if (!isWebP(bytes)) return reply(400,'AVATAR_INVALID');
      const path = `${session.profile.id}/${uuid()}.webp`;
      const upload = await fetcher(`${base}/storage/v1/object/avatars/${path}`,{
        method:'POST',headers:{...serviceHeaders,'Content-Type':'image/webp','x-upsert':'false'},
        body:bytes,signal:AbortSignal.timeout(15000),
      });
      if (!upload.ok) return reply(502,'UPLOAD_FAILED');
      let result;
      try {
        result = await rpc('app_finish_avatar_upload',{p_session_token:token,p_path:path,p_bytes:bytes.length});
      } catch (error) {
        // Nur bei bestätigtem Rollback löschen. Bei Verbindungsabbruch könnte
        // der Commit schon erfolgt sein; sonst würden wir ein aktives Bild löschen.
        if (error instanceof RpcError && error.confirmedFailure) await removeObject(path);
        throw error;
      }
      if (result.oldPath && result.oldPath !== path) await removeObject(result.oldPath);
      return reply(200,null,{profile:result.profile});
    } catch (error) {
      // Keine Tokens, Kennwörter oder serverseitigen Schlüssel in Logs/Antworten.
      return error instanceof Error && error.message === 'SESSION_INVALID'
        ? reply(401,'SESSION_INVALID') : reply(503,'UPLOAD_UNAVAILABLE');
    }
  };
}

if (typeof Deno !== 'undefined') Deno.serve(createHandler());
