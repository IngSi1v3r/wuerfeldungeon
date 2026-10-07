-- Optionale, rein lesende Kontrolle für Update 0.10.2.
select 'Update 0.10.2' as pruefung,
 case when exists(select 1 from dungeon_private.schema_migrations where version=12) then 'OK' else 'FEHLT' end as ergebnis
union all
select 'Erweiterte Kartenregeln',case when (public.app_status()->>'originalMapRulesVersion')::int=1 then 'OK' else 'FEHLT' end
union all
select 'Neuer Paschfeldtyp',case when exists(select 1 from pg_constraint where conrelid='public.dungeon_map_cells'::regclass and conname='dungeon_map_cells_kind_check' and pg_get_constraintdef(oid) like '%doubleSum%') then 'OK' else 'FEHLT' end
union all
select 'Passender Pasch',case when 'doubles:6'=any(dungeon_private.dice_options_exact('[3,3,1,5]',false)) and not 'doubles:6'=any(dungeon_private.dice_options_exact('[2,4,5,6]',false)) then 'OK' else 'FEHLT' end
union all
select 'Roter Würfel',case when not 'doubles:6'=any(dungeon_private.dice_options_exact('[3,1,2,3]',false)) and 'doubles:6'=any(dungeon_private.dice_options_exact('[3,1,2,3]',true)) then 'OK' else 'FEHLT' end;
