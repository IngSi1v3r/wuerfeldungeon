-- Lesender Check: gibt keine Passwörter, Codes oder Sitzungsschlüssel aus.
select public.app_status() as installation;
select id, public, file_size_limit, allowed_mime_types
  from storage.buckets where id in ('avatars','map-assets');
select tablename, rowsecurity
  from pg_catalog.pg_tables where schemaname='public' and tablename like 'dungeon\_%' escape '\'
  order by tablename;
select pg_catalog.has_function_privilege('anon','public.login_player(text,text,text)','EXECUTE')
  as public_login_rpc_allowed,
  pg_catalog.has_table_privilege('anon','public.dungeon_players','SELECT')
  as direct_player_read_allowed,
  pg_catalog.has_function_privilege('anon','public.app_finish_avatar_upload(text,text,integer)','EXECUTE')
  as direct_avatar_commit_allowed;
-- Erwartet: schemaVersion=1, registrationOpen=true, beide Buckets vorhanden,
-- rowsecurity überall true, letzter Check: true / false / false.
