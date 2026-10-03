// Selbst erzeugte Klänge. Keine Downloads, Fremdlizenzen oder Musikdienste.
// Audio startet erst nach einer bewussten Interaktion mit der Seite.
class DungeonAudio {
 constructor(){this.preferences={sound:true,music:false};this.context=null;this.ambient=[];this.unlocked=false;}
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
 startAmbient(){if(this.ambient.length||!this.context||!this.preferences.music||globalThis.document?.hidden)return;const c=this.context;
 try{for(const f of [65.41,98,130.81]){const o=c.createOscillator(),gain=c.createGain(),lfo=c.createOscillator(),depth=c.createGain();o.type='sine';o.frequency.value=f;gain.gain.value=.013;lfo.frequency.value=.04+f/10000;depth.gain.value=.006;lfo.connect(depth);depth.connect(gain.gain);o.connect(gain);gain.connect(c.destination);o.start();lfo.start();this.ambient.push({sources:[o,lfo],nodes:[o,lfo,gain,depth]});}
 const buffer=c.createBuffer(1,c.sampleRate*5,c.sampleRate),data=buffer.getChannelData(0);let last=0;for(let i=0;i<data.length;i++){last=(last+(Math.random()*2-1)*.03)/1.03;data[i]=last*2;}
 const wind=c.createBufferSource(),filter=c.createBiquadFilter(),g=c.createGain();wind.buffer=buffer;wind.loop=true;filter.type='lowpass';filter.frequency.value=450;g.gain.value=.08;wind.connect(filter);filter.connect(g);g.connect(c.destination);wind.start();this.ambient.push({sources:[wind],nodes:[wind,filter,g]});
 }catch{this.stopAmbient();}}
 stopAmbient(){for(const item of this.ambient){for(const source of item.sources)try{source.stop();}catch{}for(const node of item.nodes)node.disconnect();}this.ambient=[];}
}
export const audio=new DungeonAudio();
if(globalThis.document){document.addEventListener('pointerdown',()=>audio.unlock(),{once:true,capture:true});document.addEventListener('keydown',()=>audio.unlock(),{once:true,capture:true});document.addEventListener('visibilitychange',()=>document.hidden?audio.stopAmbient():audio.configure({}));}
