-- Tracking debug breadcrumb tabela.
--
-- Problem (2026-11-26): tickovi u potpunosti staju kad vozač zaključa telefon
-- — u Kong logu tokom vožnje nema NI allDone pre-GPS selecta (FGS isolate ne
-- izvršava nijedan tick), pa se iz baze ne vidi da li je FGS mrtav, isolate
-- pao ili mreža suspendovana (doze). App nema remote breadcrumba.
--
-- Tabela skuplja retke app-side događaje (start/stop/handoff/stall/error —
-- NE svaki tick) da se iz baze vidi koji deo lanca je otkazao.

CREATE TABLE IF NOT EXISTS public.v3_tracking_debug (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  v3_auth_id uuid,
  event text NOT NULL,
  detail jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.v3_tracking_debug IS
  'App-side tracking dijagnostika (FG/BG engine događaji, FGS start, stall) — remote breadcrumb. Piše app, retko (po događaju, ne po ticku).';

ALTER TABLE public.v3_tracking_debug ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow all on v3_tracking_debug" ON public.v3_tracking_debug;
CREATE POLICY "Allow all on v3_tracking_debug"
  ON public.v3_tracking_debug
  FOR ALL TO anon, authenticated
  USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_v3_tracking_debug_created_at
  ON public.v3_tracking_debug (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v3_tracking_debug_auth_created
  ON public.v3_tracking_debug (v3_auth_id, created_at DESC);

-- Retention 7 dana — čeka se u cleanup_eta_results cron-u (isti */5min job).
SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname = 'cleanup_eta_results'),
  command := $$DELETE FROM public.v3_eta_results WHERE computed_at < now() - interval '55 minutes';
             DELETE FROM public.v3_tracking_debug WHERE created_at < now() - interval '7 days';$$
);

NOTIFY pgrst, 'reload schema';
