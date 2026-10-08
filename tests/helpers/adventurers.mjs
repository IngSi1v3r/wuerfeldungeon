import {readFile} from 'node:fs/promises';
import {createSoloDatabase} from './solo-ai.mjs';
export async function createAdventurerDatabase(){const db=await createSoloDatabase();await db.exec(await readFile(new URL('../../supabase/migrations/034_adventurers.sql',import.meta.url),'utf8'));return db;}
