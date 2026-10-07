-- NUR IM SUPABASE SQL EDITOR verwenden. Nicht mit echtem Code veröffentlichen.
-- Ersetze unten DEIN_PRIVATER_ZUGANGSCODE durch deinen gewünschten Code.
-- 6 bis 72 UTF-8-Bytes, keine Apostrophe verwenden.
-- Der Code wird gehasht; der Klartext wird nicht in einer Tabelle gespeichert.
-- Supabase kann SQL-Editor-Abfragen im Projektverlauf behalten. Zugriff auf
-- das Supabase-Dashboard ist daher ausschließlich für dich gedacht.
begin;
do $$
declare access_code text := 'DEIN_PRIVATER_ZUGANGSCODE';
begin
  if access_code = ('DEIN_PRIVATER_' || 'ZUGANGSCODE')
    or octet_length(access_code) not between 6 and 72 then
    raise exception 'Bitte zuerst deinen privaten Registrierungscode im Skript einsetzen (6–72 Bytes).';
  end if;
  update dungeon_private.app_config set registration_enabled=true,
    registration_code_hash=dungeon_private.hash_password(access_code),updated_at=now()
    where singleton;
end;
$$;
commit;

-- Später neue Registrierungen sperren (bestehende Logins bleiben möglich):
-- update dungeon_private.app_config set registration_enabled=false where singleton;
