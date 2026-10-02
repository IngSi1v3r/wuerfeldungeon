import {CONFIG} from './config.js';
import {initials,safeAvatarUrl} from './validation.js';

export function h(tag,attrs={},...children) {
  const node=document.createElement(tag);
  for (const [key,value] of Object.entries(attrs)) {
    if (value===undefined || value===null || value===false) continue;
    if (key==='class') node.className=value;
    else if (key==='text') node.textContent=value;
    else if (key.startsWith('on') && typeof value==='function') node.addEventListener(key.slice(2),value);
    else if (key==='checked' || key==='disabled' || key==='required') node[key]=Boolean(value);
    else if (key==='value') node.value=value;
    else node.setAttribute(key,value===true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child!==undefined && child!==null && child!==false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const PATHS={
  dice:['M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z','M7 7h.01M17 7h.01M12 12h.01M7 17h.01M17 17h.01'],
  map:['m3 6 6-3 6 3 6-3v15l-6 3-6-3-6 3V6Z','M9 3v15M15 6v15'],
  user:['M20 21v-2a7 7 0 0 0-14 0v2','M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z'],
  settings:['M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z','m9 3-1 3-3 1-2 3 2 2-1 3 2 3 3-1 3 2 3-2 3 1 2-3-1-3 2-2-2-3-3-1-1-3H9Z'],
  book:['M4 3h13a3 3 0 0 1 3 3v15H7a3 3 0 0 1-3-3V3Z','M4 17h16M8 7h8M8 11h6'],
  arrow:['M5 12h14m-5-5 5 5-5 5'],
  back:['M19 12H5m5-5-5 5 5 5'],
  diamond:['m3 9 5-6h8l5 6-9 12L3 9Z','M3 9h18M8 3l4 18 4-18'],
  shield:['m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Z','m8 12 3 3 5-6'],
  logout:['M9 3H5v18h4','M12 12h9m-4-4 4 4-4 4'],
  check:['m5 12 4 4L19 6'],
  upload:['M12 16V3m-5 5 5-5 5 5','M4 14v6h16v-6'],
  close:['m6 6 12 12M6 18 18 6'],
  sun:['M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z','M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M5 19l1.5-1.5M17.5 6.5 19 5'],
  home:['m3 10 9-7 9 7','M5 9v12h14V9M9 21v-7h6v7'],
  sparkle:['m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3 3-7Z'],
  lock:['M6 10h12v11H6V10Z','M8 10V6a4 4 0 0 1 8 0v4'],
  eye:['M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7Z','M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z'],
  fullscreen:['M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5'],
  minimize:['M3 8h5V3M21 8h-5V3M16 21v-5h5M8 21v-5H3'],
  pause:['M8 5v14M16 5v14'],
  play:['m8 4 12 8-12 8V4Z'],
  menu:['M4 6h16M4 12h16M4 18h16'],
  heart:['M12 21S2 15 2 8a5 5 0 0 1 10-2 5 5 0 0 1 10 2c0 7-10 13-10 13Z'],
};
export function icon(name,className='') {
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');
  for (const [key,value] of Object.entries({viewBox:'0 0 24 24',fill:'none',stroke:'currentColor','stroke-width':'1.7','stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true',class:`icon ${className}`})) svg.setAttribute(key,value);
  for (const d of PATHS[name] || PATHS.dice) {
    const path=document.createElementNS(svg.namespaceURI,'path'); path.setAttribute('d',d); svg.append(path);
  }
  return svg;
}

export function avatar(profile,size='') {
  const fallback=h('span',{class:'avatar-initials'},initials(profile?.displayName));
  const node=h('span',{class:`avatar ${size}`,'aria-label':`Profilbild von ${profile?.displayName || 'Spieler'}`},fallback);
  const url=safeAvatarUrl(CONFIG.supabaseUrl,profile?.avatarPath);
  if (url) node.append(h('img',{src:url,alt:'',loading:'lazy',onerror:event=>event.target.remove()}));
  return node;
}

export function feedback(message='',kind='error') {
  return h('div',{class:`feedback ${kind}`,role:kind==='error' ? 'alert' : 'status',hidden:!message},message);
}
export function setFeedback(node,message,kind='error') {
  node.textContent=message; node.className=`feedback ${kind}`; node.hidden=!message;
}
export function setBusy(form,busy) {
  form.setAttribute('aria-busy',String(busy));
  for (const input of form.querySelectorAll('button,input,select')) input.disabled=busy;
}
export function pageHeading(eyebrow,title,subtitle) {
  return h('div',{class:'page-heading'},eyebrow?h('p',{class:'eyebrow'},eyebrow):null,h('h1',{},title),subtitle?h('p',{class:'muted'},subtitle):null);
}
