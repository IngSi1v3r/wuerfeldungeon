import {readFile} from 'node:fs/promises';
import {createClassicDatabase} from './classic-game.mjs';
export async function createStabilityDatabase(options){
 const db=await createClassicDatabase(options);
 await db.exec(await readFile(new URL('../../supabase/migrations/012_stability.sql',import.meta.url),'utf8'));
 return db;
}
