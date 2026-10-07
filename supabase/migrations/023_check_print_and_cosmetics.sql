-- Optionale Kontrolle nach 022_print_and_cosmetics.sql.
select 'Update 0.10.1' pruefung,
 case when exists(select 1 from dungeon_private.schema_migrations where version=11) then 'OK' else 'FEHLT' end ergebnis
union all select 'Elf Kosmetikvarianten',case when (select count(*) from dungeon_private.cosmetic_catalog)=11 then 'OK' else 'FEHLT' end
union all select 'Drei kostenlose Grundvarianten',case when (select count(*) from dungeon_private.cosmetic_catalog where price=0)=3 then 'OK' else 'FEHLT' end
union all select 'Kosmetikkauf',case when has_function_privilege('anon','public.buy_cosmetic(text,text,text,uuid)','execute') then 'OK' else 'FEHLT' end
union all select 'Powerups im Warteraum',case when has_function_privilege('anon','public.update_lobby_powerups(text,uuid,jsonb,bigint,uuid)','execute') then 'OK' else 'FEHLT' end
union all select 'Private Kaufdaten',case when not has_table_privilege('anon','dungeon_private.cosmetic_purchases','select') then 'OK' else 'FEHLT' end;
