-- Rein lesender Installationscheck. Keine Spieler, Karten oder Dateien ändern.
select public.app_status() as installation;
select id,public,file_size_limit,allowed_mime_types from storage.buckets where id='map-assets';
select version from dungeon_private.schema_migrations order by version;
select
 has_function_privilege('anon','public.list_maps(text)','execute') as map_rpc_allowed,
 has_table_privilege('anon','public.dungeon_maps','select') as direct_map_read_allowed,
 has_function_privilege('anon','public.app_finish_map_asset(text,uuid,uuid,text,text,integer)','execute') as direct_asset_commit_allowed;
