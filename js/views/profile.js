import {h,icon,avatar,feedback,setFeedback,setBusy,pageHeading} from '../dom.js';
import {validateDisplayName} from '../validation.js';
import {prepareAvatar} from '../avatar.js';

const number=new Intl.NumberFormat('de-DE',{maximumFractionDigits:1});
const date=new Intl.DateTimeFormat('de-DE',{dateStyle:'medium'});

export function profileView(ctx) {
  let profile=ctx.profile,disposed=false,busy=false;
  const message=feedback();
  const input=h('input',{id:'profile-display-name',name:'displayName',value:profile.displayName,maxlength:40,required:true,autocomplete:'nickname'});
  const portrait=h('div',{class:'profile-portrait'},avatar(profile,'large'));
  const uploadInput=h('input',{id:'avatar-file',type:'file',accept:'image/png,image/jpeg,image/webp',class:'visually-hidden'});
  const upload=h('button',{type:'button',class:'button secondary',id:'upload-avatar'},icon('upload'),'Bild hochladen');
  const remove=h('button',{type:'button',class:'text-button danger',id:'remove-avatar',hidden:!profile.avatarPath},'Bild entfernen');
  const reload=h('button',{type:'button',class:'text-button',id:'reload-profile'},'Profil neu laden');
  const form=h('form',{id:'profile-form',novalidate:true},
    h('div',{class:'avatar-editor'},portrait,h('div',{},h('h2',{},'Dein Gesicht im Abenteuer'),
      h('p',{class:'muted'},'PNG, JPEG oder WebP · maximal 8 MB. Das Bild wird mittig quadratisch zugeschnitten und als 256 × 256 Pixel gespeichert.'),
      h('div',{class:'button-row'},upload,remove),uploadInput)),
    h('div',{class:'profile-fields'},h('div',{class:'form-field'},h('label',{for:input.id},'Anzeigename'),input),
      h('div',{class:'form-field'},h('label',{},'Spielername zum Anmelden'),h('div',{class:'readonly-value'},profile.username),h('small',{class:'field-hint'},'Bleibt unverändert, auch wenn du deinen Anzeigenamen änderst.'))),
    message,h('div',{class:'button-row'},h('button',{type:'submit',class:'button primary',id:'save-profile'},icon('check'),'Profil speichern'),reload));

  function adopt(next,{updateInput=false}={}) {
    profile=next;ctx.updateProfile(next);refreshStatistics();portrait.replaceChildren(avatar(profile,'large'));remove.hidden=!profile.avatarPath;
    if (updateInput) input.value=profile.displayName;
  }
  async function run(action) {
    if (busy) return;
    busy=true;setFeedback(message,'');setBusy(form,true);
    try { await action(); } catch (error) { if (!disposed) setFeedback(message,error.message); }
    finally { busy=false;if (!disposed) setBusy(form,false); }
  }
  form.addEventListener('submit',event=>{
    event.preventDefault();const displayName=input.value.trim();const error=validateDisplayName(displayName);
    if (error) {setFeedback(message,error);return;}
    run(async()=>{
      const data=await ctx.api.authRpc('update_player_profile',{p_display_name:displayName,p_expected_revision:profile.revision});
      if (!disposed) {adopt(data.profile,{updateInput:true});setFeedback(message,'Dein Profil wurde gespeichert.','success');ctx.toast('Profil gespeichert.');}
    });
  });
  reload.addEventListener('click',()=>run(async()=>{
    const data=await ctx.api.authRpc('get_player_profile');
    if (!disposed) {adopt(data.profile,{updateInput:true});setFeedback(message,'Aktueller Profilstand geladen.','success');}
  }));
  upload.addEventListener('click',()=>uploadInput.click());
  uploadInput.addEventListener('change',()=>{
    const file=uploadInput.files?.[0];if (!file) return;
    run(async()=>{
      setFeedback(message,'Dein Profilbild wird vorbereitet …','info');
      const blob=await prepareAvatar(file);
      setFeedback(message,'Profilbild wird hochgeladen …','info');
      const data=await ctx.api.uploadAvatar(blob);
      if (!disposed) {adopt(data.profile);setFeedback(message,'Dein Profilbild wurde gespeichert.','success');ctx.toast('Profilbild gespeichert.');}
    }).finally(()=>{uploadInput.value='';});
  });
  remove.addEventListener('click',()=>run(async()=>{
    const data=await ctx.api.removeAvatar(profile.revision);
    if (!disposed) {adopt(data.profile);setFeedback(message,'Dein Profilbild wurde entfernt.','success');}
  }));

  const stats=profile.stats || {};
  const statLabels=[['gamesPlayed','Gespielte Spiele'],['totalPoints','Gesamtpunkte'],['averagePoints','Ø Punkte / Spiel'],['wins','Siege'],['monstersDefeated','Besiegte Monster']];
  const statistics=h('div',{class:'stats-grid'},...statLabels.map(([key,label])=>h('div',{class:'stat-card'},h('strong',{},number.format(stats[key] ?? 0)),h('span',{},label))));
  const walletTotal=h('strong',{id:'profile-shop-balance'}),walletHistory=h('p');
  const wallet=h('div',{class:'panel diamond-wallet',hidden:!profile.cosmetics},h('div',{},h('h2',{},'Deine Diamantentasche'),h('div',{class:'wallet-total'},icon('diamond'),walletTotal,h('span',{},'Diamanten')),walletHistory),h('a',{class:'button secondary',href:'#/settings'},'Zum Kosmetikshop'));
  function refreshStatistics(){for(const [i,[key]] of statLabels.entries())statistics.children[i].querySelector('strong').textContent=number.format(profile.stats?.[key]??0);wallet.hidden=!profile.cosmetics;walletTotal.textContent=number.format(profile.cosmetics?.balance??0);walletHistory.textContent=`${number.format(profile.cosmetics?.earned??0)} erspielt · ${number.format(profile.cosmetics?.spent??0)} für Kosmetik ausgegeben`;}
  refreshStatistics();
  ctx.api.authRpc('get_player_profile').then(data=>{if(!disposed)adopt(data.profile);}).catch(()=>{});
  const sessions=h('div',{id:'session-list',class:'sessions-list'},h('p',{class:'muted'},'Aktive Geräte werden geladen …'));
  const sessionFeedback=feedback();
  async function loadSessions() {
    try {
      const result=await ctx.api.authRpc('list_player_sessions');
      if (disposed) return;
      sessions.replaceChildren(...result.sessions.map(session=>{
        const revoke=h('button',{type:'button',class:'text-button danger','aria-label':`${session.deviceLabel} abmelden`},'Abmelden');
        revoke.addEventListener('click',async()=>{
          if (!window.confirm(`„${session.deviceLabel}“ wirklich abmelden?`)) return;
          revoke.disabled=true;
          try {await ctx.api.authRpc('revoke_player_session',{p_session_id:session.id});if (!disposed) await loadSessions();}
          catch (error) {if (!disposed) {setFeedback(sessionFeedback,error.message);revoke.disabled=false;}}
        });
        return h('div',{class:'session-row'},h('div',{},h('strong',{},session.deviceLabel),
          h('span',{class:'muted'},`Angemeldet am ${date.format(new Date(session.createdAt))}`)),
          session.current ? h('span',{class:'badge'},'Dieses Gerät') : revoke);
      }));
    } catch (error) { if (!disposed) {sessions.replaceChildren();setFeedback(sessionFeedback,error.message);} }
  }
  loadSessions();
  const element=h('section',{},pageHeading('Dein Profil','So kennt dich dein Abenteuertrupp.'),
    h('div',{class:'panel'},form),
    h('div',{class:'section-label'},h('h2',{},'Deine Abenteuer in Zahlen'),h('span',{class:'muted'},'Abgeschlossene Spiele')),statistics,wallet,
    h('div',{class:'panel session-panel'},h('h2',{},'Angemeldete Geräte'),h('p',{class:'muted'},'Du bleibst angemeldet, bis du dich abmeldest oder die Sitzung 180 Tage lang nicht mehr verwendest.'),sessions,sessionFeedback,
      h('div',{class:'logout-row'},
        h('button',{type:'button',class:'button danger-button',id:'logout-button',onclick:()=>ctx.logout()},icon('logout'),'Auf diesem Gerät abmelden'))));
  return {element,cleanup:()=>{disposed=true;},hasUnsavedChanges:()=>input.value.trim()!==profile.displayName};
}
