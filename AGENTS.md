# Gavra — laptop self-hosted stack (single source of truth)

Od 2026-11-18 laptop (`win-vfeglqf71ss.tail61b7a2.ts.net`) je JEDINI source of
truth za bazu i backend. Cloud Supabase projekat se vise ne koristi.

## Arhitektura

- Supabase CLI stack u Docker-u (`supabase start`): Kong :54321, DB :54322,
  Studio :54323, realtime, edge runtime, auth, storage
- Tailscale Funnel: `:8443 -> Kong:54321` (app REST/realtime/edge),
  `:443 -> osrm_proxy:8000` (OSRM rutiranje)
- OSRM: `osrm-server` Docker na :5000 (region.osm.pbf = operativni region
  Bela Crkva / Vrsac), `osrm-service/osrm_proxy.py` na :8000 sa X-API-Key zastitom
- App cita `SUPABASE_URL`/`SUPABASE_ANON_KEY` iz `.env` (bundle-uje se);
  service role + JWT secret su u `.env.admin` (NIKAD u bundle)

## Migracije — pravila

- `supabase/migrations/20261118000000_baseline_v3_schema.sql` = kompletna
  public sema (generisana pg_dump-om, verifikovana replay+diff = 0 razlika).
  Sve NOVE izmene seme idu iskljucivo kroz nove migracione fajlove.
- `supabase/migrations_archive/` = istorija starih migracija (NE vracati u
  migrations/ — njihovo stanje je vec u baseline-u).
- `supabase/migrations/20261118000001_ensure_all_v3_tables...` = idempotentni
  guard da sve v3_* tabele ostanu u supabase_realtime publikaciji.
- pg_cron jobovi zive u baseline-u (8 jobova) — pg_dump ih ne hvata.

## Backup

- `supabase-service/backup_supabase.ps1` — pg_dump -Fc cele baze + kopija
  .env.admin u `C:\gavra-backups`, dnevno 03:30 (Scheduled Task
  `GavraSupabase_Backup`), retention 14 dana.
- Restore: `docker cp` dump u kontejner, pa
  `pg_restore -U supabase_admin -d postgres -c fajl.dump`

## Watchdog / autostart (Scheduled Tasks)

- `GavraSupabase_Watchdog` — svakih 5 min: startuje ugasene supabase_*
  kontejnere, proverava Kong + reciklira Funnel :8443
- `GavraOSRM_Autostart` / `GavraOSRM_Watchdog` — OSRM kontejner, proxy :8000,
  Funnel :443

## Provere

- Realtime: `curl -H "Upgrade: websocket" ... :8443/realtime/v1/websocket?apikey=KEY`
  mora vratiti 101
- Publikacija: sve public.v3_* tabele moraju biti u supabase_realtime
- Napomene: `supabase_pg_meta` kontejner je unhealthy (samo Studio, ne utice na app)
