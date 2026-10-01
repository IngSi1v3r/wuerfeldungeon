import {h,icon,avatar,pageHeading} from '../dom.js';

function card({href,title,description,symbol,phase,main=false}) {
  return h('a',{class:`menu-card ${main ? 'main-card' : ''}`,href},
    h('span',{class:`card-symbol ${symbol}`},icon(symbol)),
    h('div',{class:'card-copy'},h('div',{class:'card-title-row'},h('h2',{},title),phase ? h('span',{class:'phase-tag'},`Phase ${phase}`) : null),
      h('p',{},description)),icon('arrow','card-arrow'));
}

export function homeView({profile,counts={}}) {
  const element=h('section',{class:'home-view'},
    h('div',{class:'welcome-line'},avatar(profile),h('span',{},'Schön, dass du da bist, ',h('strong',{},profile.displayName),'.'),
      h('span',{class:'badge'},h('span',{class:'status-dot'}),'Lager bereit')),
    pageHeading('Dein Lager','Wo führt dich der nächste Wurf hin?','Ein Ort für gemeinsame Abenteuer. Versammle deinen Trupp oder entdecke eine neue Welt.'),
    counts.activeGames>0?h('a',{class:'continue-strip',href:'#/play'},icon('dice'),h('span',{},`${counts.activeGames} ${counts.activeGames===1?'Abenteuer wartet':'Abenteuer warten'} auf dich.`,h('strong',{},'Spiel fortsetzen')),icon('arrow')):null,
    h('div',{class:'menu-grid'},
      card({href:'#/play',title:'Spielen',description:'Eine Karte wählen, Freunde einladen und begonnene Runden fortsetzen.',symbol:'dice',main:true}),
      card({href:'#/editor',title:'Kartenwerkstatt',description:'Welten gemeinsam bauen, Karten prüfen und fertige Abenteuer veröffentlichen.',symbol:'map',main:true}),
      card({href:'#/profile',title:'Dein Profil',description:'Name, Profilbild und deine Abenteuerstatistik.',symbol:'user'}),
      card({href:'#/settings',title:'Einstellungen',description:'Dein Markierungsstil und persönliche Vorlieben.',symbol:'settings'}),
      card({href:'#/history',title:'Chronik',description:'Vergangene Abenteuer und ihre Sieger.',symbol:'book'})),
    h('div',{class:'camp-strip'},h('div',{},icon('shield'),h('span',{},'Privates Lager · Zugang nur mit Registrierungscode')),
      h('div',{class:'camp-counts'},h('span',{},`${counts.publishedMaps ?? 0} fertige Karten`),h('span',{},`${counts.activeGames ?? 0} laufende Spiele`))),
    h('p',{class:'phase-explanation'},'Werkstatt und Warteräume sind geöffnet. Würfeln und Züge folgen mit Phase 4.'));
  return {element};
}

export function futureView(kind) {
  const data={
    play:{phase:3,symbol:'dice',title:'Die Runde wartet noch.',text:'Hier wählst du später eine fertige Karte, eröffnest einen Warteraum oder steigst wieder in ein laufendes Spiel ein.',items:['Neue Runde mit Kartenwahl und optionalem Passwort','Offene Warteräume und mehrere fortsetzbare Spiele','Gleicher Spielstand auf Handy und Computer']},
    editor:{phase:2,symbol:'map',title:'Die Werkstatt zieht bald ein.',text:'Dein vorhandener Editor bleibt erhalten. Im nächsten Schritt verbinden wir ihn mit der gemeinsamen Kartenbibliothek.',items:['Entwürfe gemeinsam nacheinander bearbeiten','Automatisches Speichern und Bearbeitungssperre','Karten prüfen, unveränderbar veröffentlichen und kopieren','JSON-Import und portable Exporte mit Bildern']},
    history:{phase:3,symbol:'book',title:'Noch keine Abenteuer in der Chronik.',text:'Hier erscheinen später abgeschlossene Spiele mit Kartenname, Teilnehmern, Punkten und allen Siegern bei Gleichstand.',items:['Abgeschlossene Spiele durchsuchen','Ergebnisse und Sieger ansehen','Statistiken automatisch ins Profil übernehmen']},
  }[kind];
  return {element:h('section',{class:'future-view'},pageHeading(`Vorgemerkt für Phase ${data.phase}`,data.title,data.text),
    h('div',{class:'panel future-panel'},h('span',{class:'future-icon'},icon(data.symbol)),
      h('div',{},h('h2',{},'So ist dieser Bereich geplant'),h('ul',{class:'feature-list'},...data.items.map(text=>h('li',{},icon('check'),text))),
        h('a',{class:'button secondary',href:'#/home'},icon('back'),'Zurück ins Lager'))))};
}
