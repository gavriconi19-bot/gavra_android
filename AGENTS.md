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
- `20261121000000_fix_alternativa_logic.sql` = fix-ovi alternativa toka:
  neradni_dani scope (bc/vs) u server fn-ama, zabrana proslih termina
  (process + accept RPC), FOR UPDATE na kapacitet slotu u approve path-u,
  inline 10-min expiry za 'alternativa' u fn_v3_alternativa_action,
  process_pending_zahtevi_slots(p_ignore_schedule) -> manual_process
  stvarno forsira, transfer_to_operativna odobreno grana otporna na
  duplikate (ranije unique-violation), anon/authenticated revoke na
  internim fn-ama. Primenjeno docker exec psql + schema_migrations insert.
- `20261121000001_fix_oslobodjeno_mesto_logic.sql` = fix-ovi "oslobodjeno
  mesto" toka: process_pending_zahtevi_slots racuna aktivne mesto_ponuda
  ponude u zauzetost (approve ne krade ponudjeno mesto); mrtav guard
  `d.termin_id = z.id` popravljen join-om kroz v3_operativna_nedelja
  (termin_id je FK na operativnu stavku, ne zahtev); nova kolona
  `mesto_ponuda_expired_at` — 10-min timeout vise nije trajna odbijenica
  (cooldown 30 min + rescan u fn_v3_expire_mesto_ponuda); slot FOR UPDATE
  u fn_v3_offer_freed_seats + SKIP LOCKED kandidati; trigger guard
  pokriva sve statuse; latentni `''::time` parse bug koji je obarao svaki
  upgrade accept. Verifikovano rollback testom T1–T5.
- `20261121000002_push_notification_fixes.sql` = push audit fix-ovi:
  notify_push salje x-api-key (vault secret `gavra_api_key` — mora biti isti
  kao GAVRA013_API_KEY u .env.admin; pri rotaciji kljuca azurirati OBA);
  edge send-push-notification zahteva taj header (401 bez njega);
  sync-login-columns device-replaced push ide kroz rpc notify_push (HMS fix);
  zahtev/operativna notify f-j-e SECURITY DEFINER + GUC marker
  `gavra.zahtev_cancel_notified` sprecava dupli push pri propagaciji
  otkazivanja; NOVI trigger trg_v3_notify_putnik_on_operativna_otkazano
  (putnik dobija push i kad se operativna otkaže direktno, ne samo kroz
  zahtev); REVOKE EXECUTE sa anon/authenticated/PUBLIC na push fn-ama
  (driver_started zadrzava anon — app ga zove); drop-ovan mrtav 11-param
  weather overload. Verifikovano tx rollback testom (1 push, ne 2).
- `20261120000000_add_missing_updated_at_triggers.sql` = set_updated_at
  triggeri na v3_krediti/v3_uplata_pazara/v3_vozac_location (delta resync).
  `supabase migration up` odbija — u schema_migrations fale lokalni fajlovi
  (arhivirani u baseline); nove migracije primenjivati docker exec psql +
  rucni INSERT u supabase_migrations.schema_migrations.
- `20261122000000_bootstrap_rpc_and_indexes.sql` = cold-start ubrzanje:
  `fn_v3_bootstrap(p_phase)` — sve bootstrap tabele kao jedan JSONB u 1
  round-trip-u ('critical'/'secondary'/'all'; faze odgovaraju
  V3RealtimeTableRegistry split-u). RPC zaobilazi PostgREST max_rows=1000
  (v3_finansije se vec blizi limitu). `fn_v3_bootstrap_delta(p_watermarks)`
  — delta po updated_at watermark-ima u 1 pozivu (eta_results po
  computed_at). Slim projekcije: finansije bez
  broj_voznji/ime/naplatio_ime/poslednja_dopuna (app ih ne cita), zahtevi sa
  mesto_ponuda*/alternativa_offered_at/updated_by (bili izostavljeni).
  GRANT EXECUTE anon+authenticated (app zove RPC direktno). updated_at
  indexi na vozila/krediti/racuni/trenutna_dodela(_slot)/uplata_pazara.
  Posle primene: NOTIFY pgrst 'reload schema' (u migraciji).
- App-side (isti commit): V3CachePersistence snima keš u
  Documents/v3_realtime_cache.json (debounce 30s + onPause) → cold start
  renderuje sa diska pa delta (<12h) ili full bootstrap (>12h). Sekundarne
  tabele (finansije/gorivo/krediti/uplata_pazara/eta/vozac_location) stizu
  u pozadini posle kritične faze — v3_vozac_screen se otključava na
  kritičnim. v3_racuni izbacen iz realtime registry (nista ne cita keš).
  Expando memoizacija parse-a finansije *_json kolona.
- `20261122000001_verify_login_rpc.sql` = `fn_v3_verify_login` RPC —
  replicira 1:1 verdict edge funkcije verify-login (0X phone canonical +
  device-slot/PIN logika; interni helper fn_v3_phone_canonical_local,
  EXECUTE samo service_role). Razlog: edge-runtime poziv kroz Funnel kosta
  ~1-4s (cold start i vise) i znao je da pojede ceo 15s startup timeout na
  welcome ekranu pa se auto-login tiho gubio; RPC je ~0.1-0.5s. App
  (verifyLogin u v3_closed_auth_service) zove RPC-first, edge invoke je
  fallback (15s timeout). Ako se device-slot/PIN pravila menjaju — menjati
  NA OBA mesta (RPC + edge index.ts).
- `20261122000002_mutation_rpcs.sql` = mutacioni RPC sloj — ubrzanje UI
  akcija (Funnel RTT ~250-500ms × 4-9 sekvencijalnih REST poziva -> 1 poziv).
  Sve funkcije SECURITY DEFINER + EXECUTE anon/authenticated; interni
  helperi (fn_v3_nenaplacene_list / fn_v3_consume_nenaplacene /
  fn_v3_apply_preneti_visak) REVOKE-ovani sa PUBLIC/anon/authenticated.
  - `fn_v3_putnik_otkazi` — putnik otkaže: zahtev->'otkazano' + operativne
    redove konteksta (count + `operativna` niz svih redova konteksta za
    keš); 'nothing_to_cancel' je idempotentno ok.
  - `fn_v3_putnik_polazak` — putnik menja polazak: reset na 'obrada' (port
    resetToObrada) + `operativna` niz; trigger 'obrada' grana ponistava
    operativne, cron process_pending_zahtevi ih ponovo uspostavlja.
  - `fn_v3_vozac_putnik_upsert` — vozač doda/pomeri putnika: stale zahtevi
    ->'otkazano' PRE primarnog 'odobreno' (trigger guši duplikate i
    upsertuje kanonski operativna red); vraca `operativna` (aktivni red) +
    `operativna_sve` (svi redovi konteksta).
  - `fn_v3_vozac_otkazi` — otkaz operativne po id-u ('already_canceled').
  - `fn_v3_pokupi` — pokupljenje + finansijska evidencija: visak trosi
    cenu, ostatak->nenaplacene; po-danu guard (vecVozioDanas/postojeća
    stavka->'skipped'). advisory lock 'fin:putnik:mesec:godina'.
  - `fn_v3_mesecna_naplata` — uplata: preneti visak->consume nenaplacene->
    append uplata->skalari iz uplate_json; advisory lock 'naplata:...'.
  - `fn_v3_pazar_sacuvaj` / `fn_v3_pazar_sync_zahtev` — merge dnevne
    stavke na FOR UPDATE mesecnom redu (sync: predao iz baze,
    bila_predaja=reblokada zavrsenog unosa).
  - `fn_v3_dodela_termina` — admin raspored: kandidati = aktivne operativne
    stavke na slotu ciji created_by je u v3_auth tip∉('','vozac'); delete
    dodele->slot upsert->bulk dodele; p_vozac_id NULL = uklanjanje.
  - GRANT anon na fn_v3_alternativa_action — app zove RPC-first (edge
    cold start 1-4s -> ~0.3s), edge invoke je fallback; device-identity
    provera je u samoj funkciji.
- App-side (isti commit): svi gornji RPC-ovi su RPC-first sa legacy REST
  fallback-om (isti pattern kao fn_v3_verify_login). Uklonjen realtime
  hook koji je na SVAKI operativna event zvao syncTerminDodelaFromSlotForRow
  (1-2 REST poziva po event-u po uredjaju) — trigger
  trg_v3_operativna_sync_dodela radi isto server-side. Uklonjen i mrtav
  _syncOperativnaAssignmentsForContext. Keš se puni iz `zahtev`/
  `operativna`/`operativna_sve`/`finansije`/`uplata` kljuceva RPC odgovora
  (osim dodele — nju drzi realtime, kao i do sada).
- `20261122000003_eta_cleanup_cron.sql` = pg_cron job `cleanup_eta_results`
  (*/5min): `DELETE v3_eta_results WHERE computed_at < now()-55min` — pre
  ovoga je retention delete postojao samo unutar v3-compute-eta poziva, pa
  su zastareli ETA redovi ostajali u tabeli zauvek kad niko ne track-uje
  (putnik video zamrznutu "za 0 min" ETA). Takodje osvezen zastareli
  COMMENT na v3_vozac_location (tick je 5s, ne 20s).
- App-side + edge (isti commit) — tracking/ETA audit fix-ovi:
  `v3RunTrackingTick` odbija GPS fix stariji od `v3TrackingMaxPositionAge`
  (30s) — getLastKnownPosition fallback je ranije upisivao staru poziciju
  kao svez; ETA compute throttle je naknadno UKLONJEN (2026-11-23) —
  `v3-compute-eta` (OSRM /trip reoptimizacija) ide na SVAKI tick (5s), FG i
  BG; no_active_slot strikes podignut 6->12 da zadrzi ~60s toleranciju;
  standstill kazna putuje u session payload-u (`standstill_seconds`) pa se
  ne resetuje na FG<->BG handoff; edge: sve eta_results select/delete
  operacije rade po SVIM duplikat slotovima (`.in(slot_id, matchingSlotIds)`)
  umesto samo activeSlot.id; resolveDriverLocation anti-spoof — payload
  koji odstupa >500m od sveze tabelske pozicije gubi prednost; sanity
  check `vozac_id` mora biti `uloga='vozac'` u v3_auth. Komentar drift:
  "T+40" -> hard-stop (3h) na svim mestima.
- `20261123000000_single_vozac_per_slot.sql` = uklanja multi-driver
  ("deljeni slot") logiku: jedan fizicki slot (datum,grad,vreme) ima
  tacno JEDNOG vozaca za sve putnike. Ranije je admin mogao pojedinacno
  dodeliti putnika drugom vozacu na istom slotu (dodela.vozac !=
  slot.vozac). Trigger `tr_v3_trenutna_dodela_normalize` sada enforce-uje
  invariant: svaka dodela dobija vozac_v3_auth_id = vlasnik slota, a
  slot_id se resolve-uje i kad je NULL (preko operativna termina ->
  fizicki kljuc) — pa ni STARE app verzije koje pisu override ne mogu da
  naprave split (trigger im tiho prepise vozac; BC putanja do prelaska
  svih uredjaja). `fn_v3_operativna_sync_dodela` ON CONFLICT vise ne cuva
  override — sync uvek pise vlasnika. Jednokratni data fix svodi
  postojece split dodele na vlasnika (0 redova na lokalu) + backfill
  slot_id. Verifikovano rollback testom T0–T4 (sync kreira sa vlasnikom,
  UPDATE/INSERT override prepisan, slot_id resolve, otkazano brise).
- Edge + app-side (isti commit): v3-auto-prepare-termins grupise po
  fizickom slotu (datum|grad|vreme — bez vozac_id u kljucu), bez merge-a
  optimized_order izmedju vozaca i bez cuvanja per-putnik override-a;
  v3-compute-eta dodela select ostaje .eq(vozac) (sesijski scope, ne
  multi-driver); v3_notify_passengers_driver_started i dalje filtrira po
  p_vozac_id (potpis zadrzan za stare build-ove), ali trigger invariant
  garantuje da sve dodele na slotu nose vlasnika — owner-ov poziv
  pokriva sve putnike slota. Admin raspored:
  uklonjen per-putnik dijalog dodele (_showDodeliVozacaDialog,
  assignPutnikOverride/clearPutnikOverride iz orchestratora,
  onDodeliVozaca callback na V3PutnikCard) — dodela vozaca je iskljucivo
  na nivou slota. Vozac screen: uklonjen _allTerminToVozac map i filteri
  "tudji putnici" — vozac vidi SVE aktivne putnike svog slota; tracking
  all-completed check-i (v3AllPassengersCompleted, tryAllPassengersCompleted)
  gledaju ceo fizicki slot bez otherVozacTerminIds izuzetaka.
  V3StatusPolicy.sharedVozacIdForTermin/assignedVozacIdForPutnik zadrzani
  kao read-resolution helperi (sada uvek resolvuju na vlasnika slota).
  flutter analyze: 0 issues na svim dirnutim fajlovima.
- `20261123000001_tracking_push_fixes.sql` = tracking/push audit fix-ovi:
  `v3_notify_passengers_driver_started` dobija 3 nova parametra
  (p_device_token/p_hardware_id/p_installation_id) + device-identity gate
  isti OR-pattern kao fn_v3_alternativa_action (identity protiv VOZAC-evih
  v3_auth slotova) — ranije je anon RPC bez identiteta mogao tudji termin da
  claim-uje i posalje prerani "vozac je krenuo" push; stari 4-param potpis
  je DROP-ovan (stare app verzije dobijaju ok=false/unauthorized — tracking
  im radi, samo driver-started push ne izlazi dok se ne azuriraju).
  `notify_push`: `(payload_data->>'data_only')::boolean` zamenjen sigurnim
  `= 'true'` poredjenjem (cast je bacao exception za ne-boolean ulaz pa se
  push tiho gubio kroz WHEN OTHERS). Primenjeno docker exec psql +
  schema_migrations insert + NOTIFY pgrst 'reload schema'.
- App-side (isti commit): activateSlotWithRetry prosledjuje
  installationId/hardwareId (V3DeviceIdentityService.getDeviceIds,
  kesirano po sesiji); tryRestoreFromSession _setRunning(true) TEK POSLE
  activate (ranije ostajao "running" bez engine-a kad Supabase nije spreman
  — catch sada radi _clearLocalSessionState, prefs sesija ostaje za retry
  na sledecem resume-u); BG doTick tickInFlight guard (ticker timeout ne
  otkazuje zaglavljen tick — bez guard-a paralelni upisi/compute-eta);
  BG self-heal pause re-check — svaki 6. tick cita ticks_paused iz prefs
  (servicePipe moze dropovati pauseTicks event); onIosBackground ucitava
  standstill_seconds iz sesije i persist-uje nazad; _v3TerminHasActivePassengers
  dobija server-side .eq('datum') (max_rows=1000 mogao tiho odseci termin);
  V3VremeDolaskaWidget ETA live gate — prikazuje samo dok je
  v3_vozac_location.updated_at < 120s (ranije "za 0 min" do 55min retention
  posle prestanka trackinga); send-push-notification collapse_key po
  zahtev_id/entity_id/type umesto 'default' (offline uredjaj — weather
  alert je mogao pregaziti driver_started), HMS data_only komentar
  (nema HmsMessageService — sistemski banner jedini put); obrisan mrtav
  v3_driver_push_notification_service.dart. flutter analyze: 0 issues.
- `20261124000000_gorivo_pregled_rpc.sql` = `fn_v3_gorivo_pregled` (8
  timestamptz granica perioda -> jsonb sa svim agregatima): kartica
  "potrosnja goriva po periodima" je po refresh-u zvala 6 RPC-ova kroz
  Funnel (4× sum_potrosnja + 2× dnevni_prosek — RTT ~250-500ms + TLS
  handshake po pozivu, baza trivijalna). Granice dolaze iz app-a
  (V3BelgradeTime/V3DanHelper — bez dupliranja DST/nedelja logike u SQL);
  proseci se povlace iz postojecih v3_gorivo_dnevni_prosek(_uplata).
  GRANT EXECUTE anon+authenticated. Primenjeno docker exec psql +
  schema_migrations insert + NOTIFY pgrst 'reload schema'.
- App-side (isti commit): V3GorivoService.getPotrosnjaPregled je
  RPC-first (fn_v3_gorivo_pregled) sa legacy 6-RPC fallback-om +
  memoizacija po tableRevision('v3_gorivo') — istorija se menja samo
  kroz trigger na v3_gorivo pa isti revision = isti podaci (in-flight
  dedupe). _FuelConsumptionPeriodCard dobija initialData iz
  potrosnjaPregledCached — bez spinnera pri refetch-u. flutter analyze:
  0 issues.
- App-side (2026-11-24): `_handlePickup` na V3PutnikCard je sada
  optimisticki — pokupljen_at/pokupljen_by se odmah upisu u
  operativnaNedeljaCache pa kartica reaguje trenutno (Funnel RTT
  ~0.6-0.9s po pozivu, mereno curl-om; fn_v3_pokupi u bazi 20-50ms warm /
  do ~600ms cold po pg_stat_statements). Mrezni deo (RPC -> legacy REST
  fallback) ide u pozadini sa timeout-ima (15s / 45s) — ranije poziv nije
  imao timeout pa je zaglavljen TCP drzao _globalProcessingLock i tapovi
  na druge kartice su se tiho odbacivali. Lock se otpusta posle
  optimistickog dela; pri totalnom neuspehu se vraca originalni red +
  error snackbar. flutter analyze: 0 issues.
- App-side (isti commit, 2026-11-24 — vozac/profil optimizacije):
  `_handleOtkazivanje` (vozac otkazuje putnika) isto optimisticki
  (otkazano_at odmah u kes, mrezni update u pozadini, revert pri gresci);
  nedostajuci .timeout(15s) dodat na fn_v3_mesecna_naplata,
  fn_v3_vozac_putnik_upsert, fn_v3_pazar_sacuvaj, fn_v3_pazar_sync_zahtev
  i fn_v3_dodela_termina RPC pozive (isti "half-open TCP" rizik);
  _odgovoriNaPonudu (alternativa/mesto_ponuda) paralelno dovlaci
  getBestToken/getHardwareId/getInstallationId preko record .wait —
  ranije serijski, getBestToken zna da pojede sekunde u 10-min prozoru
  ponude; V3DeviceIdentityService.getDeviceIds isto paralelno; busy
  indikatori (_pendingActionContexts na celiji rasporeda,
  _pendingPonudaZahtevi na banneru ponude) sada stvarno re-renderuju
  (safeSetState — ranije se flag menjao bez rebuild-a pa se spinner
  nikad nije video). flutter analyze: 0 issues.
- App-side (isti commit, 2026-11-24 — "smooth" animacije na kljucnim
  ekranima): novi `lib/widgets/v3_fade_slide_in.dart` — V3FadeSlideIn
  (TweenAnimationBuilder + Interval, entrance se ne ponavlja na realtime
  rebuild-ima; delay za staggered cascade). V3VozacScreen: ListView.builder
  -> SliverAnimatedList — _animPutnici + _syncAnimatedPutnici diff (kljuc
  'e:<operativna_id>'/'p:<putnik_id>'; insert=expand+slide+fade,
  remove=collapse+fade+slide levo, move=remove+insert) + reset na promenu
  slota (datum|grad|vreme) sa cascadeDelays mapom (index*55ms, cap 8).
  V3PutnikProfilScreen: _animatedSection (AnimatedCrossFade, child se
  montira tek kad postane vidljiv) na vreme-dolaska/mesto_ponuda/
  alternativa + V3FadeSlideIn stagger na ostalim sekcijama. Navigacija:
  V3SmoothPageRoute (slide 5% + fade, 320ms) u V3NavigationUtils —
  pushScreen/pushReplacement/pushAndRemoveUntil + svi direktni
  MaterialPageRoute pozivi konvertovani (logout->welcome, statistika,
  finansije, putnici, deep-link u main.dart). flutter analyze: 0 issues.
- App-side (isti commit, 2026-11-24 — putnik flow audit): popunjeni
  preostali mrezni pozivi bez timeout-a u login/profil toku (isti
  "half-open TCP drzi _isLoading zauvek" rizik): findAuthIdByPhone,
  verifyPin, changePin (v3-pin-auth), getActiveById x3,
  getVozacByIdDirect, addUpdatePutnik i writeLoginColumns u
  v3_sms_login_screen, getActiveById/getVozacByIdDirect u
  restore*FromManualSmsSession — svi na 15s (addUpdatePutnik 20s),
  greska propusta se u postojece catch blokove. Push alternativa/mesto
  akcija (_executeAlternativaEdgeAction u main.dart) sada RPC-first
  (fn_v3_alternativa_action, 15s) + edge fallback (20s) — isti pattern
  kao in-app odgovor; ranije samo edge bez timeout-a. _odgovoriNaPonudu:
  optimisticki zahtevi-cache upis po ok:true (preslikana semantika
  servera: accept->'odobreno'+polazak_at=selected_time+clear flags,
  reject mesto->mesto_ponuda=false/odbijena, reject alternativa->
  'odbijeno'+clear) — banner nestaje odmah umesto da ceka realtime.
  V3PutnikProfilScreen.isOpen static + guard u
  _openPutnikProfilFromNotification — tap na notifikaciju vise ne
  slaze dupli profil ekran (instance dele iste V3StreamUtils kljuceve
  pa bi se donja prestala osvežavati). flutter analyze: 0 issues.
- `20261124000001_tracking_stall_watchdog.sql` = pg_cron job
  `tracking_stall_watchdog` (*/2min) + kolona
  `v3_trenutna_dodela_slot.tracking_stall_notified_at` (throttle 10min po
  slotu, auto-NULL kad lokacija osvezi). `fn_v3_tracking_stall_watchdog`
  (SECURITY DEFINER, EXECUTE revoke-an sa PUBLIC/anon/authenticated) salje
  `tracking_stalled` push vozacu kad: slot ima tracking_started_at u
  poslednja 4h + termin ima aktivnih putnika + njegova vozac_location
  zastarela >3min. Lokacija je po VOZACU pa svez tick sa bilo kog slota
  ucutkuje watchdog za sve njegove slotove. Razlog: potvrdjeno da tickovi
  na zakljucanom telefonu umiru (14-22min tišine tokom vožnje) — FGS se
  ne podigne ili ga ubije OEM/doze; server detektuje zamrzak i budi app
  kroz high-priority push (vozac tapne ili se FGS sam oživi).
- App-side (isti commit, 2026-11-24 — tracking stall self-heal):
  `tracking_stalled` push u _handleIncomingFcmMessage (FCM BG + FG) poziva
  _reviveBackgroundTrackingService — best-effort startService/invoke
  'startTracking' iz prefs sesije (skip kad ticks_paused=true); tap na
  notifikaciju samo otvara app (initialize/tryRestoreFromSession obnavlja).
  BG isolate self-heal: expiryWatchdog (zivi i dok je ticker pauziran) na
  svaki minut proverava prefs — ticker==null + sesija aktivna +
  ticks_paused=false -> maybeResumeTicks restartuje ticker (pokriva
  dropovani 'startTracking' invoke; ranije self-heal postojao samo u
  suprotnom smeru). _startBgServiceVerified: posle startService() poll
  isRunning do 2s + retry — na nekim OEM-ima FGS tiho propadne pa se
  ranije nastavljalo kao da radi. Battery-optimization prompt za vozace:
  timestamp umesto bool — re-prompt na 24h dok je app optimizovan (ranije
  jednom po instalaciji pa je odbijanje bilo trajno). flutter analyze:
  0 issues.
- Edge fix (2026-11-24, GPS tracking test): `v3-compute-eta` sanity check
  je odbijao sve sto nije `uloga='vozac'` ('not_a_driver') — Bojan i
  review nalozi su `uloga='admin'`/`tip='vozac'` i vaze kao vozaci na
  slotovima, pa njihovi putnici NIKAD nisu dobijali ETA. Sada prolazi i
  `tip='vozac'`. Testirano end-to-end (Lazar Gavrilovic na BC 12:00,
  simulirani tickovi preko Kong :54321): eta_results ok, anti-spoof
  (>500m divergence -> table loc) ok, driver_started identity gate ok.

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

## Huawei AppGallery (status 2026-11-22)

- `huawei-mcp/` — lokalni MCP server sa Connect API tool-ovima
  (release status, app-info, compile status, generic `huawei_api_request`).
  Registrovan u `~/.codeium/windsurf/mcp_config.json`. Kredencijali se
  citaju iz `Desktop/production final/huawei/agc-apiclient-*.json` +
  `HUAWEI.txt` (client_id `1850740994484473152`, app `116046535`,
  package `com.gavra013.gavra_android`). Napomena: Huawei WAF daje 502
  na node-fetch — koristi se native fetch + JSON body (kao
  `scripts/huawei_publish.sh`).
- AppGallery kanal je do 11-2026 bio mrtav: 0 HMS korisnika u bazi
  (`push_token_hms`/`provider='hms'` nigde), ~13 instalacija u 18 meseci,
  0 store impresija — objavljena je samo za RS (`publishCountry: "RS"`),
  web store je ne indeksira, vidljiva je samo kroz direktni link
  `appgallery.huawei.com/app/C116046535` na uređaju sa region=RS.
- Verzija 6.0.632 (on-shelf 19.11) bundle-uje STARI cloud `.env` —
  Huawei review uređaj je pisao u cloud bazu. Kanal trazi "zive" verzije
  tek od build-ova posle azuriranja `APP_ENV_BASE64` secreta (19.11).
- 6.0.637 submit-ovana preko CI 21.11 ali je release poništen 22.11
  (~00:07, releaseState=11 "release canceled").
- 6.0.640 submit-ovana 22.11 ~14:18 (releaseState=5 "pending update
  review") — prvi AppGallery build sa lokalnim `.env`. CI:
  `gh workflow run production-release.yml -f target=huawei` (bump-uje
  pubspec za sve; `both`/`android`/`ios` targeti SKIP-uju huawei job).
- Reports API: `GET connect-api.cloud.huawei.com/api/report/
  distribution-operation-quality/v1/appDownloadExport/{appId}
  ?language=en-US&startTime=YYYYMMDD&endTime=YYYYMMDD` → fileURL CSV
  (limit 360 dana po pozivu). app-info radi samo na glavnom (CN) domenu
  — DRE/DRA endpointi vracaju prazno.
- releaseState decode: 0 released, 3 releasing, 4 reviewing, 5 pending
  update review, 7 draft, 8 update rejected, 11 release canceled.
