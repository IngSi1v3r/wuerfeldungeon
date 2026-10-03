import {fogMiniature} from '../maps/fog-preview.js';
import {h,icon,feedback,setFeedback,pageHeading} from '../dom.js';
import {AppError} from '../api.js';
import {CONFIG} from '../config.js';
import {miniature,mapMiniature} from './maps.js';
import {GameCommands} from '../games/commands.js';
import {gameLink} from '../games/ui.js';

export function newGameView({api,status}) {
 let closed=false,selected=null,availableMaps=[];const commands=new GameCommands(api),message=feedback(),grid=h('div',{class:'game-map-selection',id:'game-map-selection'});
 const name=h('input',{id:'game-name',required:true,maxlength:80,autocomplete:'off'}),max=h('select',{id:'game-max-players'},...Array.from({length:15},(_,i)=>h('option',{value:i+2},`${i+2} Spieler`)));max.value='8';
 const password=h('input',{id:'game-password',type:'password',maxlength:72,autocomplete:'new-password',placeholder:'Kein Passwort'});
 const cards=h('input',{id:'game-cards',type:'checkbox',checked:true});
 const hints=h('select',{id:'game-hints'},h('option',{value:'true'},'Mit Tipps'),h('option',{value:'false'},'Ohne Tipps'));
 const modern=status?.gameFeaturesVersion===CONFIG.gameFeaturesVersion;
 const sums=h('input',{id:'game-dice-hints',type:'checkbox',checked:true}),fields=h('input',{id:'game-field-hints',type:'checkbox',checked:true}),fog=h('input',{id:'game-fog',type:'checkbox'});
 const previews=new Map();fog.addEventListener('change',()=>{for(const m of availableMaps){const target=previews.get(m.versionId);target?.replaceChildren(fog.checked?fogMiniature(api,m):mapMiniature(api,m));}});
 const selectedLabel=h('h2',{id:'selected-game-map'}),submit=h('button',{id:'create-game',class:'button primary',type:'submit',disabled:true},icon('dice'),'Warteraum eröffnen');
 const form=h('form',{class:'panel game-options',id:'create-game-form',onsubmit:async event=>{
  event.preventDefault();if(!selected)return;submit.disabled=true;setFeedback(message,'');
  try {if(new TextEncoder().encode(password.value).length>72)throw Error('Das Spielpasswort darf höchstens 72 UTF-8-Bytes lang sein.');
   const result=await commands.run('create_game',{p_map_version_id:selected.versionId,p_name:name.value.trim(),p_settings:{maxPlayers:Number(max.value),cards:cards.checked?'open':'hidden',hints:modern?sums.checked&&fields.checked:hints.value==='true',...(modern?{diceHints:sums.checked,fieldHints:fields.checked,fog:fog.checked}:{})},p_password:password.value});
   password.value='';if(!closed)location.hash=gameLink(result.gameId);
  } catch(error){if(!closed)setFeedback(message,error.message);}finally{if(!closed)submit.disabled=!selected;}
 }},h('p',{class:'eyebrow'},'2 · Deine Runde'),selectedLabel,h('div',{class:'game-form-grid'},
  h('label',{class:'map-form-label game-name-label'},'Name des Spiels',name),h('label',{class:'map-form-label'},'Maximale Spieleranzahl',max),h('label',{class:'map-form-label'},'Spielpasswort · optional',password),
  h('label',{class:'rule-check'},cards,'Offene Karten der Mitspieler'),modern?h('fieldset',{class:'game-rule-options'},h('legend',{},'Spielhilfen und Sicht'),h('label',{},sums,'Würfelsummen anzeigen'),h('label',{},fields,'Spielbare Felder hervorheben'),h('label',{},fog,'Fog of War · zwei Felder Sicht')):h('label',{class:'map-form-label'},'Kombinationen und erreichbare Felder',hints)),
  h('p',{class:'muted'},'Nach dem Start bleiben Karte, Einstellungen und Teilnehmer für dieses Spiel festgelegt.'),submit);
 form.hidden=true;
 const element=h('section',{class:'new-game-view'},h('a',{class:'back-link',href:'#/play'},icon('back'),'Zur Spielauswahl'),pageHeading('Eine Runde beginnen','Wähle eure Welt.','Hier erscheinen ausschließlich fertig veröffentlichte Karten.'),
  h('p',{class:'eyebrow'},'1 · Karte wählen'),grid,message,form);
 async function load() {
  try {
   if(status?.gameSchemaVersion!==CONFIG.gameSchemaVersion)throw new AppError('GAMES_NOT_INSTALLED');
   const data=await api.authRpc('list_game_maps');if(closed)return;
   availableMaps=data.maps;grid.replaceChildren(...data.maps.map(m=>{const preview=h('div',{class:'game-choice-preview'},mapMiniature(api,m));previews.set(m.versionId,preview);const button=h('button',{type:'button',class:'game-map-choice','data-version-id':m.versionId,'aria-pressed':'false',onclick:()=>{
    selected=m;for(const b of grid.querySelectorAll('button')){const yes=b===button;b.classList.toggle('selected',yes);b.setAttribute('aria-pressed',String(yes));}name.value=m.name;selectedLabel.textContent=m.name;form.hidden=false;submit.disabled=false;
   }},preview,h('strong',{},m.name),h('span',{class:'muted'},`${m.fields} Felder · ${m.enemies} Gegner`));return button;}));
   if(!data.maps.length)grid.append(h('div',{class:'panel game-empty'},icon('map'),h('h2',{},'Die erste Welt fehlt noch.'),h('p',{class:'muted'},'Veröffentliche zuerst eine Karte in der Kartenwerkstatt.'),h('a',{class:'button secondary',href:'#/editor'},'Kartenwerkstatt öffnen')));
  } catch(error){if(!closed)setFeedback(message,error.message);}
 }
 load();return {element,cleanup:()=>{closed=true;}};
}
