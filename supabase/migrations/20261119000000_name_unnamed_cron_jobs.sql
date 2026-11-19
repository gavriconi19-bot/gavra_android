-- Imenuje pg_cron jobove koji su na živoj bazi kreirani bez imena
-- (cron.schedule pozivima bez jobname argumenta). Nakon db reset/restore
-- iz baseline-a bili bi ponovo anonimni, pa ih ovde vezujemo po komandi.
-- Idempotentno. Otporn na replay pod rolama bez prava na cron.job
-- (npr. `postgres` u ovom stacku nije superuser — to radi `supabase_admin`).
do $$
begin
  update cron.job set jobname = 'process_pending_zahtevi'
    where command = 'select public.process_pending_zahtevi();'
      and (jobname is null or jobname = '');
  update cron.job set jobname = 'expire_unanswered_alternativa_10m'
    where command = 'select public.expire_unanswered_alternativa_10m();'
      and (jobname is null or jobname = '');
exception
  when insufficient_privilege or undefined_table then
    raise notice 'preskočeno imenovanje cron jobova (nema prava na cron.job)';
end $$;
