import {h,icon,feedback,setFeedback,setBusy,pageHeading} from '../dom.js';
import {cleanPreferences} from '../validation.js';
import {markingPreview,MARKING_LABELS} from '../markings.js';
import {GameCommands} from '../games/commands.js';

export function settingsView(ctx){
 let profile=ctx.profile,disposed=false,busy=false,items=null;
 const original=cleanPreferences(profile.preferences),message=feedback(),commands=new GameCommands(ctx.api);
 let draftStyle=original.markStyle;
 const shopEnabled=profile.cosmetics?.version===1||ctx.status?.shopSchemaVersion===1;
 const form=h('form',{id:'settings-form'}),cards=h('div',{class:'mark-options shop-options'}),amount=h('strong',{id:'shop-balance'}),wallet=h('div',{class:'shop-wallet',hidden:!shopEnabled},icon('diamond'),amount,h('span',{},'Diamanten'));
 const heading=h('div',{class:'shop-heading'},h('h2',{},shopEnabled?'Markierungs-Shop':'Dein Markierungsstil'),wallet);
 function toggle(id,label,description,checked){const input=h('input',{type:'checkbox',id,name:id,checked});return {input,node:h('label',{class:'setting-toggle',for:id},h('span',{},h('strong',{},label),h('small',{},description)),h('span',{class:'switch'},input,h('span',{class:'switch-track'})))};}
 const sound=toggle('sound','Soundeffekte','Vorgemerkt für die spätere Audio-Erweiterung.',original.sound),music=toggle('music','Hintergrundmusik','Vorgemerkt für die spätere Audio-Erweiterung.',original.music),motion=toggle('reduceMotion','Weniger Bewegung','Sanfte Hintergrundanimationen und Übergänge ausschalten.',original.reduceMotion);
 motion.input.addEventListener('change',()=>ctx.applyPreferences({reduceMotion:motion.input.checked}));
 const reload=h('button',{type:'button',class:'text-button',id:'reload-settings'},'Einstellungen neu laden');
 function values(){return {markStyle:draftStyle,sound:sound.input.checked,music:music.input.checked,reduceMotion:motion.input.checked};}
 function catalog(){return items||Object.entries(MARKING_LABELS).filter(([s])=>shopEnabled||['cross','pencil','waves','solid'].includes(s)).map(([style,label])=>({style,label,price:style==='cross'?0:null,owned:!shopEnabled||style==='cross'||profile.cosmetics?.unlocked?.includes(style)}));}
 function locks(){for(const card of cards.children){const item=catalog().find(i=>i.style===card.dataset.style);card.querySelector('input').disabled=busy||!item?.owned;const button=card.querySelector('button');if(button)button.disabled=busy||item.price==null||Number(profile.cosmetics?.balance||0)<item.price;}}
 function paintShop(){
  amount.textContent=String(profile.cosmetics?.balance||0);
  cards.replaceChildren(...catalog().map(item=>{
   const radio=h('input',{type:'radio',name:'markStyle',value:item.style,id:`mark-${item.style}`,checked:item.style===draftStyle,disabled:busy||!item.owned});
   radio.addEventListener('change',()=>{if(radio.checked)draftStyle=item.style;});
   const select=h('label',{class:'mark-select',for:radio.id},radio,markingPreview(item.style),h('span',{class:'mark-name'},item.label));
   return h('div',{class:`mark-option ${item.owned?'owned':'locked'}`,'data-style':item.style},select,shopEnabled?(item.owned?h('span',{class:'mark-owned'},item.style==='cross'?'Kostenlos':'Freigeschaltet'):h('div',{class:'mark-purchase'},h('span',{class:'mark-price'},icon('diamond'),item.price??'…'),h('button',{type:'button',class:'button secondary buy-marking','data-buy-marking':item.style,onclick:()=>purchase(item)},'Freischalten'))):null);
  }));locks();
 }
 function refreshProfile(next){
  const previous=cleanPreferences(profile.preferences),updated=cleanPreferences(next.preferences);
  if(draftStyle===previous.markStyle)draftStyle=updated.markStyle;
  for(const [key,control] of [['sound',sound],['music',music],['reduceMotion',motion]])if(control.input.checked===previous[key])control.input.checked=updated[key];
  profile=next;ctx.updateProfile(next);ctx.applyPreferences({reduceMotion:motion.input.checked});
 }
 function adopt(next){refreshProfile(next);const prefs=cleanPreferences(next.preferences);draftStyle=prefs.markStyle;sound.input.checked=prefs.sound;music.input.checked=prefs.music;motion.input.checked=prefs.reduceMotion;ctx.applyPreferences(prefs);paintShop();}
 async function readShop(reset=false){const result=await ctx.api.authRpc('get_marking_shop');if(disposed)return;items=result.items;if(reset)adopt(result.profile);else {refreshProfile(result.profile);paintShop();}}
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
    const result=await commands.run('buy_marking',{p_style:item.style});if(disposed)return;
    items=result.items;refreshProfile(result.profile);draftStyle=item.style;paintShop();
    setFeedback(message,'Freigeschaltet. Mit „Einstellungen speichern“ verwendest du deine Auswahl.','success');ctx.toast(`${item.label} freigeschaltet.`);
   }catch(error){
    // Bei gleichzeitigem Kauf auf einem anderen Gerät aktuelle Guthaben holen,
    // dabei ungespeicherte Audio-/Bewegungseinstellungen behalten.
    if(error.code==='SHOP_INSUFFICIENT_DIAMONDS')await readShop().catch(()=>{});
    throw error;
   }
  });
 }
 form.append(h('div',{class:'panel marking-shop',id:'marking-shop'},heading,shopEnabled?h('p',{class:'shop-note'},'Diamanten aus abgeschlossenen Partien · dauerhaft freischalten'):null,cards),
  h('div',{class:'panel settings-panel'},h('h2',{},'Atmosphäre & Bewegung'),motion.node,h('details',{id:'audio-preferences',class:'audio-preferences'},h('summary',{},'Audio-Vorlieben'),sound.node,music.node)),
  message,h('div',{class:'button-row'},h('button',{class:'button primary',type:'submit',id:'save-settings'},icon('check'),'Einstellungen speichern'),reload));
 form.addEventListener('submit',event=>{event.preventDefault();run(async()=>{const result=await ctx.api.authRpc('update_player_preferences',{p_preferences:values(),p_expected_revision:profile.revision});if(!disposed){adopt(result.profile);setFeedback(message,'Deine Einstellungen wurden gespeichert.','success');ctx.toast('Einstellungen gespeichert.');}});});
 reload.addEventListener('click',()=>run(async()=>{if(shopEnabled)await readShop(true);else {const result=await ctx.api.authRpc('get_player_profile');if(!disposed)adopt(result.profile);}if(!disposed)setFeedback(message,'Aktuelle Einstellungen geladen.','success');}));
 paintShop();if(shopEnabled)run(()=>readShop());
 return {element:h('section',{},pageHeading('Einstellungen','Dein Spiel. Dein Stil.'),form),cleanup:()=>{disposed=true;ctx.applyPreferences(cleanPreferences(ctx.getProfile().preferences));},hasUnsavedChanges:()=>JSON.stringify(values())!==JSON.stringify(cleanPreferences(profile.preferences))};
}
