import {CONFIG} from './config.js';

const ERRORS={
  SHOP_STYLE_INVALID:'Diese Markierung ist nicht verfügbar.',
  SHOP_STYLE_LOCKED:'Diese Markierung musst du zuerst im Shop freischalten.',
  SHOP_INSUFFICIENT_DIAMONDS:'Dein Guthaben reicht dafür noch nicht. Der Shop wird aktualisiert.',
  SHOP_REQUEST_INVALID:'Diese Kaufanfrage gehört zu einer anderen Markierung. Bitte erneut versuchen.',
  GAME_POWERUP_PENDING:'Bitte zuerst das Powerup aus deiner geöffneten Truhe wählen.',
  GAME_POWERUP_UNAVAILABLE:'Dieses Powerup wurde bereits gewählt oder ist auf dieser Karte nicht freigegeben.',
  GAME_CHEST_INVALID:'Für diese Truhe ist keine Auswahl mehr offen. Der Spielstand wird neu geladen.',
  GAME_TORCH_EMPTY:'Du hast keine Fackelverwendung mehr.',
  GAME_TORCH_PATH:'Wähle zuerst einen angrenzenden, noch freien Raum und dann dessen Nachbarfeld. Ein Gegner kann kein Zwischenraum sein.',
  GAME_AXE_UNAVAILABLE:'Ein Doppelhit ist nur bei einem Gegner mit einer übrigen Axtverwendung möglich.',
  GAME_POWERUP_COMBINATION:'Fackel und Doppelhit werden in getrennten Zügen verwendet. Rot lässt sich mit beiden kombinieren.',
  PLAY_NOT_INSTALLED:'Zum Würfeln bitte 008_phase4.sql aus PHASE_4_SETUP.md installieren.',
  GAME_PAUSED:'Das Spiel ist gerade für alle pausiert.',
  GAME_ROLLER_ONLY:'In dieser Runde würfelt ein anderer Spieler.',
  GAME_ROUND_CHANGED:'Die nächste Runde hat bereits begonnen. Der aktuelle Stand wird neu geladen.',
  GAME_ALREADY_ROLLED:'Für diese Runde wurde bereits gewürfelt.',
  GAME_NOT_ROLLED:'Bitte zuerst auf den Wurf dieser Runde warten.',
  GAME_TURN_DONE:'Dein Zug für diese Runde ist bereits gespeichert.',
  GAME_STATE_CHANGED:'Dein Spielstand wurde auf einem anderen Gerät verändert. Bitte erneut wählen.',
  GAME_CELL_INVALID:'Dieses Feld gehört nicht zum Spielplan.',
  GAME_CELL_REACHED:'Dieses Feld hast du bereits erreicht.',
  GAME_CELL_UNREACHABLE:'Dieses Feld grenzt nicht über einen offenen Durchgang an deinen erreichten Weg an.',
  GAME_NUMBER_MISMATCH:'Die gewürfelten Kombinationen passen zu keiner freigeschalteten Zahl dieses Feldes.',
  GAME_RED_CONFIRMATION:'Dieser Zug benötigt eine Verwendung des roten Würfels.',
  GAME_MOVE_AVAILABLE:'Es ist noch ein Zug ohne Sonderwürfel möglich. Bitte ein passendes Feld wählen.',
  GAME_WAIT_TOO_SHORT:'Der Host kann einen ausstehenden Zug oder Wurf erst nach einer Minute weitergeben oder den Spieler entfernen.',
  GAME_NO_OTHER_ROLLER:'Es gibt keinen anderen aktiven Spieler, an den der Wurf weitergegeben werden kann.',
  GAMES_NOT_INSTALLED:'Für Spiele und Warteräume bitte 006_phase3.sql aus PHASE_3_SETUP.md installieren.',
  GAME_NOT_FOUND:'Dieses Spiel ist nicht verfügbar.',
  GAME_INPUT_INVALID:'Bitte Spielname und Eingaben prüfen.',
  GAME_SETTINGS_INVALID:'Bitte 2–16 Plätze, offene oder verdeckte Karten und eine Tipps-Einstellung wählen.',
  GAME_PASSWORD_INVALID:'Das Spielpasswort darf höchstens 72 UTF-8-Bytes lang sein.',
  GAME_PASSWORD_WRONG:'Das Spielpasswort stimmt nicht.',
  GAME_MAP_UNAVAILABLE:'Diese Karte ist nicht mehr für neue Spiele freigegeben. Bitte eine andere wählen.',
  GAME_JOIN_REQUIRED:'Bitte diesem Warteraum zuerst beitreten.',
  GAME_NOT_MEMBER:'Du bist kein aktiver Teilnehmer dieses Spiels.',
  GAME_REMOVED:'Der Host hat dich aus diesem Warteraum entfernt.',
  GAME_FULL:'Dieser Warteraum ist inzwischen voll.',
  GAME_ALREADY_STARTED:'Der Warteraum ist bereits geschlossen. Es können keine neuen Spieler mehr beitreten.',
  GAME_HOST_ONLY:'Diese Aktion kann nur der aktuelle Host ausführen.',
  GAME_CHANGED:'Im Spiel hat sich gerade etwas geändert. Der aktuelle Stand wird neu geladen; bitte danach erneut wählen.',
  GAME_CLOSED:'Dieses Spiel ist bereits abgeschlossen oder abgebrochen.',
  GAME_ACTION_INVALID:'Diese Aktion ist im aktuellen Spielstand nicht möglich.',
  GAME_REQUEST_INVALID:'Diese Anfrage wurde bereits für eine andere Aktion verwendet. Bitte den Spielstand neu laden.',
  EDITOR_NOT_INSTALLED:'Die Kartenwerkstatt braucht das Datenbank-Update 014_editor_upgrade.sql aus der Update-Anleitung.',
  MAP_NOT_FOUND:'Diese Karte wurde inzwischen gelöscht.',
  MAP_NAME_INVALID:'Der Kartenname muss 1–80 Zeichen lang sein.',
  MAP_NAME_TAKEN:'Dieser Kartenname ist schon vergeben. Bitte einen anderen wählen.',
  MAP_DOCUMENT_INVALID:'Die Kartendaten sind nicht gültig. Bitte Größen, Bildreferenzen und Spielregeln prüfen.',
  MAP_IMAGE_INVALID:'Bitte eine gültige PNG-, JPG- oder WebP-Datei verwenden.',
  MAP_IMAGE_TOO_LARGE:'Dieses Bild ist zu groß. Bitte ein kleineres Bild verwenden.',
  MAP_UPLOAD_NOT_CONFIGURED:'Bitte die neue Function map-asset-upload aus PHASE_2_SETUP.md installieren.',
  MAP_UPLOAD_UNAVAILABLE:'Der Kartenbild-Upload ist nicht erreichbar. Bitte map-asset-upload und „Verify JWT“ prüfen.',
  MAP_UPLOAD_FAILED:'Das Kartenbild konnte nicht gespeichert werden. Bitte map-assets und die Upload-Function prüfen.',
  MAP_CHANGED:'Die Karte wurde inzwischen verändert. Dein lokaler Stand bleibt erhalten. Bitte neu verbinden oder als Kopie sichern.',
  MAP_LOCK_LOST:'Die Bearbeitungssperre ist abgelaufen oder wurde übernommen. Dein lokaler Stand bleibt erhalten.',
  MAP_BUSY:'Die Karte wird gerade bearbeitet. Bitte nach Freigabe erneut versuchen.',
  MAP_READ_ONLY:'Veröffentlichte oder archivierte Karten können nur als Kopie bearbeitet werden.',
  MAP_INCOMPLETE:'Die Karte braucht noch Änderungen, bevor sie veröffentlicht werden kann.',
  MAP_WARNINGS:'Bitte die Hinweise vor dem Veröffentlichen bestätigen.',
  MAP_REQUEST_INVALID:'Diese Speicheranfrage ist nicht mehr gültig. Bitte neu verbinden.',
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
  constructor(code='SERVER_ERROR',details=null) { super(ERRORS[code] || ERRORS.SERVER_ERROR); this.name='AppError'; this.code=code; this.details=details; }
}

export class Api {
  constructor(sessionStore,{config=CONFIG,fetcher=globalThis.fetch,onInvalidSession=()=>{}}={}) {
    this.sessionStore=sessionStore; this.config=config; this.fetcher=fetcher; this.onInvalidSession=onInvalidSession;
  }
  async request(path,{body,headers={},method='POST',timeout=this.config.requestTimeoutMs,keepalive=false}={}) {
    const controller=new AbortController();
    const timer=setTimeout(()=>controller.abort(),timeout);
    try {
      // Nicht als Objektmethode aufrufen: Window.fetch erwartet in manchen
      // Browsern einen Window-/neutralen Receiver, nicht unsere Api-Instanz.
      const fetcher=this.fetcher;
      const response=await fetcher(`${this.config.supabaseUrl}${path}`,{
        method,headers:{apikey:this.config.publishableKey,...headers},body,signal:controller.signal,
        cache:'no-store',credentials:'omit',keepalive,
      });
      let data;
      try { data=await response.json(); } catch { throw new AppError('SERVER_ERROR'); }
      if (!response.ok || data?.ok===false) {
        let code=data?.error;
        if (data?.message==='SESSION_INVALID') code='SESSION_INVALID';
        if (!code && path.startsWith('/rest/') && (response.status===404 || data?.code==='PGRST202')) code='APP_NOT_INSTALLED';
        if (!code && path.startsWith('/functions/') && response.status===404) code=path.includes('map-asset-upload') ? 'MAP_UPLOAD_NOT_CONFIGURED' : 'UPLOAD_NOT_CONFIGURED';
        if (!code && [401,403].includes(response.status)) code=path.startsWith('/functions/') ? 'UPLOAD_UNAVAILABLE' : 'CONFIG_INVALID';
        throw new AppError(code || 'SERVER_ERROR',data);
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
  uploadMapAsset(blob,mapId,editorId) {
    const token=this.sessionStore.read()?.token;
    if (!token) return Promise.reject(new AppError('SESSION_INVALID'));
    const body=new FormData();body.append('file',blob,'map-image');body.append('mapId',mapId);body.append('editorId',editorId);
    return this.request('/functions/v1/map-asset-upload',{body,headers:{'x-session-token':token},timeout:60000});
  }
  releaseMapLock(mapId,editorId) {
    const token=this.sessionStore.read()?.token;
    if(!token)return Promise.resolve();
    return this.request('/rest/v1/rpc/release_map_lock',{keepalive:true,headers:{'Content-Type':'application/json'},body:JSON.stringify({p_session_token:token,p_map_id:mapId,p_editor_id:editorId})});
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
