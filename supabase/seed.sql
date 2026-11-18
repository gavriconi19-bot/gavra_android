-- Minimalni seed za funkcionalan stack nakon `supabase db reset`.
-- Produkcioni podaci se NE seed-uju iz repozitorijuma — backup skripta
-- (supabase-service/backup_supabase.ps1) je izvor za restore podataka.

-- Singleton red koji app/edge funkcije očekuju da postoji.
insert into public.v3_app_settings (id)
values ('global')
on conflict (id) do nothing;
