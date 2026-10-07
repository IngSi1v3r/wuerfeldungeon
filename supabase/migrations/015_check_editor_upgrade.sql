-- Run after 014_editor_upgrade.sql. Every result should read OK.
select 'Editor-Erweiterung' as pruefung,case when (public.app_status()->>'editorFeaturesVersion')::int=1 then 'OK' else 'FEHLT' end as ergebnis
union all select 'Kartenversion 7',case when to_regprocedure('dungeon_private.map_compile_v2(jsonb)') is not null then 'OK' else 'FEHLT' end
union all select 'Alte Kartenversion erhalten',case when to_regprocedure('dungeon_private.map_document_valid_v1(jsonb)') is not null and to_regprocedure('dungeon_private.map_report_v1(jsonb)') is not null then 'OK' else 'FEHLT' end
union all select 'Migration registriert',case when exists(select 1 from dungeon_private.schema_migrations where version=7) then 'OK' else 'FEHLT' end;
