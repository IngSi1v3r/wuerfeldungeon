import {createServer} from 'node:http';
import {readFile,stat} from 'node:fs/promises';
import {resolve,extname,sep} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=fileURLToPath(new URL('../web/',import.meta.url));
const port=Number(process.env.PORT || 5173);
const types={'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.json':'application/json; charset=utf-8'};
createServer(async(request,response)=>{
  try {
    const pathname=decodeURIComponent(new URL(request.url,'http://localhost').pathname);
    const path=resolve(root,`.${pathname.endsWith('/') ? pathname+'index.html' : pathname}`);
    if (!path.startsWith(root.endsWith(sep) ? root : root+sep)) {response.writeHead(403);response.end();return;}
    if (!(await stat(path)).isFile()) throw new Error('Not a file');
    response.writeHead(200,{'Content-Type':types[extname(path)] || 'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
    response.end(await readFile(path));
  } catch {response.writeHead(404,{'Content-Type':'text/plain; charset=utf-8'});response.end('Nicht gefunden.');}
}).listen(port,'127.0.0.1',()=>console.log(`Würfeldungeon lokal: http://localhost:${port}`));
