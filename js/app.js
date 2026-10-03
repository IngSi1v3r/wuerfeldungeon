import {audio} from './audio.js';
import {CONFIG} from './config.js';
import {SessionStore,sessionTokenFromRaw} from './session.js';
import {Api} from './api.js';
import {h,icon,avatar,feedback,pageHeading} from './dom.js';
import {cleanPreferences} from './validation.js';
import {authView} from './views/auth.js';
import {homeView} from './views/home.js';
import {profileView} from './views/profile.js';
import {settingsView} from './views/settings.js';
import {mapsView} from './views/maps.js';
import {editorView} from './views/editor.js';
import {playView} from './views/play.js';
import {newGameView} from './views/new-game.js';
import {gameView} from './views/game.js';
import {historyView} from './views/history.js';

const root=document.querySelector('#app'),nav=document.querySelector('#header-nav');
const banner=document.querySelector('#network-banner'),toastRegion=document.querySelector('#toast-region');
const sessions=new SessionStore();
let profile=null,status=null,currentView=null,route='',renderId=0,booting=true;
const toastTimers=new Map();
const inviteKey='wuerfeldungeon.invite.v1',invitePattern=/^#\/game\?id=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
let pendingInvite='';
try {const saved=sessionStorage.getItem(inviteKey);if(invitePattern.test(saved||''))pendingInvite=saved;}catch{/* Optionaler Rücksprung nach Anmeldung. */}
function rememberInvite(){if(invitePattern.test(location.hash)){pendingInvite=location.hash;try{sessionStorage.setItem(inviteKey,pendingInvite);}catch{}}}
function clearInvite(){pendingInvite='';try{sessionStorage.removeItem(inviteKey);}catch{}}
const api=new Api(sessions,{onInvalidSession:invalidateSession});
document.querySelector('#version-label').textContent=CONFIG.version;

function toast(message,{prominent=false}={}) {
  const node=h('div',{class:`toast ${prominent?'toast-prominent':''}`},icon(prominent?'sparkle':'check'),h('span',{},message));
  function remove(item){clearTimeout(toastTimers.get(item));toastTimers.delete(item);item.remove();toastRegion.classList.toggle('has-prominent',Boolean(toastRegion.querySelector('.toast-prominent')));}
  if(toastRegion.childElementCount>=3)remove(toastRegion.firstElementChild);
  toastRegion.append(node);toastRegion.classList.toggle('has-prominent',Boolean(toastRegion.querySelector('.toast-prominent')));
  toastTimers.set(node,setTimeout(()=>remove(node),prominent?3800:4500));
}
function applyPreferences(prefs) {
  document.body.classList.toggle('reduce-motion',Boolean(prefs.reduceMotion));
  audio.configure(prefs);
  const forest=document.querySelector('.forest');if(forest){const style=prefs.campStyle||'forest',src=`./assets/forest${style==='forest'?'':'-'+style}.svg`;if(forest.getAttribute('src')!==src)forest.setAttribute('src',src);}
  for(const key of ['diceStyle','cupStyle','campStyle'])document.body.dataset[key]=prefs[key]||({diceStyle:'ivory',cupStyle:'leather',campStyle:'forest'})[key];
}
function updateProfile(next) {
  profile=next;const prefs=cleanPreferences(next.preferences);applyPreferences(prefs);
  try {localStorage.setItem(CONFIG.localPreferencesKey,JSON.stringify(prefs));} catch { /* Optionaler Komfort-Cache. */ }
  renderHeader();
}
function renderHeader() {
  nav.replaceChildren(profile
    ? h('a',{class:'nav-home',href:'#/home'},icon('home'),h('span',{},'Lager')) : h('span',{class:'header-caption'},'Privater Abenteuertrupp'));
  if (profile) nav.append(h('a',{class:'nav-profile',href:'#/profile'},avatar(profile,'small'),h('span',{},profile.displayName)));
  const parent=route==='new-game'?'#/play':['profile','settings','play','editor','history'].includes(route)?'#/home':null;
  if(profile&&parent)nav.prepend(h('a',{class:'nav-back',href:parent,'aria-label':parent==='#/play'?'Zurück zur Spielauswahl':'Zurück ins Lager',title:'Zurück'},icon('back')));
}
function loading(text='Das Lager öffnet sich …') {
  return h('div',{class:'loading-panel',role:'status'},h('span',{class:'loader'}),text);
}
function clearView() {currentView?.cleanup?.();currentView=null;for(const timer of toastTimers.values())clearTimeout(timer);toastTimers.clear();toastRegion.replaceChildren();toastRegion.classList.remove('has-prominent');}
function show(view) {currentView=view;root.replaceChildren(view.element);root.setAttribute('aria-busy','false');}
function showAuth(message='') {
  rememberInvite();
  renderId++;clearView();route='login';profile=null;renderHeader();
  document.title='Anmelden · Würfeldungeon';
  history.replaceState(null,'','#/login');
  show(authView({api,status,initialMessage:message,onAuthenticated:async data=>{
    const persistent=sessions.save(data.session);updateProfile(data.profile);
    if (!persistent) toast('Angemeldet. Dieser Browser erlaubt keine dauerhafte Speicherung der Sitzung.');
    const destination=pendingInvite||'#/home';clearInvite();history.replaceState(null,'',destination);await renderRoute(true);
  }}));
}
function invalidateSession() {
  sessions.clear();
  if (!booting) showAuth('Deine Sitzung ist abgelaufen oder wurde abgemeldet. Bitte melde dich erneut an.');
}
async function logout() {
  if (!window.confirm('Auf diesem Gerät abmelden?')) return;
  clearInvite();
  let offline=false;
  try {await api.authRpc('logout_player_session');} catch {offline=true;}
  sessions.clear();showAuth(offline ? 'Auf diesem Gerät abgemeldet. Der Server konnte die Sitzung nicht widerrufen. Du kannst sie auf einem anderen angemeldeten Gerät im Profil beenden.' : 'Du wurdest auf diesem Gerät abgemeldet.');
}

async function renderRoute(force=false) {
  if (booting) return;
  if (!sessions.read() || !profile) {if (route!=='login') showAuth();return;}
  const hash=location.hash.replace(/^#\/?/,''),[path,query='']=hash.split('?');
  let next=path || 'home';
  if (!['home','profile','settings','play','new-game','game','editor','history'].includes(next)) next='home';
  const params=new URLSearchParams(query),mapId=params.get('id'),routeKey=['editor','game'].includes(next)&&mapId?`${next}?id=${mapId}`:next;
  if (routeKey===route && !force) return;
  if (!force && currentView?.prepareLeave) {
    const destination=location.hash;
    await currentView.prepareLeave();
    if(location.hash!==destination)return;
  }
  if (!force && currentView?.hasUnsavedChanges?.() && !window.confirm('Ungespeicherte Änderungen verwerfen und die Seite wechseln?')) {
    history.replaceState(null,'',`#/${route}`);return;
  }
  const id=++renderId;clearView();route=routeKey;renderHeader();
  const ctx={api,profile,status,updateProfile,getProfile:()=>profile,applyPreferences,toast,logout};
  if (next==='home') {
    root.replaceChildren(loading('Dein Lager wird geladen …'));root.setAttribute('aria-busy','true');
    try {
      const data=await api.authRpc('get_home_data');
      if (id!==renderId) return;updateProfile(data.profile);show(homeView({profile,counts:data.counts}));
    } catch (error) {
      if (id!==renderId) return;
      show({element:h('section',{},pageHeading('Verbindung','Dein Lager ist gerade nicht erreichbar.','Deine Sitzung bleibt gespeichert.'),
        feedback(error.message),h('button',{class:'button primary',onclick:()=>renderRoute(true)},'Erneut versuchen'))});
    }
  } else if (next==='profile') show(profileView(ctx));
  else if (next==='settings') show(settingsView(ctx));
  else if (next==='editor') {
    if (mapId && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(mapId)) show(editorView({...ctx,mapId}));
    else show(mapsView(ctx));
  }
  else if (next==='play') show(playView(ctx));
  else if (next==='new-game') show(newGameView(ctx));
  else if (next==='game') {
    if(mapId&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(mapId))show(gameView({...ctx,gameId:mapId}));
    else show(playView(ctx));
  }
  else if (next==='history') show(historyView(ctx));
  document.title=`${{home:'Dein Lager',profile:'Profil',settings:'Einstellungen',play:'Spielen','new-game':'Neues Spiel',game:'Spielraum',editor:'Kartenwerkstatt',history:'Chronik'}[next]} · Würfeldungeon`;
}

function connectionRecovery(error) {
  clearView();renderHeader();root.setAttribute('aria-busy','false');
  document.title='Verbindung · Würfeldungeon';
  const retry=h('button',{class:'button primary',id:'retry-connection',onclick:()=>bootstrap()},icon('arrow'),'Verbindung erneut prüfen');
  show({element:h('section',{class:'connection-view'},pageHeading('Das Tor bleibt kurz geschlossen','Wir warten auf die Verbindung.',sessions.read() ? 'Deine gespeicherte Anmeldung geht dadurch nicht verloren.' : 'Sobald Supabase eingerichtet und erreichbar ist, kannst du eintreten.'),
    h('div',{class:'panel'},feedback(error.message,'info'),
      h('p',{class:'muted'},'Die Installationsschritte stehen in SETUP.md im Projektpaket.'),
      h('div',{class:'button-row'},retry,sessions.read() ? h('button',{class:'text-button',onclick:()=>{sessions.clear();showAuth('Die lokale Anmeldung wurde entfernt.');}},'Lokale Anmeldung entfernen') : null)))});
}

async function bootstrap() {
  booting=true;renderId++;clearView();profile=null;renderHeader();root.replaceChildren(loading());root.setAttribute('aria-busy','true');
  try {
    status=await api.status();
    const saved=sessions.read();
    if (saved) {
      try {
        const data=await api.rpc('validate_player_session',{p_session_token:saved.token});
        sessions.save({...saved,expiresAt:data.expiresAt});updateProfile(data.profile);
      } catch (error) {
        if (error.code!=='SESSION_INVALID') throw error;
        booting=false;showAuth(error.message);return;
      }
    }
    booting=false;
    if (!profile) showAuth();
    else {if(pendingInvite&&location.hash==='#/login')history.replaceState(null,'',pendingInvite);clearInvite();await renderRoute(true);}
  } catch (error) {booting=false;connectionRecovery(error);}
}

function updateNetworkBanner() {
  banner.hidden=navigator.onLine;
  banner.textContent='Du bist offline. Deine Anmeldung bleibt gespeichert; Speichern und Hochladen brauchen eine Verbindung.';
}
let checkingSession=false;
async function refreshSession() {
  const token=sessions.read()?.token;
  if (!token || !profile || booting || checkingSession) return;
  checkingSession=true;
  try {
    const result=await api.rpc('validate_player_session',{p_session_token:token});
    if (sessions.read()?.token===token) {
      sessions.save({...sessions.read(),expiresAt:result.expiresAt});
      // Keine geöffneten, eventuell ungespeicherten Formulare überschreiben.
      if (!['profile','settings'].includes(route)) updateProfile(result.profile);
    }
  } catch (error) {if (error.code!=='SESSION_INVALID') {banner.hidden=false;banner.textContent=error.message;}}
  finally {checkingSession=false;}
}
window.addEventListener('hashchange',()=>{audio.effect('paper');renderRoute();});
window.addEventListener('online',()=>{updateNetworkBanner();refreshSession();});
window.addEventListener('offline',updateNetworkBanner);
document.addEventListener('visibilitychange',()=>{if (!document.hidden) refreshSession();});
window.addEventListener('storage',event=>{
  if (event.key!==CONFIG.sessionStorageKey) return;
  sessions.memory=null;
  // Eine verlängerte Ablaufzeit ist keine neue Anmeldung. Insbesondere keine
  // ungespeicherten Profil-/Einstellungsformulare in anderen Tabs verwerfen.
  const before=sessionTokenFromRaw(event.oldValue),after=sessionTokenFromRaw(event.newValue);
  if (before && before===after) return;
  if (!event.newValue) {sessions.clear();showAuth('Du wurdest in einem anderen Tab abgemeldet.');}
  else bootstrap();
});
window.addEventListener('beforeunload',event=>{
  if (currentView?.hasUnsavedChanges?.()) {event.preventDefault();event.returnValue='';}
});
try {applyPreferences(cleanPreferences(JSON.parse(localStorage.getItem(CONFIG.localPreferencesKey) || '{}')));} catch { /* Standard. */ }
updateNetworkBanner();bootstrap();
