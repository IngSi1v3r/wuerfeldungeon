import {readFile} from 'node:fs/promises';
import {createUpgradedDatabase} from './game-upgrade.mjs';
export const shopMigration=()=>readFile(new URL('../../supabase/migrations/018_marking_shop.sql',import.meta.url),'utf8');
export async function createShopDatabase(){const db=await createUpgradedDatabase();await db.exec(await shopMigration());return db;}
