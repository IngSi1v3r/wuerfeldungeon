import {h,icon,feedback,setFeedback,setBusy} from '../dom.js';
import {deviceLabel} from '../session.js';
import {normalizeUsername,validateUsername,validateDisplayName,validatePassword} from '../validation.js';

function field(label,id,{type='text',autocomplete='off',hint='',...attrs}={}) {
  const input=h('input',{id,name:id,type,autocomplete,required:true,...attrs});
  const wrapper=h('div',{class:'form-field'},h('label',{for:id},label),input,
    hint ? h('small',{id:`${id}-hint`,class:'field-hint'},hint) : null);
  if (hint) input.setAttribute('aria-describedby',`${id}-hint`);
  return {input,wrapper};
}

export function authView({api,status,onAuthenticated,initialMessage=''}) {
  let mode='login',disposed=false;
  const codeRequired=status?.registrationCodeRequired!==false;
  const message=feedback(initialMessage,initialMessage ? 'info' : 'error');
  const tabLogin=h('button',{type:'button',role:'tab',id:'login-tab','aria-selected':'true'},'Anmelden');
  const tabRegister=h('button',{type:'button',role:'tab',id:'register-tab','aria-selected':'false'},'Neuer Spieler');
  const form=h('form',{id:'auth-form',novalidate:true});
  const formArea=h('div',{},message,form);
  function draw() {
    const username=field('Spielername','username',{autocomplete:'username',maxlength:32,
      autocapitalize:'none',spellcheck:'false',hint:'Dein fester Name zum Anmelden.'});
    const display=field('Anzeigename','display-name',{autocomplete:'nickname',maxlength:40,placeholder:'So sehen dich deine Freunde'});
    const password=field('Passwort','password',{type:'password',autocomplete:mode==='login' ? 'current-password' : 'new-password',
      hint:mode==='register' ? 'Mindestens 6 Zeichen. Das Passwort wird nur serverseitig gehasht gespeichert.' : ''});
    const confirm=field('Passwort wiederholen','password-confirm',{type:'password',autocomplete:'new-password'});
    const code=field('Registrierungscode','access-code',{type:'password',autocapitalize:'none',spellcheck:'false',hint:'Den Code erhältst du vom Gastgeber.'});
    const show=h('input',{type:'checkbox',id:'show-password'});
    show.addEventListener('change',()=>{for (const f of [password,confirm]) f.input.type=show.checked ? 'text' : 'password';});
    const submit=h('button',{type:'submit',class:'button primary',id:'auth-submit'},icon(mode==='login' ? 'arrow' : 'sparkle'),mode==='login' ? 'Ins Lager eintreten' : 'Spieler anlegen');
    const closed=mode==='register' && status && !status.registrationOpen;
    form.replaceChildren(username.wrapper,...(mode==='register' ? [display.wrapper] : []),password.wrapper,
      ...(mode==='register' ? [confirm.wrapper,...(codeRequired?[code.wrapper]:[])] : []),
      h('label',{class:'checkbox-line',for:'show-password'},show,'Passwort anzeigen'),
      ...(closed ? [h('p',{class:'notice'},'Neue Registrierungen sind noch nicht freigeschaltet. Bestehende Spieler können sich weiterhin anmelden.')] : []),
      submit,
      h('p',{class:'form-footnote'},icon('shield'),'Ohne E-Mail. Dein Browser merkt sich deine Anmeldung.'));
    submit.disabled=Boolean(closed);
    form.onsubmit=async event=>{
      event.preventDefault();
      if (form.getAttribute('aria-busy')==='true') return;
      const values={username:normalizeUsername(username.input.value),displayName:display.input.value.trim(),password:password.input.value,accessCode:code.input.value};
      let error=validateUsername(values.username) || (mode==='register' ? validateDisplayName(values.displayName) || validatePassword(values.password) : '');
      if (!values.password) error='Bitte dein Passwort eingeben.';
      if (mode==='register' && values.password!==confirm.input.value) error='Die beiden Passwörter stimmen nicht überein.';
      if (mode==='register' && codeRequired && !values.accessCode) error='Bitte den Registrierungscode eingeben.';
      if (error) { setFeedback(message,error); return; }
      setFeedback(message,''); setBusy(form,true); tabLogin.disabled=true; tabRegister.disabled=true;
      submit.textContent=mode==='login' ? 'Das Tor öffnet sich …' : 'Dein Spieler wird angelegt …';
      try {
        const result=mode==='login'
          ? await api.rpc('login_player',{p_username:values.username,p_password:values.password,p_device_label:deviceLabel()})
          : await api.rpc('register_player',{p_username:values.username,p_display_name:values.displayName,p_password:values.password,p_access_code:values.accessCode,p_device_label:deviceLabel()});
        if (!disposed) await onAuthenticated(result);
      } catch (error) { if (!disposed) setFeedback(message,error.message); }
      finally {
        if (!disposed) { setBusy(form,false);tabLogin.disabled=false;tabRegister.disabled=false;submit.textContent=mode==='login' ? 'Ins Lager eintreten' : 'Spieler anlegen';submit.disabled=Boolean(closed); }
      }
    };
  }
  function switchMode(next) {
    if (mode===next) return;
    mode=next; tabLogin.setAttribute('aria-selected',String(mode==='login'));tabRegister.setAttribute('aria-selected',String(mode==='register'));
    setFeedback(message,''); draw();form.querySelector('input')?.focus();
  }
  tabLogin.addEventListener('click',()=>switchMode('login'));tabRegister.addEventListener('click',()=>switchMode('register'));draw();
  const element=h('section',{class:'auth-layout'},
    h('div',{class:'auth-story'},h('div',{class:'eyebrow'},icon('sparkle'),'Ein Abenteuer unter Freunden'),
      h('h1',{},'Ein Wurf. ',h('em',{},'Tausend Wege.')),
      h('p',{},'Tief unter dem Feenwald warten verborgene Schätze und alte Wächter. Findet gemeinsam euren Weg durch den Dungeon.'),
      h('div',{class:'story-chips'},h('span',{},icon('dice'),'Würfeln'),h('span',{},icon('map'),'Entdecken'),h('span',{},icon('diamond'),'Schätze sammeln'))),
    h('div',{class:'panel auth-panel'},h('p',{class:'eyebrow'},'Willkommen im Würfeldungeon'),
      h('h2',{},'Das Abenteuer wartet.'),h('p',{class:'muted'},'Melde dich an oder lege deinen Spieler an.'),
      h('div',{class:'tabs',role:'tablist','aria-label':'Anmeldung oder Registrierung'},tabLogin,tabRegister),formArea));
  return {element,cleanup:()=>{disposed=true;}};
}
