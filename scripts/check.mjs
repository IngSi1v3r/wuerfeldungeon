import {readdir,readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const files=[];
async function walk(dir) {
  for (const item of await readdir(dir,{withFileTypes:true})) {
    const path=dir+'/'+item.name;
    if (item.isDirectory()) await walk(path); else if (/\.m?js$/.test(item.name)) files.push(path);
  }
}
await walk(root+'/web');await walk(root+'/supabase/functions');await walk(root+'/scripts');await walk(root+'/tests');
let failures=0;
for (const path of files) {
  const result=spawnSync(process.execPath,['--check',path],{encoding:'utf8'});
  if (result.status!==0) {console.error(result.stderr);failures++;}
}
const webConfig=await readFile(root+'/web/js/config.js','utf8');
if (/sb_secret_|service_role/.test(webConfig.replace(/^\s*\/\/.*$/gm,''))) {console.error('Geheimer Schlüssel im Browser-Code!');failures++;}
if (failures) process.exitCode=1;
else console.log(`${files.length} JavaScript-Dateien syntaktisch geprüft; kein geheimer Server-Schlüssel in config.js.`);
