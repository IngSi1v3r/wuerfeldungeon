import {COSMETICS,cosmeticValue} from '../cosmetics.js';
import {cosmeticPreview} from '../cosmetic-preview.js';
import {h,icon,feedback,setFeedback,setBusy,pageHeading} from '../dom.js';
import {cleanPreferences} from '../validation.js';
import {markingPreview,MARKING_LABELS} from '../markings.js';
import {GameCommands} from '../games/commands.js';

const ANIMATIONS=['none','short','normal','long'];
const ANIMATION_LABELS=['Aus','Kurz · 2 s','Normal · 4 s','Lang · 6 s'];
const GROUPS={markStyle:'Feldmarkierungen',diceStyle:'Würfeldesigns',cupStyle:'Würfelbecher',campStyle:'Lagerhintergründe'};

export function settingsView(ctx){
 let profile=ctx.profile,disposed=false,busy=false,items=null,cosmeticItems=null;
 const commands=new GameCommands(ctx.api),message=feedback(),form=h('form',{id:'settings-form'});
 const shopEnabled=profile.cosmetics?.version===1||ctx.status?.shopSchemaVersion===1;
 const cosmeticShop=profile.cosmetics?.cosmeticVersion===1||ctx.status?.cosmeticShopVersion===1;
 const preferences=p=>{const clean=cleanPreferences(p.preferences);return {...clean,...Object.fromEntries(Object.keys(COSMETICS).map(key=>[key,cosmeticValue(clean,key)]))};};
 const original=preferences(profile),draft={markStyle:original.markStyle,diceStyle:original.diceStyle,cupStyle:original.cupStyle,campStyle:original.campStyle};
 const amount=h('strong',{id:'shop-balance'}),wallet=h('div',{class:'shop-wallet',hidden:!shopEnabled},icon('diamond'),amount,h('span',{},'Diamanten'));
 const shop=h('div',{class:'panel marking-shop',id:'marking-shop'},h('div',{class:'shop-heading'},h('h2',{},shopEnabled?'Dein Kosmetikshop':'Dein Spielstil'),wallet),shopEnabled?h('p',{class:'shop-note'},'Diamanten aus abgeschlossenen Partien · dauerhaft freischalten'):null);
 const cards={};
 for(const [key,label] of Object.entries(GROUPS)){
  cards[key]=h('div',{class:`mark-options shop-options ${key==='markStyle'?'marking-options':'cosmetic-options'}`,'data-shop-category':key});
  shop.append(h('section',{class:'shop-category'},h('h3',{},label),cards[key]));
 }
 function toggle(id,label,description,checked){
  const input=h('input',{type:'checkbox',id,name:id,checked});
  return {input,node:h('label',{class:'setting-toggle',for:id},h('span',{},h('strong',{},label),h('small',{},description)),h('span',{class:'switch'},input,h('span',{class:'switch-track'})))};
 }
 const sound=toggle('sound','Soundeffekte','Papier, Bleistift, Würfel und Spielereignisse.',original.sound);
 const music=toggle('music','Atmosphärischer Hintergrund','Leise, wechselnde Akkorde und verhallende Lichtklänge.',original.music);
 const motion=toggle('reduceMotion','Weniger Bewegung','Sanfte Hintergrundanimationen und Übergänge ausschalten.',original.reduceMotion);
 const animation=h('input',{type:'range',id:'diceAnimation',name:'diceAnimation',min:0,max:3,step:1,value:ANIMATIONS.indexOf(original.diceAnimation),'aria-label':'Dauer der Würfelanimation'});
 const animationLabel=h('output',{for:'diceAnimation',id:'dice-animation-value'});
 function paintAnimation(){const i=Number(animation.value);animationLabel.textContent=ANIMATION_LABELS[i];animation.setAttribute('aria-valuetext',ANIMATION_LABELS[i]);}
 function values(){return {...draft,diceAnimation:ANIMATIONS[Number(animation.value)],sound:sound.input.checked,music:music.input.checked,reduceMotion:motion.input.checked};}
 animation.addEventListener('input',()=>{paintAnimation();ctx.applyPreferences(values());});paintAnimation();
 for(const control of [sound,music,motion])control.input.addEventListener('change',()=>ctx.applyPreferences(values()));
 const reload=h('button',{type:'button',class:'text-button',id:'reload-settings'},'Einstellungen neu laden');
 function catalog(key){
  if(key==='markStyle')return (items||Object.entries(MARKING_LABELS).filter(([style])=>shopEnabled||['cross','pencil','waves','solid'].includes(style)).map(([style,label])=>({style,label,price:style==='cross'?0:null,owned:!shopEnabled||style==='cross'||profile.cosmetics?.unlocked?.includes(style)}))).map(item=>({...item,key,value:item.style}));
  return (cosmeticItems?.filter(item=>item.category===key)||Object.entries(COSMETICS[key].choices).map(([value,label])=>({category:key,value,label,price:value===COSMETICS[key].default?0:null,owned:!cosmeticShop||value===COSMETICS[key].default||profile.cosmetics?.cosmeticUnlocked?.[key]?.includes(value)}))).map(item=>({...item,key}));
 }
 function locks(){
  for(const [key,grid] of Object.entries(cards))for(const card of grid.children){
   const item=catalog(key).find(i=>i.value===card.dataset.value);
   card.querySelector('input').disabled=busy||!item?.owned;
   const button=card.querySelector('button');if(button)button.disabled=busy||item?.price==null||Number(profile.cosmetics?.balance||0)<item.price;
  }
 }
 function paintShop(){
  amount.textContent=String(profile.cosmetics?.balance||0);
  for(const [key,grid] of Object.entries(cards))grid.replaceChildren(...catalog(key).map(item=>{
   const radio=h('input',{type:'radio',name:key,value:item.value,id:key==='markStyle'?`mark-${item.value}`:`${key}-${item.value}`,checked:draft[key]===item.value,disabled:busy||!item.owned});
   radio.addEventListener('change',()=>{if(radio.checked){draft[key]=item.value;ctx.applyPreferences(values());}});
   const preview=key==='markStyle'?markingPreview(item.value):cosmeticPreview(key,item.value);
   const label=h('label',{class:`mark-select ${key==='markStyle'?'':'cosmetic-select'}`,for:radio.id},radio,preview,h('span',{class:'mark-name'},item.label));
   const paid=key==='markStyle'?shopEnabled:cosmeticShop;
   return h('div',{class:`mark-option ${key==='markStyle'?'':'cosmetic-option'} ${item.owned?'owned':'locked'}`,'data-value':item.value,...(key==='markStyle'?{'data-style':item.value}:{'data-category':key})},label,paid?(item.owned?h('span',{class:'mark-owned'},item.price===0?'Kostenlos':'Freigeschaltet'):h('div',{class:'mark-purchase'},h('span',{class:'mark-price'},icon('diamond'),item.price??'…'),h('button',{type:'button',class:'button secondary buy-marking',...(key==='markStyle'?{'data-buy-marking':item.value}:{'data-buy-cosmetic':`${key}:${item.value}`}),onclick:()=>purchase(item)},'Freischalten'))):null);
  }));
  locks();
 }
 function refreshProfile(next){
  const previous=preferences(profile),updated=preferences(next);
  for(const key of Object.keys(draft))if(draft[key]===previous[key])draft[key]=updated[key];
  for(const [key,control] of [['sound',sound],['music',music],['reduceMotion',motion]])if(control.input.checked===previous[key])control.input.checked=updated[key];
  if(ANIMATIONS[Number(animation.value)]===previous.diceAnimation)animation.value=ANIMATIONS.indexOf(updated.diceAnimation);
  profile=next;ctx.updateProfile(next);ctx.applyPreferences(values());paintAnimation();
 }
 function adopt(next){
  refreshProfile(next);const prefs=preferences(next);for(const key of Object.keys(draft))draft[key]=prefs[key];
  sound.input.checked=prefs.sound;music.input.checked=prefs.music;motion.input.checked=prefs.reduceMotion;animation.value=ANIMATIONS.indexOf(prefs.diceAnimation);
  paintAnimation();ctx.applyPreferences(prefs);paintShop();
 }
 async function readShop(reset=false){
  const result=await ctx.api.authRpc('get_marking_shop');if(disposed)return;
  items=result.items;cosmeticItems=result.cosmeticItems||null;
  if(reset)adopt(result.profile);else{refreshProfile(result.profile);paintShop();}
 }
 async function run(action){
  if(busy||disposed)return;busy=true;setBusy(form,true);setFeedback(message,'');
  try{await action();}catch(error){if(!disposed)setFeedback(message,error.message);}
  finally{busy=false;if(!disposed){setBusy(form,false);locks();}}
 }
 async function purchase(item){
  if(busy||disposed||item.owned||item.price==null)return;
  if(!window.confirm(`„${item.label}“ für ${item.price} Diamanten freischalten?`))return;
  await run(async()=>{
   try{
    const result=await commands.run(item.key==='markStyle'?'buy_marking':'buy_cosmetic',item.key==='markStyle'?{p_style:item.value}:{p_category:item.key,p_value:item.value});if(disposed)return;
    items=result.items;cosmeticItems=result.cosmeticItems||null;refreshProfile(result.profile);draft[item.key]=item.value;ctx.applyPreferences(values());paintShop();
    setFeedback(message,'Freigeschaltet. Mit „Einstellungen speichern“ verwendest du deine Auswahl.','success');ctx.toast(`${item.label} freigeschaltet.`);
   }catch(error){if(error.code==='SHOP_INSUFFICIENT_DIAMONDS')await readShop().catch(()=>{});throw error;}
  });
 }
 form.append(shop,h('div',{class:'panel settings-panel'},h('div',{class:'animation-heading'},h('label',{for:animation.id},'Würfelanimation'),animationLabel),h('div',{class:'animation-slider'},animation,h('div',{class:'animation-ticks','aria-hidden':'true'},...['Aus','Kurz','Normal','Lang'].map(label=>h('span',{},label)))),h('h2',{},'Atmosphäre & Bewegung'),motion.node,h('details',{id:'audio-preferences',class:'audio-preferences',open:true},h('summary',{},'Audio-Vorlieben'),sound.node,music.node)),message,h('div',{class:'button-row'},h('button',{class:'button primary',type:'submit',id:'save-settings'},icon('check'),'Einstellungen speichern'),reload));
 form.addEventListener('submit',event=>{event.preventDefault();run(async()=>{const result=await ctx.api.authRpc('update_player_preferences',{p_preferences:values(),p_expected_revision:profile.revision});if(!disposed){adopt(result.profile);setFeedback(message,'Deine Einstellungen wurden gespeichert.','success');ctx.toast('Einstellungen gespeichert.');}});});
 reload.addEventListener('click',()=>run(async()=>{if(shopEnabled)await readShop(true);else{const result=await ctx.api.authRpc('get_player_profile');if(!disposed)adopt(result.profile);}if(!disposed)setFeedback(message,'Aktuelle Einstellungen geladen.','success');}));
 paintShop();if(shopEnabled)run(()=>readShop());
 return {element:h('section',{},pageHeading('Einstellungen','Dein Spiel. Dein Stil.'),form),cleanup:()=>{disposed=true;ctx.applyPreferences(cleanPreferences(ctx.getProfile().preferences));},hasUnsavedChanges:()=>{const saved=preferences(profile);return Object.entries(values()).some(([key,value])=>value!==saved[key]);}};
}
