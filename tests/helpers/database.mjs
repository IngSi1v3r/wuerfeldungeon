import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

export const TEST_ACCESS_CODE = 'Friends-only-test-42';

export async function createDatabase() {
  const db = new PGlite({extensions:{pgcrypto}});
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role;
    grant usage on schema public to anon,authenticated,service_role;
    create schema storage;
    create table storage.buckets (
      id text primary key,name text,public boolean,
      file_size_limit bigint,allowed_mime_types text[]
    );
  `);
  await db.exec(await readFile(new URL('../../supabase/migrations/001_phase1.sql',import.meta.url),'utf8'));
  await db.query(`update dungeon_private.app_config set registration_code_hash=dungeon_private.hash_password($1) where singleton`,[TEST_ACCESS_CODE]);
  return db;
}

export async function callRpc(db,name,params={},role='anon') {
  if (!/^[a-z_]+$/.test(name)) throw new Error('Invalid RPC name');
  const keys = Object.keys(params);
  if (!keys.every(key=>/^p_[a-z_]+$/.test(key))) throw new Error('Invalid RPC parameter');
  const argumentsSql = keys.map((key,index)=>`${key} => $${index+1}`).join(',');
  await db.exec(`set role ${role}`);
  try {
    const response = await db.query(`select public.${name}(${argumentsSql}) as result`,Object.values(params));
    return response.rows[0].result;
  } finally { await db.exec('reset role'); }
}
