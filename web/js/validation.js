import {COSMETICS} from './cosmetics.js';
export const MARK_STYLES = Object.freeze(['cross','pencil','waves','solid','stars','runes','claws','spiral','weave','seal']);
export const DEFAULT_PREFERENCES = Object.freeze({markStyle:'cross',sound:true,music:false,reduceMotion:false});

export function normalizeUsername(value) { return String(value ?? '').trim().toLowerCase(); }
export function validateUsername(value) {
  return /^[a-z0-9._-]{3,32}$/.test(normalizeUsername(value))
    ? '' : '3–32 Zeichen: Buchstaben a–z, Zahlen, Punkt, Bindestrich oder Unterstrich.';
}
export function validateDisplayName(value) {
  const length = Array.from(String(value ?? '').trim()).length;
  return length >= 1 && length <= 40 ? '' : 'Bitte einen Anzeigenamen mit 1–40 Zeichen eingeben.';
}
export function validatePassword(value) {
  return Array.from(String(value ?? '')).length >= 6 && new TextEncoder().encode(String(value ?? '')).length <= 72
    ? '' : 'Das Passwort braucht mindestens 6 Zeichen und höchstens 72 UTF-8-Bytes.';
}
export function cleanPreferences(value = {}) {
  return {
    ...Object.fromEntries(Object.entries(COSMETICS).filter(([key])=>value[key]!==undefined).map(([key,s])=>[key,Object.hasOwn(s.choices,value[key])?value[key]:s.default])),
    markStyle:MARK_STYLES.includes(value.markStyle) ? value.markStyle : DEFAULT_PREFERENCES.markStyle,
    sound:typeof value.sound === 'boolean' ? value.sound : DEFAULT_PREFERENCES.sound,
    music:typeof value.music === 'boolean' ? value.music : DEFAULT_PREFERENCES.music,
    reduceMotion:typeof value.reduceMotion === 'boolean' ? value.reduceMotion : DEFAULT_PREFERENCES.reduceMotion,
  };
}
export function initials(name) {
  return String(name ?? '').trim().split(/\s+/).filter(Boolean).slice(0,2).map(part=>Array.from(part)[0]).join('').toUpperCase() || '?';
}
export function safeAvatarUrl(base,path) {
  if (!path || !/^[a-f0-9-]{36}\/[a-f0-9-]{36}\.webp$/.test(path)) return null;
  return `${base.replace(/\/$/,'')}/storage/v1/object/public/avatars/${path}`;
}
