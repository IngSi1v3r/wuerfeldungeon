import {h,icon,feedback,setFeedback,setBusy,pageHeading} from '../dom.js';
import {cleanPreferences} from '../validation.js';

const STYLES=[['pencil','Bleistift'],['cross','Großes X'],['solid','Ausgemalt'],['waves','Wellenlinien']];

export function settingsView(ctx) {
  let profile=ctx.profile,disposed=false;
  const original=cleanPreferences(profile.preferences),message=feedback();
  const form=h('form',{id:'settings-form'});
  const previews=STYLES.map(([value,label])=>{
    const radio=h('input',{type:'radio',name:'markStyle',value,id:`mark-${value}`,checked:value===original.markStyle});
    return h('label',{class:'mark-option',for:radio.id},radio,h('span',{class:`mark-preview ${value}`,'aria-hidden':'true'},h('span',{class:'preview-number'},'7'),h('span',{class:'mark-ink'})),h('span',{},label));
  });
  function toggle(id,label,description,checked) {
    const input=h('input',{type:'checkbox',id,name:id,checked});
    return {input,node:h('label',{class:'setting-toggle',for:id},h('span',{},h('strong',{},label),h('small',{},description)),h('span',{class:'switch'},input,h('span',{class:'switch-track'})))};
  }
  const sound=toggle('sound','Soundeffekte','Vorgemerkt für die spätere Audio-Erweiterung.',original.sound);
  const music=toggle('music','Hintergrundmusik','Vorgemerkt für die spätere Audio-Erweiterung.',original.music);
  const motion=toggle('reduceMotion','Weniger Bewegung','Sanfte Hintergrundanimationen und Übergänge ausschalten.',original.reduceMotion);
  motion.input.addEventListener('change',()=>ctx.applyPreferences({reduceMotion:motion.input.checked}));
  const reload=h('button',{type:'button',class:'text-button',id:'reload-settings'},'Einstellungen neu laden');
  function values() {return {markStyle:form.querySelector('input[name="markStyle"]:checked').value,sound:sound.input.checked,music:music.input.checked,reduceMotion:motion.input.checked};}
  form.append(h('div',{class:'panel'},h('h2',{},'Dein Markierungsstil'),
    h('div',{class:'mark-options'},previews)),
    h('div',{class:'panel settings-panel'},h('h2',{},'Atmosphäre & Bewegung'),motion.node,h('details',{id:'audio-preferences',class:'audio-preferences'},h('summary',{},'Audio-Vorlieben'),sound.node,music.node)),
    message,h('div',{class:'button-row'},h('button',{class:'button primary',type:'submit',id:'save-settings'},icon('check'),'Einstellungen speichern'),reload));
  function adopt(next) {
    profile=next;ctx.updateProfile(next);const prefs=cleanPreferences(next.preferences);
    for (const radio of form.querySelectorAll('input[name="markStyle"]')) radio.checked=radio.value===prefs.markStyle;
    sound.input.checked=prefs.sound;music.input.checked=prefs.music;motion.input.checked=prefs.reduceMotion;
    ctx.applyPreferences(prefs);
  }
  async function run(action) {
    if (form.getAttribute('aria-busy')==='true') return;
    setBusy(form,true);setFeedback(message,'');
    try {await action();} catch (error) {if (!disposed) setFeedback(message,error.message);}
    finally {if (!disposed) setBusy(form,false);}
  }
  form.addEventListener('submit',event=>{
    event.preventDefault();const prefs=values();
    run(async()=>{
      const result=await ctx.api.authRpc('update_player_preferences',{p_preferences:prefs,p_expected_revision:profile.revision});
      if (!disposed) {adopt(result.profile);setFeedback(message,'Deine Einstellungen wurden gespeichert.','success');ctx.toast('Einstellungen gespeichert.');}
    });
  });
  reload.addEventListener('click',()=>run(async()=>{
    const result=await ctx.api.authRpc('get_player_profile');
    if (!disposed) {adopt(result.profile);setFeedback(message,'Aktuelle Einstellungen geladen.','success');}
  }));
  return {element:h('section',{},pageHeading('Einstellungen','Dein Spiel. Dein Stil.'),form),
    cleanup:()=>{disposed=true;ctx.applyPreferences(cleanPreferences(ctx.getProfile().preferences));},
    hasUnsavedChanges:()=>JSON.stringify(values())!==JSON.stringify(cleanPreferences(profile.preferences))};
}
