import {CONFIG} from '../config.js';

// Supabase Realtime protocol 1.0.0. Nur öffentliche Broadcast-Wecksignale;
// Daten und Berechtigungen kommen immer aus unseren sitzungsgeprüften RPCs.
// Keine Postgres-Changes-Abos, kein Spieler-Token in WebSocket-Nachrichten.
export class RealtimeSignals {
  constructor(topics,{onSignal=()=>{},onState=()=>{},config=CONFIG,socketFactory=url=>new WebSocket(url),heartbeatMs=25000,joinTimeoutMs=12000,reconnectBaseMs=1000}={}) {
    this.topics=[...new Set(topics)].map(t=>`realtime:${t}`);this.onSignal=onSignal;this.onState=onState;this.config=config;this.socketFactory=socketFactory;
    this.heartbeatMs=heartbeatMs;this.joinTimeoutMs=joinTimeoutMs;this.reconnectBaseMs=reconnectBaseMs;this.ref=0;this.attempt=0;this.stopped=true;this.socket=null;
  }
  start() {if(!this.stopped)return;this.stopped=false;this.connect();}
  connect() {
    if(this.stopped||this.socket)return;
    this.onState('connecting');
    try {
      const url=new URL(this.config.supabaseUrl);url.protocol=url.protocol==='http:'?'ws:':'wss:';url.pathname='/realtime/v1/websocket';url.search='';url.searchParams.set('apikey',this.config.publishableKey);url.searchParams.set('vsn','1.0.0');
      const socket=this.socketFactory(url.href);this.socket=socket;this.joined=new Set();this.joinRefs=new Map();this.awaitingHeartbeat=null;
      this.joinTimer=setTimeout(()=>this.fail(socket),this.joinTimeoutMs);
      socket.onopen=()=>{
        if(this.socket!==socket||this.stopped)return;
        for(const topic of this.topics){const ref=String(++this.ref);this.joinRefs.set(ref,topic);socket.send(JSON.stringify({topic,event:'phx_join',payload:{config:{broadcast:{ack:false,self:false},presence:{enabled:false},postgres_changes:[],private:false}},ref,join_ref:ref}));}
      };
      socket.onmessage=event=>{
        if(this.socket!==socket||this.stopped)return;let message;try{message=JSON.parse(event.data);}catch{return;}
        if(message.event==='phx_reply') {
          if(message.ref===this.awaitingHeartbeat){this.awaitingHeartbeat=null;return;}
          const topic=this.joinRefs.get(message.ref);
          if(topic){this.joinRefs.delete(message.ref);if(message.payload?.status!=='ok'){this.fail(socket);return;}this.joined.add(topic);
            if(this.joined.size===this.topics.length){clearTimeout(this.joinTimer);this.attempt=0;this.onState('connected');this.onSignal();this.heartTimer=setInterval(()=>{
              if(this.awaitingHeartbeat){this.fail(socket);return;}this.awaitingHeartbeat=String(++this.ref);
              if(socket.readyState===1)socket.send(JSON.stringify({topic:'phoenix',event:'heartbeat',payload:{},ref:this.awaitingHeartbeat}));else this.fail(socket);
            },this.heartbeatMs);}
          }
        } else if(message.event==='broadcast' && this.joined.has(message.topic) && message.payload?.event==='changed')this.onSignal();
        else if(['phx_error','phx_close'].includes(message.event) || (message.event==='system'&&message.payload?.status==='error'))this.fail(socket);
      };
      socket.onerror=()=>this.fail(socket);socket.onclose=()=>this.fail(socket);
    } catch {this.fail(this.socket);}
  }
  fail(socket) {
    if(socket && this.socket!==socket)return;
    this.clearSocket();if(this.stopped)return;this.onState('fallback');
    clearTimeout(this.reconnectTimer);const delay=Math.min(30000,this.reconnectBaseMs*2**Math.min(this.attempt++,5));
    this.reconnectTimer=setTimeout(()=>this.connect(),delay);
  }
  clearSocket() {
    clearInterval(this.heartTimer);clearTimeout(this.joinTimer);
    const socket=this.socket;this.socket=null;
    if(socket){socket.onopen=socket.onclose=socket.onerror=socket.onmessage=null;try{socket.close();}catch{/* Bereits geschlossen. */}}
  }
  stop() {this.stopped=true;clearTimeout(this.reconnectTimer);this.clearSocket();}
}

export function watchGameChanges(topics,{refresh,onState=()=>{},pollMs=12000,allowRealtime=true}={}) {
  let closed=false,running=false,again=false,debounce;
  async function request() {
    if(closed||document.hidden||navigator.onLine===false)return;
    if(running){again=true;return;}running=true;
    try {await refresh();} catch {/* View zeigt Fehler und behält den letzten Stand. */}
    finally {running=false;if(again&&!closed){again=false;schedule();}}
  }
  function schedule(){clearTimeout(debounce);debounce=setTimeout(request,120);}
  const realtime=new RealtimeSignals(topics,{onSignal:schedule,onState});
  function resume() {
    if(document.hidden||navigator.onLine===false){realtime.stop();if(navigator.onLine===false)onState('offline');return;}
    if(allowRealtime)realtime.start();else onState('fallback');schedule();
  }
  const timer=setInterval(request,pollMs);
  document.addEventListener('visibilitychange',resume);window.addEventListener('online',resume);window.addEventListener('offline',resume);window.addEventListener('pageshow',resume);
  resume();
  return {refresh:request,cleanup:()=>{closed=true;clearInterval(timer);clearTimeout(debounce);realtime.stop();document.removeEventListener('visibilitychange',resume);window.removeEventListener('online',resume);window.removeEventListener('offline',resume);window.removeEventListener('pageshow',resume);}};
}
