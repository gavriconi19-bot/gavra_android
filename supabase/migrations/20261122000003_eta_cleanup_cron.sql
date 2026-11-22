-- ETA cleanup cron + komentar fix.
--
-- v3-compute-eta briše redove starije od 55min samo pri svojim pozivima —
-- kad niko ne track-uje, zastareli redovi bi ostajali u tabeli zauvek i
-- putnik bi video zamrznutu "za 0 min" ETA do kraja 3h prozora. Ovaj job
-- primenjuje isti retention nezavisno od poziva.
--
-- 55 min odgovara ETA_RETENTION_SECONDS u v3-compute-eta i
-- etaRetentionDuration u lib/globals.dart.

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'cleanup_eta_results') then
    perform cron.schedule(
      'cleanup_eta_results',
      '*/5 * * * *',
      $c$DELETE FROM public.v3_eta_results WHERE computed_at < now() - interval '55 minutes'$c$
    );
  end if;
end $$;

-- Komentar je zastareo (tick je 5s, ne 20s).
COMMENT ON TABLE public.v3_vozac_location IS 'Jedna trenutna GPS lokacija po vozaču. Ažurira je Flutter app svakih 5s dok tracking radi. JEDINI izvor istine za lokaciju vozača.';
