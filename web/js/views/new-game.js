import {fogMiniature} from '../maps/fog-preview.js';
import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {mapMiniature} from './maps.js';
import {GameCommands} from '../games/commands.js';
import {gameLink} from '../games/ui.js';
import {powerupSelection} from '../games/powerups.js';
import {ADVENTURERS,adventurerCharacter} from '../games/adventurers.js';

export function newGameView({api,status,solo=false}) {
 let closed=false,selected=null,availableMaps=[];const commands=new GameCommands(api),message=feedback(),grid=h('div',{class:'game-map-selection',id:'game-map-selection'});
 const name=h('input',{id:'game-name',required:true,maxlength:80,autocomplete:'off'}),max=h('select',{id:'game-max-players'},...Array.from({length:15},(_,i)=>h('option',{value:i+2},`${i+2} Spieler`)));max.value='8';
 const bots=h('select',{id:'solo-bots'},...Array.from({length:8},(_,n)=>h('option',{value:n},n?`${n} ${n===1?'Abenteurer':'Abenteurer'} · experimentell`:'Alleine reisen')));
 const characterChoices=h('div',{class:'adventurer-choices',id:'adventurer-choices'}),chosenCharacters=[];
 function updateCharacters(){
  characterChoices.hidden=!Number(bots.value);characterChoices.replaceChildren(...Array.from({length:Number(bots.value)},(_,i)=>{
   const select=h('select',{'data-adventurer-seat':i,'aria-label':`Charakter von Abenteurer ${i+1}`},...ADVENTURERS.map(c=>h('option',{value:c.id},`${c.symbol} ${c.name}`)));select.value=chosenCharacters[i]||ADVENTURERS[i%ADVENTURERS.length].id;chosenCharacters[i]=select.value;
   const portrait=h('span',{class:'adventurer-emblem','aria-hidden':true}),description=h('small',{class:'muted'});
   const paint=()=>{const c=adventurerCharacter(select.value);chosenCharacters[i]=c.id;portrait.textContent=c.symbol;portrait.style.setProperty('--adventurer-color',c.color);description.textContent=c.description;};select.addEventListener('change',paint);paint();
   return h('div',{class:'adventurer-choice'},portrait,h('div',{},h('label',{},`Abenteurer ${i+1}`,select),description));
  }));
 }
 bots.addEventListener('change',updateCharacters);updateCharacters();
 const aiOnly=h('input',{id:'solo-ai-only',type:'checkbox'}),redEvery=h('select',{id:'solo-red-every'},h('option',{value:0},'Wie im Mehrspieler: einmal pro Teilnehmerzyklus'),...Array.from({length:4},(_,n)=>h('option',{value:n+1},n?`Jede ${n+1}. Runde`:'Jede Runde'))),runs=h('select',{id:'solo-test-runs'},...[1,3,5,10].map(n=>h('option',{value:n},`${n} ${n===1?'Partie':'Partien'} automatisch`)));
 aiOnly.addEventListener('change',()=>{if(aiOnly.checked&&Number(bots.value)<1)bots.value='2';for(const o of bots.options)o.disabled=aiOnly.checked&&Number(o.value)<1;runs.disabled=!aiOnly.checked;submit.textContent=aiOnly.checked?'Abenteurerprobe starten · experimentell':'Einzelspiel starten';updateCharacters();});
 runs.disabled=true;
 const password=h('input',{id:'game-password',type:'password',maxlength:72,autocomplete:'new-password',placeholder:'Kein Passwort'});
 const cards=h('input',{id:'game-cards',type:'checkbox',checked:true});
 const hints=h('select',{id:'game-hints'},h('option',{value:'true'},'Mit Tipps'),h('option',{value:'false'},'Ohne Tipps'));
 const modern=status?.gameFeaturesVersion===CONFIG.gameFeaturesVersion;
 const sums=h('input',{id:'game-dice-hints',type:'checkbox',checked:true}),fields=h('input',{id:'game-field-hints',type:'checkbox',checked:true}),fog=h('input',{id:'game-fog',type:'checkbox'});
 const powers=powerupSelection({id:'game-powerups'}),customPowers=status?.lobbyPowerupsVersion===1;
 const previews=new Map(),chosenPreview=h('div',{class:'chosen-map-preview'});
 function refreshPreviews(){
  powers.setFog(fog.checked);
  if(form.hidden)for(const m of availableMaps){const target=previews.get(m.versionId);target?.replaceChildren(fog.checked?fogMiniature(api,m):mapMiniature(api,m));}
  if(selected)chosenPreview.replaceChildren(fog.checked?fogMiniature(api,selected):mapMiniature(api,selected));
 }
 fog.addEventListener('change',refreshPreviews);
 const selectedLabel=h('h2',{id:'selected-game-map'}),submit=h('button',{id:'create-game',class:'button primary',type:'submit',disabled:true},icon('dice'),solo?'Einzelspiel starten':'Warteraum eröffnen');
 const form=h('form',{class:'panel game-options',id:'create-game-form',onsubmit:async event=>{
  event.preventDefault();if(!selected)return;submit.disabled=true;setFeedback(message,'');
  try {if(new TextEncoder().encode(password.value).length>72)throw Error('Das Spielpasswort darf höchstens 72 UTF-8-Bytes lang sein.');
   if(solo&&status?.adventurerVersion!==2)throw Error('Bitte zuerst das Datenbank-Update 034 installieren.');
   const result=await commands.run(solo?'create_solo_game':'create_game',{p_map_version_id:selected.versionId,p_name:name.value.trim(),p_settings:{maxPlayers:Number(max.value),cards:cards.checked?'open':'hidden',hints:modern?sums.checked&&fields.checked:hints.value==='true',...(modern?{diceHints:sums.checked,fieldHints:fields.checked,fog:fog.checked}:{}),...(customPowers?{allowedPowerups:powers.values()}:{}),...(solo?{adventurers:chosenCharacters.slice(0,Number(bots.value))}:{})},...(solo?{p_bot_count:Number(bots.value),p_red_every:Number(redEvery.value),p_ai_only:aiOnly.checked}:{p_password:password.value})});
   password.value='';if(!closed)location.hash=solo&&aiOnly.checked?`#/ai-lab?id=${result.gameId}&runs=${runs.value}`:gameLink(result.gameId);
  } catch(error){if(!closed)setFeedback(message,error.message);}finally{if(!closed)submit.disabled=!selected;}
 }},h('button',{type:'button',class:'back-link',id:'choose-another-map',onclick:()=>showStep(false)},icon('back'),'Andere Karte wählen'),h('p',{class:'eyebrow'},'2 · Deine Runde'),selectedLabel,chosenPreview,h('div',{class:'game-form-grid'},
  h('label',{class:'map-form-label game-name-label'},'Name des Spiels',name),solo?h('label',{class:'map-form-label'},'Mitreisende · experimentell',bots):h('label',{class:'map-form-label'},'Maximale Spieleranzahl',max),solo?h('label',{class:'map-form-label'},'Roter Würfel kostenlos',redEvery):h('label',{class:'map-form-label'},'Spielpasswort · optional',password),
  solo?h('fieldset',{class:'game-rule-options experimental-options'},h('legend',{},'Abenteurerprobe · experimentell'),h('label',{},aiOnly,'Nur Abenteurer spielen · ich schaue zu'),h('label',{class:'map-form-label'},'Testreihe',runs),h('p',{class:'muted'},'Automatische Partien haben eine eigene Auswertung. Sie zählen nicht für Profil, Shop oder menschliche Bestenlisten.')):null,
  h('fieldset',{class:'game-rule-options'},h('legend',{},'Spielhilfen und Sicht'),h('label',{},cards,'Offene Karten der Mitspieler'),modern?h('label',{},sums,'Würfelsummen anzeigen'):null,modern?h('label',{},fields,'Spielbare Felder hervorheben'):null,modern?h('label',{},fog,'Fog of War · zwei Felder Sicht'):null),
  modern?null:h('label',{class:'map-form-label'},'Kombinationen und erreichbare Felder',hints)),
  solo?characterChoices:null,customPowers?powers.element:null,submit);
 form.hidden=true;
 const heading=pageHeading(solo?'Einzelspiel':'Eine Runde beginnen',solo?'Wähle dein Abenteuer.':'Wähle eure Welt.'),choose=h('div',{id:'choose-game-map'},heading,h('p',{class:'eyebrow'},'1 · Karte wählen'),grid);
 const element=h('section',{class:'new-game-view'},h('a',{class:'back-link',href:'#/play'},icon('back'),'Zur Spielauswahl'),choose,message,form);
 function showStep(settings){
  choose.hidden=settings;form.hidden=!settings;
  refreshPreviews();
  window.scrollTo({top:0,behavior:'instant'});
  if(settings)name.focus({preventScroll:true});else grid.querySelector('.selected')?.focus({preventScroll:true});
 }
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('list_game_maps');if(closed)return;
   availableMaps=data.maps;grid.replaceChildren(...data.maps.map(m=>{const preview=h('div',{class:'game-choice-preview'},mapMiniature(api,m));previews.set(m.versionId,preview);const button=h('button',{type:'button',class:'game-map-choice','data-version-id':m.versionId,'aria-pressed':'false',onclick:()=>{
    if(selected?.versionId!==m.versionId){name.value=m.name;powers.set(m.allowedPowerups||['extraLife','redDice','torch']);}
    selected=m;for(const b of grid.querySelectorAll('button')){const yes=b===button;b.classList.toggle('selected',yes);b.setAttribute('aria-pressed',String(yes));}selectedLabel.textContent=m.name;submit.disabled=false;showStep(true);
   }},preview,h('strong',{},m.name),h('span',{class:'muted'},`${m.fields} Felder · ${m.enemies} Gegner`));return button;}));
   if(!data.maps.length)grid.append(h('div',{class:'panel game-empty'},icon('map'),h('h2',{},'Die erste Welt fehlt noch.'),h('p',{class:'muted'},'Veröffentliche zuerst eine Karte in der Kartenwerkstatt.'),h('a',{class:'button secondary',href:'#/editor'},'Kartenwerkstatt öffnen')));
  } catch(error){if(!closed)setFeedback(message,error.message);}
 }
 load();return {element,cleanup:()=>{closed=true;}};
}
