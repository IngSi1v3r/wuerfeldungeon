import {h,icon,pageHeading} from '../dom.js';

function card({href,title,description,symbol,main=false}) {
  return h('a',{class:`menu-card ${main ? 'main-card' : ''}`,href},
    h('span',{class:`card-symbol ${symbol}`},icon(symbol)),
    h('div',{class:'card-copy'},h('div',{class:'card-title-row'},h('h2',{},title)),
      h('p',{},description)),icon('arrow','card-arrow'));
}

export function homeView({profile,counts={}}) {
  const element=h('section',{class:'home-view'},
    pageHeading('Dein Lager','Wo führt dich der nächste Wurf hin?'),
    counts.activeGames>0?h('a',{class:'continue-strip',href:'#/play'},icon('dice'),h('span',{},`${counts.activeGames} ${counts.activeGames===1?'Abenteuer wartet':'Abenteuer warten'} auf dich.`,h('strong',{},'Spiel fortsetzen')),icon('arrow')):null,
    h('div',{class:'menu-grid'},
      card({href:'#/play',title:'Spielen',description:'Eine Karte wählen, Freunde einladen und begonnene Runden fortsetzen.',symbol:'dice',main:true}),
      card({href:'#/editor',title:'Kartenwerkstatt',description:'Welten gemeinsam bauen, Karten prüfen und fertige Abenteuer veröffentlichen.',symbol:'map',main:true}),
      card({href:'#/profile',title:'Dein Profil',description:'Name, Profilbild und deine Abenteuerstatistik.',symbol:'user'}),
      card({href:'#/settings',title:'Einstellungen',description:'Dein Markierungsstil und persönliche Vorlieben.',symbol:'settings'}),
      card({href:'#/history',title:'Chronik',description:'Vergangene Abenteuer und ihre Sieger.',symbol:'book'}),
      card({href:'#/highscores',title:'Bestenlisten',description:'Abenteuerwertung pro Karte vergleichen.',symbol:'diamond'})));
  return {element};
}
