import {CONFIG} from './config.js';

export function sessionTokenFromRaw(value) {
  try {
    const token=JSON.parse(value || 'null')?.token;
    return typeof token==='string' && /^[a-f0-9]{64}$/.test(token) ? token : null;
  } catch {return null;}
}

export class SessionStore {
  constructor(storage) {
    this.memory=null;
    try {this.storage=storage===undefined ? globalThis.localStorage : storage;}
    catch {this.storage=null;}
  }
  read() {
    try {
      const parsed=JSON.parse(this.storage.getItem(CONFIG.sessionStorageKey) || 'null');
      if (parsed && /^[a-f0-9]{64}$/.test(parsed.token)) { this.memory=parsed; return parsed; }
    } catch { /* Privater Modus / deaktivierter Speicher: Sitzung im RAM. */ }
    return this.memory;
  }
  save(session) {
    if (!session || !/^[a-f0-9]{64}$/.test(session.token)) throw new Error('Ungültige Sitzung');
    this.memory={token:session.token,id:session.id ?? null,expiresAt:session.expiresAt ?? null};
    try { this.storage.setItem(CONFIG.sessionStorageKey,JSON.stringify(this.memory)); return true; }
    catch { return false; }
  }
  clear() {
    this.memory=null;
    try { this.storage.removeItem(CONFIG.sessionStorageKey); } catch { /* RAM wurde bereits geleert. */ }
  }
}

export function deviceLabel(agent = globalThis.navigator?.userAgent || '') {
  const platform=/iPhone|iPad/.test(agent) ? 'iPhone / iPad' : /Android/.test(agent) ? 'Android' : /Macintosh/.test(agent) ? 'Mac' : /Windows/.test(agent) ? 'Windows' : 'Computer';
  const browser=/Edg\//.test(agent) ? 'Edge' : /Firefox\//.test(agent) ? 'Firefox' : /Chrome\//.test(agent) ? 'Chrome' : /Safari\//.test(agent) ? 'Safari' : 'Browser';
  return `${platform} · ${browser}`;
}
