import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
// Default: Playwright's installed Chromium. Optional local runner overrides
// use the same settings as the existing full-game browser tests.
export function browserOptions(){
 const args=process.env.WUERFELDUNGEON_CHROMIUM_MODULE?require(process.env.WUERFELDUNGEON_CHROMIUM_MODULE).default.args.filter(v=>!['--single-process','--disable-web-security'].includes(v)):[];
 return {headless:true,executablePath:process.env.WUERFELDUNGEON_CHROMIUM_PATH||undefined,args};
}
