// Selbst erzeugte Klänge. Keine Downloads, Fremdlizenzen oder Musikdienste.
// Audio startet erst nach einer bewussten Interaktion mit der Seite.
export class DungeonAudio {
 constructor(){this.preferences={sound:true,music:false};this.context=null;this.ambient=[];this.ambientTimer=null;this.ambientStep=0;this.unlocked=false;}
 configure(prefs){this.preferences={...this.preferences,...prefs};if(!this.preferences.music||globalThis.document?.hidden)this.stopAmbient();else if(this.unlocked)this.startAmbient();}
 unlock(){this.unlocked=true;try{const C=globalThis.AudioContext||globalThis.webkitAudioContext;if(!C)return;this.context??=new C();this.context.resume().catch(()=>{});if(this.preferences.music)this.startAmbient();}catch{/* Browser ohne Audio. */}}
 tone(frequency,duration=.2,volume=.07,delay=0,type='sine',end=frequency){const c=this.context;if(!c)return;const t=c.currentTime+delay,o=c.createOscillator(),g=c.createGain();o.type=type;o.frequency.setValueAtTime(frequency,t);o.frequency.exponentialRampToValueAtTime(Math.max(20,end),t+duration);g.gain.setValueAtTime(.0001,t);g.gain.exponentialRampToValueAtTime(volume,t+.025);g.gain.exponentialRampToValueAtTime(.0001,t+duration);o.connect(g);g.connect(c.destination);o.start(t);o.stop(t+duration+.02);o.onended=()=>{o.disconnect();g.disconnect();};}
 noise(duration=.15,volume=.06,frequency=1600,delay=0){const c=this.context;if(!c)return;const n=Math.ceil(c.sampleRate*duration),buffer=c.createBuffer(1,n,c.sampleRate),data=buffer.getChannelData(0);for(let i=0;i<n;i++)data[i]=(Math.random()*2-1)*Math.sin(Math.PI*i/n);const source=c.createBufferSource(),filter=c.createBiquadFilter(),gain=c.createGain();source.buffer=buffer;filter.type='bandpass';filter.frequency.value=frequency;filter.Q.value=.6;gain.gain.value=volume;source.connect(filter);filter.connect(gain);gain.connect(c.destination);source.start(c.currentTime+delay);source.onended=()=>{source.disconnect();filter.disconnect();gain.disconnect();};}
 effect(kind){if(!this.unlocked||!this.preferences.sound||globalThis.document?.hidden)return;try{
 if(kind==='paper'){this.noise(.22,.035,1800);return;}
 if(kind==='pencil'){this.noise(.2,.07,3200);this.noise(.13,.045,2400,.11);return;}
 if(kind==='dice'){for(let i=0;i<8;i++){this.noise(.045,.09,450+i*160,i*.075);this.tone(180+i*13,.07,.035,i*.075,'triangle',80);}return;}
 if(kind==='attack'){this.noise(.2,.1,700);this.tone(200,.25,.07,0,'triangle',65);return;}
 if(kind==='loss'){this.tone(220,.6,.05,0,'sine',110);return;}
 if(kind==='horn'){for(const [i,f] of [110,165,220].entries())this.tone(f,1.8,.035,i*.08,'triangle',f);return;}
 const notes=kind==='finish'?[261.63,329.63,392,523.25]:[329.63,392,523.25];notes.forEach((f,i)=>this.tone(f,.7,.035,i*.16));
 }catch{/* Einzelner Effekt darf Bedienung nicht stören. */}}
 startAmbient(){
  if(this.ambient.length||!this.context||!this.preferences.music||globalThis.document?.hidden)return;
  const c=this.context;
  try{
   const master=c.createGain(),reverb=c.createConvolver(),wet=c.createGain();
   master.gain.setValueAtTime(0,c.currentTime);master.gain.linearRampToValueAtTime(.7,c.currentTime+2);
   master.connect(c.destination);wet.gain.value=.24;reverb.connect(wet);wet.connect(master);
   // Die zufälligen Werte dienen nur als Hallimpuls, nicht als Rauschschleife.
   const length=Math.floor(c.sampleRate*3.2),impulse=c.createBuffer(2,length,c.sampleRate);
   for(let channel=0;channel<2;channel++){const data=impulse.getChannelData(channel);for(let i=0;i<length;i++)data[i]=(Math.random()*2-1)*Math.pow(1-i/length,3.5)*.32;}
   reverb.buffer=impulse;
   const session={sources:[],nodes:[master,reverb,wet],master,reverb,voices:new Set()};this.ambient=[session];
   const voice=(frequency,at,duration,volume,type='sine')=>{
    if(this.ambient[0]!==session)return;
    const o=c.createOscillator(),gain=c.createGain(),filter=c.createBiquadFilter();
    o.type=type;o.frequency.setValueAtTime(frequency,at);filter.type='lowpass';filter.frequency.value=type==='triangle'?1300:2400;
    gain.gain.setValueAtTime(.0001,at);gain.gain.exponentialRampToValueAtTime(volume,at+(type==='triangle'?2.8:.1));gain.gain.exponentialRampToValueAtTime(.0001,at+duration);
    o.connect(filter);filter.connect(gain);gain.connect(master);gain.connect(reverb);
    const entry={o,nodes:[o,filter,gain]};session.voices.add(entry);
    o.onended=()=>{session.voices.delete(entry);for(const node of entry.nodes)try{node.disconnect();}catch{}};
    o.start(at);o.stop(at+duration+.05);
   };
   const phrases=()=>{
    if(this.ambient[0]!==session||!this.preferences.music||globalThis.document?.hidden)return;
    const now=c.currentTime+.1;
    const chords=[[146.83,220,329.63],[174.61,261.63,392],[130.81,196,293.66],[164.81,246.94,392]];
    const index=this.ambientStep++%chords.length;
    chords[index].forEach((f,i)=>voice(f,now+i*.45,13+i*.5,.014,'triangle'));
    const notes=[293.66,349.23,440,523.25,587.33,698.46];
    // Unterschiedliche Pausen, Töne und Klangfarben statt einer kurzen Schleife.
    for(let i=0;i<3;i++)voice(notes[(index*2+i+Math.floor(Math.random()*3))%notes.length],now+2.5+i*4.4+Math.random()*1.4,4.5+Math.random()*2,.018);
    this.ambientTimer=setTimeout(phrases,15000+Math.random()*2500);
   };
   phrases();
  }catch{this.stopAmbient();}
 }
 stopAmbient(){
  clearTimeout(this.ambientTimer);this.ambientTimer=null;
  const sessions=this.ambient;this.ambient=[];
  for(const session of sessions){
   const c=this.context,now=c?.currentTime||0;
   try{session.master.gain.cancelScheduledValues(now);session.master.gain.setTargetAtTime(0,now,.045);}catch{}
   for(const voice of session.voices||[])try{voice.o.stop(now+.16);}catch{}
   // Die kurze Ausblendung verhindert Klicks beim Umschalten.
   setTimeout(()=>{for(const voice of session.voices||[])for(const node of voice.nodes)try{node.disconnect();}catch{}for(const node of session.nodes)try{node.disconnect();}catch{}},180);
  }
 }

}
export const audio=new DungeonAudio();
if(globalThis.document){document.addEventListener('pointerdown',()=>audio.unlock(),{once:true,capture:true});document.addEventListener('keydown',()=>audio.unlock(),{once:true,capture:true});document.addEventListener('visibilitychange',()=>document.hidden?audio.stopAmbient():audio.configure({}));}
