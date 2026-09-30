import {CONFIG} from './config.js';

const ERRORS={
  NETWORK:'Die Verbindung ist gerade nicht erreichbar. Deine Anmeldung bleibt gespeichert. Bitte erneut versuchen.',
  TIMEOUT:'Die Antwort dauert zu lange. Bitte erneut versuchen. Falls du gerade gespeichert hast, lade den Stand vorher neu.',
  APP_NOT_INSTALLED:'Die Datenbank ist noch nicht eingerichtet. Bitte zuerst 001_phase1.sql und 002_registration_code.sql aus der Setup-Anleitung ausführen.',
  SCHEMA_MISMATCH:'App und Datenbank passen nicht zusammen. Bitte die aktuelle Datenbankmigration installieren.',
  CONFIG_INVALID:'Die öffentlichen Supabase-Projektwerte wurden nicht akzeptiert. Bitte URL und Publishable Key prüfen.',
  SESSION_INVALID:'Deine Sitzung ist abgelaufen oder wurde abgemeldet. Bitte melde dich erneut an.',
  LOGIN_INVALID:'Spielername oder Passwort stimmen nicht.',
  ACCESS_CODE_INVALID:'Der Registrierungscode stimmt nicht.',
  REGISTRATION_CLOSED:'Neue Spieler können gerade nicht angelegt werden. Bitte den Gastgeber fragen.',
  USERNAME_INVALID:'Der Spielername muss 3–32 Zeichen aus a–z, Zahlen, Punkt, Bindestrich oder Unterstrich enthalten.',
  USERNAME_TAKEN:'Dieser Spielername ist schon vergeben. Bitte einen anderen wählen.',
  DISPLAY_NAME_INVALID:'Der Anzeigename muss 1–40 Zeichen lang sein.',
  PASSWORD_INVALID:'Das Passwort braucht mindestens 6 Zeichen und höchstens 72 UTF-8-Bytes.',
  RATE_LIMIT:'Zu viele Anmeldeversuche. Bitte etwa 10 Minuten warten.',
  PROFILE_CHANGED:'Dein Profil wurde auf einem anderen Gerät verändert. Bitte neu laden und erneut speichern.',
  PREFERENCES_INVALID:'Diese Einstellungen sind nicht gültig.',
  AVATAR_INVALID:'Bitte eine PNG-, JPEG- oder WebP-Bilddatei auswählen.',
  AVATAR_TOO_LARGE:'Das Bild ist zu groß. Bitte eine kleinere Bilddatei auswählen (maximal 8 MB).',
  UPLOAD_NOT_CONFIGURED:'Der Bild-Upload ist noch nicht eingerichtet. Bitte die Function avatar-upload aus der Anleitung installieren.',
  UPLOAD_UNAVAILABLE:'Der Bild-Upload ist nicht erreichbar. Bitte Function und Einstellung „Verify JWT“ prüfen. Bei einem Verbindungsabbruch zunächst das Profil neu laden.',
  UPLOAD_FAILED:'Das Bild konnte nicht gespeichert werden. Bitte den avatars-Bucket und die Upload-Function prüfen.',
  SERVER_ERROR:'Der Server konnte die Anfrage nicht abschließen. Bitte erneut versuchen.',
};

export class AppError extends Error {
  constructor(code='SERVER_ERROR') { super(ERRORS[code] || ERRORS.SERVER_ERROR); this.name='AppError'; this.code=code; }
}

export class Api {
  constructor(sessionStore,{config=CONFIG,fetcher=globalThis.fetch,onInvalidSession=()=>{}}={}) {
    this.sessionStore=sessionStore; this.config=config; this.fetcher=fetcher; this.onInvalidSession=onInvalidSession;
  }
  async request(path,{body,headers={},method='POST',timeout=this.config.requestTimeoutMs}={}) {
    const controller=new AbortController();
    const timer=setTimeout(()=>controller.abort(),timeout);
    try {
      // Nicht als Objektmethode aufrufen: Window.fetch erwartet in manchen
      // Browsern einen Window-/neutralen Receiver, nicht unsere Api-Instanz.
      const fetcher=this.fetcher;
      const response=await fetcher(`${this.config.supabaseUrl}${path}`,{
        method,headers:{apikey:this.config.publishableKey,...headers},body,signal:controller.signal,
        cache:'no-store',credentials:'omit',
      });
      let data;
      try { data=await response.json(); } catch { throw new AppError('SERVER_ERROR'); }
      if (!response.ok || data?.ok===false) {
        let code=data?.error;
        if (data?.message==='SESSION_INVALID') code='SESSION_INVALID';
        if (!code && path.startsWith('/rest/') && (response.status===404 || data?.code==='PGRST202')) code='APP_NOT_INSTALLED';
        if (!code && path.startsWith('/functions/') && response.status===404) code='UPLOAD_NOT_CONFIGURED';
        if (!code && [401,403].includes(response.status)) code=path.startsWith('/functions/') ? 'UPLOAD_UNAVAILABLE' : 'CONFIG_INVALID';
        throw new AppError(code || 'SERVER_ERROR');
      }
      return data;
    } catch (error) {
      if (error instanceof AppError) {
        if (error.code==='SESSION_INVALID') this.onInvalidSession();
        throw error;
      }
      throw new AppError(controller.signal.aborted ? 'TIMEOUT' : 'NETWORK');
    } finally { clearTimeout(timer); }
  }
  rpc(name,params={}) {
    return this.request(`/rest/v1/rpc/${name}`,{headers:{'Content-Type':'application/json'},body:JSON.stringify(params)});
  }
  authRpc(name,params={}) {
    const token=this.sessionStore.read()?.token;
    if (!token) return Promise.reject(new AppError('SESSION_INVALID'));
    return this.rpc(name,{...params,p_session_token:token});
  }
  async status() {
    const status=await this.rpc('app_status');
    if (status?.schemaVersion!==this.config.schemaVersion) throw new AppError('SCHEMA_MISMATCH');
    return status;
  }
  uploadAvatar(blob) {
    const token=this.sessionStore.read()?.token;
    if (!token) return Promise.reject(new AppError('SESSION_INVALID'));
    const body=new FormData(); body.append('file',blob,'avatar.webp');
    return this.request('/functions/v1/avatar-upload',{
      body,headers:{'x-session-token':token},timeout:40000,
    });
  }
  removeAvatar(revision) {
    const token=this.sessionStore.read()?.token;
    if (!token) return Promise.reject(new AppError('SESSION_INVALID'));
    return this.request('/functions/v1/avatar-upload',{
      headers:{'x-session-token':token,'Content-Type':'application/json'},
      body:JSON.stringify({action:'remove',revision}),timeout:40000,
    });
  }
}
