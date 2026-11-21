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
  Svih 8 imaju jobname; jobovi 7/8 (`process_pending_zahtevi`,
  `expire_unanswered_alternativa_10m`) imenovani tekstom komande u
  `20261119000000_name_unnamed_cron_jobs.sql`.
- `20261120000000_add_missing_updated_at_triggers.sql` = set_updated_at
  triggeri na v3_krediti/v3_uplata_pazara/v3_vozac_location (delta resync).
  `supabase migration up` odbija — u schema_migrations fale lokalni fajlovi
  (arhivirani u baseline); nove migracije primenjivati docker exec psql +
  rucni INSERT u supabase_migrations.schema_migrations.

## Release (GitHub Actions)

- Workflow cita `.env` iz `APP_ENV_BASE64` secret-a i bundle-uje ga u svaki
  build. OBAVEZNO ga azurirati pri svakoj izmeni `.env`:
  `gh secret set APP_ENV_BASE64 --body "$(base64 -w0 .env)"`
  (poslednji put azuriran 2026-11-19 na self-hosted URL)

## Backup

- `supabase-service/backup_supabase.ps1` — pg_dump -Fc cele baze + kopija
  .env.admin u `C:\gavra-backups`, dnevno 03:30 (Scheduled Task
  `GavraSupabase_Backup`), retention 14 dana. Task je do 2026-11-21 bio
  pogresno registrovan (putanja skripte u WorkingDirectory umesto -File
  argumenta, padao sa 0x8007010B) — popravljeno i verifikovano rucnim
  run-om; StartWhenAvailable ukljucen.
- Restore: `docker cp` dump u kontejner, pa
  `pg_restore -U supabase_admin -d postgres -c fajl.dump`
- Dumpovi STARE cloud baze (schema + data, 2026-11-18) cuvaju se u
  `C:\gavra-backups\migration_artifacts\` — ne vracati u repo.

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

## Cloud→local merge (2026-11-20)

- Cloud projekat `gjtabtwudbrmfeyjiicu` je i dalje PRIMIO UPISE od starih
  build-ova (bundle-ovan stari .env) do force update-a — nije "mrtav".
- 2026-11-20 uradjen merge cloud→local (latest-wins po `updated_at` +
  insert cloud-only redova; ~376 redova: operativna 167, zahtevi 60,
  finansije 57, auth 51, dodela/slot 33, ostalo). Skripte + diff izvestaj:
  `C:\gavra-backups\migration_artifacts\gavra_{diff,merge}.py` i
  `gavra_diff_report.json`; pre-merge backup `pre_merge_cloud_sync_20261120.dump`.
- Merge se radi sa `SET LOCAL session_replication_role='replica'` u tx —
  zaobilazi triggere/FK da se upise verbatim cloud stanje (bez duplog
  finansije/dodela sync-a).
- Semantic-twin slucaj: `v3_operativna_nedelja` parcijalni unique indeks
  `(created_by, datum, grad, polazak5) WHERE otkazano_at IS NULL` — isti
  termin se moze pojaviti pod 2 id-a na dva sistema (lokalni `e8f3d317`
  obrisan, kanonski cloud `e4425876` unet).
- PRE force update-a ponoviti `gavra_diff.py` pa `gavra_merge.py` (cloud
  akumulira nove upise svaki dan dok stari build-ovi voze).
- Posle force update-a: ugasiti cloud pg_cron jobove i edge funkcije da
  cloud vise ne mutira podatke, pa projekat pauzirati.

### Status 2026-11-20 (force update aktiviran)

- `gavra_merge.py` samo GENERISE SQL u `%TEMP%\gavra_merge.sql` — treba ga
  rucno primeniti: `docker exec -i supabase_db_gavra_android psql -U
  postgres -d postgres -v ON_ERROR_STOP=1 < gavra_merge.sql`.
- Force update na cloud `v3_app_settings`: `force_update_ios=true`
  (min 6.0.634 — iOS je LIVE), `force_update_android=false` dok
  6.0.635 ne prodje Play review. Stari build-ovi citaju flag iz
  CLOUD-a; novi citaju lokalni red (force=false — bez banner-a).
- VAZNO: Play API `edits.tracks` status `completed` = rollout komitovan,
  NE znaci da je release prosao review/live. 6.0.635 je commit-ovan
  20.11 ~09:52 ali je u recenziji (vezano za "Dozvole za lokaciju"
  deklaraciju "recenzija u toku") — na store-u je nema, 0 uredjaja je
  ima, konzola je ne prikazuje kao objavljenu. Force-update dijalog je
  HARD blokada (PopScope canPop:false) — flag ne sme biti ukljucen dok
  verzija nije skinljiva, inace zakljuca sve korisnike.
- Kad 6.0.635 prodje review: `UPDATE v3_app_settings SET
  force_update_android=true` na cloud-u.
- iOS 6.0.634 verifikovan da nosi self-hosted .env: v3_auth redovi sa
  `app_version='6.0.634+60634', platform='ios'` pisu u LOKALNU bazu.
- Svih 8 cloud pg_cron jobova DEAKTIVIRANO (`cron.alter_job active=false`,
  reversibilno) — cloud vise ne mutira podatke server-side.
- 2026-11-20 (update): prelazak cloud→local NIJE uspeo — svih 8 cloud
  pg_cron jobova PONOVO AKTIVIRANO (`cron.alter_job active=true`),
  verifikovano da rade (job_run_details, succeeded). Edge funkcije su
  sve vreme bile ACTIVE (nisu gasene). `force_update_ios` je vracen
  na false na cloud-u; `maintenance_mode_*` i dalje false.
- Cloud edge funkcije + projekat OSTAJU UP dok rep stragglers-a ne uvene —
  stari build-ovi ih koriste do update-a; njihovi upisi se povlace
  ponovljenim merge-om. PRE pauziranja projekta: poslednji merge + provera
  da vise nema cloud-only upisa.
- Opcija za rep koji se ne updatuje: `maintenance_mode_*=true` na cloud-u
  (app im postaje neupotrebljiv — ultimativni kill-switch).

### Status 2026-11-20 (finalni prelazak — force update LIVE)

- Cloud `v3_app_settings`: `force_update_android=true` i
  `force_update_ios=true` (latest/min: android 6.0.636, ios 6.0.634) —
  stari build-ovi su HARD blokirani na force-update dijalogu.
- Finalni merge primenjen ~16h: 110 redova cloud→local (auth 29,
  finansije 36, operativna 36, dodela_slot 7, zahtevi 1).
  `v3_app_settings` NAMERNO iskljucen iz merge-a — lokalni red ostaje
  `force_update_*=false` (novi build-ovi bez banner-a); lokalni
  latest/min podignut na 6.0.636 radi konzistentnosti.
- Post-merge diff verifikacija: `only_cloud=0` na svim tabelama;
  preostali diff-ovi su iskljucivo "local noviji" (last_seen_at,
  app_version, tracking polja) — lokalna baza je kanonska.
- Svih 8 cloud pg_cron jobova DEAKTIVIRANO (`cron.alter_job
  active=false`, reversibilno) — cloud vise ne mutira podatke
  server-side. Lokalnih 8 jobova aktivno.
- Cloud edge funkcije (10) i projekat OSTAJU UP — stari build-ovi
  citaju force-update config sa cloud REST-a; pausiranje cloud-a bi
  tiho pustilo stragglere dalje (row==null -> nema banner-a).
- Sledeci korak kad stragglera nema (proveriti `v3_auth.app_version`/
  `last_seen_at` na cloud-u): finalni merge, pa `pause_project`
  (MCP) ili maintenance_mode kill-switch.
