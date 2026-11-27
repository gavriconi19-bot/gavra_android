// @ts-nocheck
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fetchOsrmWithRetry } from "../_shared/osrm_fetch.ts";

const jsonHeaders = { "Content-Type": "application/json; charset=utf-8" };

/// Koliko dugo se poslednji ETA red čuva u bazi kada vozač prestane da šalje
/// tickove (npr. ugasio app). Putnik i dalje vidi poslednju poznatu ETA.
/// Nezavisno od tracking prozora (T-15..T+3h). Brisanje radi isključivo pg_cron
/// job `cleanup_eta_results` (svakih 5 min) — edge ga ne radi na svaki poziv.
/// Uskladiti sa etaRetentionDuration u lib/globals.dart.

/// Maksimalna starost lokacije vozača u `v3_vozac_location` pre nego što se
/// smatra zastarelom za NOVI live ETA — samo fallback kada tick NE pošalje
/// lat/lng u payload-u. Tracking tick šalje lokaciju svakih 5s.
const DRIVER_LOCATION_MAX_AGE_MS = 130 * 1000;

/// Operativni region (Bela Crkva / Vršac + okolina) — OSRM mapa pokriva samo
/// ovo područje, pa koordinate van box-a nisu rutabilne. Dodatno: endpoint
/// nema user-JWT (app koristi anon key + custom PIN), pa je ovo i jedina
/// zaštita od očiglednog spoofing-a driver lokacije kroz payload.
/// Uskladiti sa `v3IsInOperatingRegion` u v3_tracking_config.dart.
const REGION_LAT_MIN = 44.5;
const REGION_LAT_MAX = 45.5;
const REGION_LNG_MIN = 20.6;
const REGION_LNG_MAX = 21.9;

function inOperatingRegion(lat: number, lng: number): boolean {
  return (
    lat >= REGION_LAT_MIN && lat <= REGION_LAT_MAX &&
    lng >= REGION_LNG_MIN && lng <= REGION_LNG_MAX
  );
}

/// OSRM retry konfiguracija
const OSRM_MAX_RETRIES = 3;
const OSRM_BASE_DELAY_MS = 1000;
const OSRM_REQUEST_TIMEOUT_MS = 12000;
/// OSRM /trip endpoint po default-u odbija vise od 100 waypoint-a
const OSRM_MAX_WAYPOINTS = 100;
/// Minimalni razmak između dva OSRM /trip compute-a za istog vozača —
/// između njih tick ide "cheap path": eta redovi se jeftino osveže
/// (preostali travel + svez standstill) bez reoptimizacije rute.
/// 5s = efektivno svaki tick (kao pre uvođenja route cache-a) — cheap
/// path ostaje kao safety net ako tickovi dođu brže od intervala.
const OSRM_MIN_INTERVAL_MS = 5 * 1000;

type ComputeEtaPayload = {
  vozac_id?: string;
  grad?: string;
  vreme?: string;
  datum_iso?: string;
  /** Svež GPS iz istog tick-a (preferiran nad v3_vozac_location). */
  lat?: number | string;
  lng?: number | string;
};

type PassengerEntry = {
  putnik_id: string;
  termin_id: string;
  lat: number;
  lng: number;
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function coordStr(lat: number, lng: number): string {
  return `${lng},${lat}`;
}

/// Haversine razdaljina u metrima — za proveru konzistentnosti lokacije.
function haversineMeters(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function normalizeTime(value: unknown): string {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  const timePart = raw.includes("T") ? raw.split("T")[1] : raw;
  const parts = timePart.split(":");
  if (parts.length >= 2) {
    const hour = parts[0].padStart(2, "0");
    const minute = parts[1].padStart(2, "0");
    return `${hour}:${minute}`;
  }
  return timePart.slice(0, 5);
}

function normalizeDateIso(value: unknown): string {
  const raw = String(value ?? "").trim();
  if (!raw) return "";
  if (raw.includes("T")) return raw.split("T")[0];
  const match = raw.match(/^(\d{4}-\d{2}-\d{2})/);
  return match?.[1] ?? "";
}

function parseCoord(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

function etaRowsFromFixedOrder(
  ordered: PassengerEntry[],
  legs: any[],
  ctx: { slotId: string; vozacId: string; now: string; standstillSeconds?: number },
): Array<{
  slot_id: string;
  termin_id: string;
  putnik_id: string;
  vozac_id: string;
  eta_seconds: number;
  travel_seconds: number;
  route_at: string;
  computed_at: string;
}> | null {
  const upsertRows: Array<{
    slot_id: string;
    termin_id: string;
    putnik_id: string;
    vozac_id: string;
    eta_seconds: number;
    travel_seconds: number;
    route_at: string;
    computed_at: string;
  }> = [];
  let cumulative = 0;
  for (let i = 0; i < ordered.length; i++) {
    const duration = Number(legs[i]?.duration ?? -1);
    if (!Number.isFinite(duration) || duration < 0) {
      // null = fatalno: preskočen leg bi umanjio ETA svima iza njega —
      // pozivalac pada na fallback (poslednji dobar order + ETA).
      console.warn(`[v3-compute-eta] leg[${i}] duration invalid: ${duration}`);
      return null;
    }
    cumulative += Math.round(duration);
    upsertRows.push({
      slot_id: ctx.slotId,
      termin_id: ordered[i].termin_id,
      putnik_id: ordered[i].putnik_id,
      vozac_id: ctx.vozacId,
      // travel_seconds = sirovi OSRM (route_at anchor); eta_seconds =
      // izvedena travel+standstill — kompatibilno sa starim citaocima.
      travel_seconds: cumulative,
      route_at: ctx.now,
      eta_seconds: cumulative + (ctx.standstillSeconds ?? 0),
      computed_at: ctx.now,
    });
  }
  return upsertRows;
}

type AuthAddressRow = {
  id: string;
  adresa_primary_bc_id: string | null;
  adresa_primary_vs_id: string | null;
  adresa_secondary_bc_id: string | null;
  adresa_secondary_vs_id: string | null;
};

function pickAdresaId(
  grad: string,
  auth: AuthAddressRow | undefined,
  koristiSekundarnu: boolean,
  overrideId: string | null,
): string | null {
  if (overrideId) return overrideId;
  if (!auth) return null;
  if (grad === "BC") {
    return (koristiSekundarnu ? auth.adresa_secondary_bc_id : auth.adresa_primary_bc_id)
      ?? auth.adresa_primary_bc_id
      ?? null;
  }
  if (grad === "VS") {
    return (koristiSekundarnu ? auth.adresa_secondary_vs_id : auth.adresa_primary_vs_id)
      ?? auth.adresa_primary_vs_id
      ?? null;
  }
  return null;
}

/// Ako dodela nema GPS, uzmi ga iz v3_operativna_nedelja + v3_auth + v3_adrese
/// (iste kolone koje već postoje) i upiši nazad u v3_trenutna_dodela.
async function fillMissingPassengerGps(
  client: ReturnType<typeof createClient>,
  activeGrad: string,
  dodelaRows: any[],
): Promise<PassengerEntry[]> {
  const result: PassengerEntry[] = [];
  const missing: Array<{ termin_id: string; putnik_id: string }> = [];

  for (const r of dodelaRows ?? []) {
    const terminId = String(r?.termin_id ?? "").trim();
    const putnikId = String(r?.putnik_v3_auth_id ?? "").trim();
    if (!terminId || !putnikId) continue;
    const lat = parseCoord(r?.adresa_gps_lat);
    const lng = parseCoord(r?.adresa_gps_lng);
    if (lat != null && lng != null) {
      result.push({ putnik_id: putnikId, termin_id: terminId, lat, lng });
    } else {
      missing.push({ termin_id: terminId, putnik_id: putnikId });
    }
  }

  if (missing.length === 0) return result;

  const terminIds = missing.map((m) => m.termin_id);
  const putnikIds = [...new Set(missing.map((m) => m.putnik_id))];

  const [{ data: operativnaRows, error: operativnaLookupError }, { data: authRows, error: authLookupError }] =
    await Promise.all([
      client
        .from("v3_operativna_nedelja")
        .select("id, adresa_override_id, koristi_sekundarnu")
        .in("id", terminIds),
      client
        .from("v3_auth")
        .select("id, adresa_primary_bc_id, adresa_primary_vs_id, adresa_secondary_bc_id, adresa_secondary_vs_id")
        .in("id", putnikIds),
    ]);

  if (operativnaLookupError || authLookupError) {
    console.warn(
      `[v3-compute-eta] missing_gps lookup error op=${operativnaLookupError?.message ?? "ok"} ` +
        `auth=${authLookupError?.message ?? "ok"} unresolved=${missing.length}`,
    );
  }

  const operativnaById = new Map((operativnaRows ?? []).map((row: any) => [String(row.id), row]));
  const authById = new Map((authRows ?? []).map((row: any) => [String(row.id), row as AuthAddressRow]));

  const adresaIds: string[] = [];
  const missingToAdresa = new Map<string, string>();
  for (const m of missing) {
    const op = operativnaById.get(m.termin_id);
    const adresaId = pickAdresaId(
      activeGrad,
      authById.get(m.putnik_id),
      op?.koristi_sekundarnu === true,
      op?.adresa_override_id ? String(op.adresa_override_id) : null,
    );
    if (!adresaId) continue;
    adresaIds.push(adresaId);
    missingToAdresa.set(`${m.termin_id}:${m.putnik_id}`, adresaId);
  }

  if (adresaIds.length === 0) {
    console.warn(`[v3-compute-eta] missing_gps unresolved=${missing.length} no_adresa_id`);
    return result;
  }

  const { data: adresaRows, error: adresaLookupError } = await client
    .from("v3_adrese")
    .select("id, gps_lat, gps_lng")
    .in("id", [...new Set(adresaIds)]);

  if (adresaLookupError) {
    console.warn(`[v3-compute-eta] adrese lookup error: ${adresaLookupError.message}`);
  }

  const gpsByAdresa = new Map<string, { lat: number; lng: number }>();
  for (const a of adresaRows ?? []) {
    const lat = parseCoord(a?.gps_lat);
    const lng = parseCoord(a?.gps_lng);
    if (lat == null || lng == null) continue;
    gpsByAdresa.set(String(a.id), { lat, lng });
  }

  const updates: Array<{ termin_id: string; lat: number; lng: number }> = [];
  for (const m of missing) {
    const adresaId = missingToAdresa.get(`${m.termin_id}:${m.putnik_id}`);
    if (!adresaId) continue;
    const gps = gpsByAdresa.get(adresaId);
    if (!gps) continue;
    result.push({ putnik_id: m.putnik_id, termin_id: m.termin_id, lat: gps.lat, lng: gps.lng });
    updates.push({ termin_id: m.termin_id, lat: gps.lat, lng: gps.lng });
  }

  for (const u of updates) {
    await client
      .from("v3_trenutna_dodela")
      .update({ adresa_gps_lat: u.lat, adresa_gps_lng: u.lng })
      .eq("termin_id", u.termin_id);
  }

  console.log(
    `[v3-compute-eta] gps_filled from_adrese=${updates.length} still_missing=${missing.length - updates.length}`,
  );
  return result;
}

/// Trenutno vreme u Europe/Belgrade kao "YYYY-MM-DDTHH:mm:ss" — poredi se
/// leksikografski sa polaskom (obe strane su Belgrade lokalno vreme).
function belgradeNowString(d: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Belgrade",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}T${get("hour")}:${get("minute")}:${get("second")}`;
}

/// Cap standstill kazne (20 min). Tracking može ostati upaljen dok vozač
/// pauzira — bez cap-a ETA bi rastao neograničeno.
const STANDSTILL_PENALTY_MAX_SECONDS = 20 * 60;

/// Standstill pragovi — isti kao u ranijoj klijentskoj verziji:
/// speed < 3.6 km/h primarno, distance < 15m fallback kad speed nije
/// validan; elapsed po tick-u clamp-ovan na 30s da preskočeni tickovi
/// (stale/out_of_region) ne "dokažu" stajanje.
const STANDSTILL_SPEED_KMH = 3.6;
const STANDSTILL_MOVED_M = 15;
const STANDSTILL_ELAPSED_CAP_S = 30;

/// Standstill (ETA penalty) se akumulira SERVER-SIDE u kolonama
/// standstill_* na v3_vozac_location — ranije je brojač putovao kroz
/// SharedPreferences session payload između FG i BG isolate-a (4 parse
/// mesta + persist na svaki tick). Edge poziv ide na svaki tick, pa je
/// ovo prirodno mesto. Zove se pre OSRM poziva da se kazna upiše i kad
/// kasniji koraci padnu na fallback.
async function computeAndPersistStandstill(
  client: ReturnType<typeof createClient>,
  vozacId: string,
  lat: number,
  lng: number,
  departureReached: boolean,
): Promise<number> {
  const nowMs = Date.now();
  const { data: row } = await client
    .from("v3_vozac_location")
    .select("speed_kmh, standstill_seconds, standstill_tick_at, standstill_prev_lat, standstill_prev_lng")
    .eq("vozac_id", vozacId)
    .maybeSingle();

  let standstill = 0;
  if (departureReached && row) {
    const prevTickMs = row.standstill_tick_at ? Date.parse(String(row.standstill_tick_at)) : NaN;
    const elapsed = Number.isFinite(prevTickMs)
      ? Math.min(Math.max((nowMs - prevTickMs) / 1000, 0), STANDSTILL_ELAPSED_CAP_S)
      : 0;
    const speed = parseCoord(row.speed_kmh);
    let standing: boolean;
    if (speed != null) {
      standing = speed < STANDSTILL_SPEED_KMH;
    } else {
      const plat = parseCoord(row.standstill_prev_lat);
      const plng = parseCoord(row.standstill_prev_lng);
      standing = plat != null && plng != null && haversineMeters(lat, lng, plat, plng) < STANDSTILL_MOVED_M;
    }
    standstill = standing
      ? Math.min(Math.round((Number(row.standstill_seconds) || 0) + elapsed), STANDSTILL_PENALTY_MAX_SECONDS)
      : 0;
  }

  await client.from("v3_vozac_location").update({
    standstill_seconds: standstill,
    standstill_tick_at: new Date(nowMs).toISOString(),
    standstill_prev_lat: lat,
    standstill_prev_lng: lng,
  }).eq("vozac_id", vozacId);

  return standstill;
}

/// Preferira lat/lng iz tick payload-a — to je isti GPS fix koji je klijent
/// u istom tick-u upisao u `v3_vozac_location` (i vec region/stale-validirao).
/// Fallback na tabelu samo kad payload nedostaje (stari klijenti).
/// Nije anti-spoof: endpoint je anon, a `v3_vozac_location` takodje moze da
/// pise anon — ovo je samo izbor svezeg izvora, ne security granica.
async function resolveDriverLocation(
  client: ReturnType<typeof createClient>,
  vozacId: string,
  payloadLat: unknown,
  payloadLng: unknown,
): Promise<{ lat: number; lng: number; source: "payload" | "table" } | null> {
  const pLat = parseCoord(payloadLat);
  const pLng = parseCoord(payloadLng);
  if (pLat != null && pLng != null) {
    if (inOperatingRegion(pLat, pLng)) {
      return { lat: pLat, lng: pLng, source: "payload" };
    }
    console.warn(`[v3-compute-eta] payload location out_of_region ${pLat},${pLng}`);
  }

  const { data: row, error } = await client
    .from("v3_vozac_location")
    .select("lat, lng, updated_at")
    .eq("vozac_id", vozacId)
    .maybeSingle();

  if (error || !row) return null;
  const lat = parseCoord(row.lat);
  const lng = parseCoord(row.lng);
  const ts = typeof row.updated_at === "string" ? Date.parse(row.updated_at) : NaN;
  if (lat == null || lng == null || !Number.isFinite(ts)) return null;
  if (!inOperatingRegion(lat, lng)) {
    console.warn(`[v3-compute-eta] table location out_of_region ${lat},${lng}`);
    return null;
  }
  const ageMs = Date.now() - ts;
  if (ageMs > DRIVER_LOCATION_MAX_AGE_MS) {
    console.warn(`[v3-compute-eta] driver location stale ageMs=${ageMs} max=${DRIVER_LOCATION_MAX_AGE_MS}`);
    return null;
  }
  return { lat, lng, source: "table" };
}

/// Fetch sa eksponencijalnim backoff retry-om.
/// HTTP/1.1 only: Deno default (HTTP/2 ALPN) često pada na Tailscale Funnel sa
/// "tls handshake eof" iz Supabase edge runtime-a.
async function fetchWithRetry(url: string, maxRetries: number = OSRM_MAX_RETRIES): Promise<Response> {
  return await fetchOsrmWithRetry(url, {
    maxRetries,
    timeoutMs: OSRM_REQUEST_TIMEOUT_MS,
    baseDelayMs: OSRM_BASE_DELAY_MS,
    userAgent: "gavra-v3-compute-eta/1.0",
  });
}

/// Vraća fallback response sa postojećim ETA redovima i poslednjim poznatim
/// optimized_order za ovog vozača.
async function buildOsrmFallbackResponse(
  client: ReturnType<typeof createClient>,
  slotIds: string[],
  vozacId: string,
  reason: string,
  extra: Record<string, unknown> = {},
): Promise<Response> {
  const { data: existingEtaRows } = await client
    .from("v3_eta_results")
    .select("termin_id, putnik_id, eta_seconds, optimized_order")
    .in("slot_id", slotIds)
    .eq("vozac_id", vozacId);

  const etaRows = (existingEtaRows ?? [])
    .map((r: any) => ({
      termin_id: String(r?.termin_id ?? ""),
      putnik_id: String(r?.putnik_id ?? ""),
      eta_seconds: Number(r?.eta_seconds),
    }))
    .filter((r) => r.termin_id.length > 0 && r.putnik_id.length > 0 && Number.isFinite(r.eta_seconds));

  const existingOrder = Array.isArray((existingEtaRows ?? [])[0]?.optimized_order)
    ? ((existingEtaRows ?? [])[0].optimized_order as unknown[]).filter((id): id is string => typeof id === "string" && id.length > 0)
    : [];

  return json(200, {
    ok: true,
    fallback: true,
    reason,
    updated: etaRows.length,
    eta_results: etaRows,
    optimized_order: existingOrder,
    ...extra,
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json(200, { ok: false, reason: "method_not_allowed" });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? "";
    const osrmBaseUrl = Deno.env.get("OSRM_BASE_URL")?.trim() ?? "";

    if (!supabaseUrl || !serviceRoleKey) {
      return json(200, { ok: false, reason: "missing_supabase_credentials" });
    }
    if (!osrmBaseUrl) {
      return json(200, { ok: false, reason: "missing_osrm_config" });
    }

    const client = createClient(supabaseUrl, serviceRoleKey);

    const payload = (await req.json()) as ComputeEtaPayload;
    const vozacId = String(payload.vozac_id ?? "").trim();
    const activeGrad = String(payload.grad ?? "").trim().toUpperCase();
    const activeVreme = normalizeTime(payload.vreme);
    const activeDatumIso = normalizeDateIso(payload.datum_iso);

    console.log(`[v3-compute-eta] payload received: ${JSON.stringify({
      vozac_id: vozacId ? `${vozacId.slice(0, 8)}…` : "",
      grad: activeGrad,
      vreme: activeVreme,
      datum_iso: activeDatumIso,
      has_lat: payload.lat != null,
      has_lng: payload.lng != null,
    })}`);

    if (!vozacId) {
      return json(200, { ok: false, reason: "invalid_payload", detail: "missing vozac_id" });
    }
    if (!activeGrad || !activeVreme || !activeDatumIso) {
      return json(200, {
        ok: false,
        reason: "invalid_payload",
        detail: "missing grad, vreme or datum_iso",
      });
    }

    // Sanity: vozac_id mora biti nalog koji sme da vozi — endpoint nema auth
    // pa bar odbijamo pozive za nepostojeće/putnik naloge pre skupljeg rada.
    // 'admin' uloga (Bojan, review nalozi) vozi slotove — tip='vozac'.
    const { data: vozacRow } = await client
      .from("v3_auth")
      .select("id, uloga, tip")
      .eq("id", vozacId)
      .maybeSingle();
    const canDrive = vozacRow &&
      (String(vozacRow.uloga ?? "") === "vozac" || String(vozacRow.tip ?? "") === "vozac");
    if (!canDrive) {
      return json(200, { ok: false, reason: "not_a_driver" });
    }

    // Standstill kazna se NE čita iz payload-a — akumulira se server-side
    // u v3_vozac_location (vidi computeAndPersistStandstill), posle provere
    // da je vozač stvarno krenuo (polazak u Belgrade lokalnom vremenu).
    const polazakLocal = `${activeDatumIso}T${activeVemme}:00`;
    const departureReached = belgradeNowString() >= polazakLocal;

    // ETA retention (55 min) brise pg_cron cleanup_eta_results — ovde se ne radi
    // da ne dodajemo jos jedan delete po tick-u. Poslednja ETA i dalje ostaje
    // dostupna putniku do cron brisanja.

    // 1. Dohvati aktivan SLOT (v3_trenutna_dodela_slot) po grad+datum+vreme.
    //    Fizički ključ slota (jedan vozač po slotu — migracija 20261123000000).
    const { data: slotRows, error: slotError } = await client
      .from("v3_trenutna_dodela_slot")
      .select("id, vreme, vozac_v3_auth_id, optimized_order")
      .eq("grad", activeGrad)
      .eq("datum", activeDatumIso);

    if (slotError) {
      return json(200, { ok: false, reason: "slot_lookup_error", warning: slotError.message });
    }

    const matchingSlots = (slotRows ?? []).filter((s: any) => normalizeTime(s.vreme) === activeVreme);
    if (matchingSlots.length === 0) {
      console.warn(`[v3-compute-eta] no_active_slot grad=${activeGrad} vreme=${activeVreme} datum=${activeDatumIso}`);
      return json(200, { ok: false, reason: "no_active_slot" });
    }

    // Više redova (format time vs text): preferiraj slot sa putnicima ovog vozača.
    // PK v3_trenutna_dodela je termin_id — tabela NEMA kolonu `id`.
    let activeSlot = matchingSlots[0];
    if (matchingSlots.length > 1) {
      for (const candidate of matchingSlots) {
        const { count } = await client
          .from("v3_trenutna_dodela")
          .select("termin_id", { count: "exact", head: true })
          .eq("slot_id", candidate.id)
          .eq("vozac_v3_auth_id", vozacId);
        if ((count ?? 0) > 0) {
          activeSlot = candidate;
          break;
        }
      }
      console.warn(
        `[v3-compute-eta] multiple slots for slotKey=${activeGrad} ${activeVreme}: ${matchingSlots.length}, using=${activeSlot.id}`,
      );
    }
    const matchingSlotIds = matchingSlots
      .map((s: any) => String(s?.id ?? "").trim())
      .filter((id: string) => id.length > 0);

    // 2a. Lokacija: payload (isti tick) > sveža tabela.
    const driverLocation = await resolveDriverLocation(client, vozacId, payload.lat, payload.lng);
    if (!driverLocation) {
      console.warn(`[v3-compute-eta] no_driver_location vozac=${vozacId.slice(0, 8)}`);
      return json(200, { ok: false, reason: "no_driver_location" });
    }
    const driverLat = driverLocation.lat;
    const driverLng = driverLocation.lng;

    // Standstill: akumulacija + persist PRE citanja putnika — upisuje se i
    // kad OSRM padne na fallback, a stari klijenti (koji jos salju
    // standstill_seconds u payload-u) dobijaju istu kaznu bez izmene.
    const standstillPenalty = await computeAndPersistStandstill(
      client,
      vozacId,
      driverLat,
      driverLng,
      departureReached,
    );

    const now = new Date().toISOString();

    // 1.5. Putnici ovog vozača na slotu (jedan vozač po slotu — filter po
    // vozaču je i dalje sesijski scope, ne multi-driver). Ako dodela nema
    // GPS, uzmi iz adrese. Dodele mogu biti raspoređene na više
    // format-duplikata istog fizičkog slota (vreme "15:25" vs "15:25:00")
    // — .eq() na samo activeSlot.id bi tiho isključio putnike sa ostalih
    // duplikata.
    const { data: dodelaRows, error: dodelaError } = await client
      .from("v3_trenutna_dodela")
      .select("termin_id, putnik_v3_auth_id, adresa_gps_lat, adresa_gps_lng")
      .in("slot_id", matchingSlotIds)
      .eq("vozac_v3_auth_id", vozacId);

    if (dodelaError) {
      return json(200, { ok: false, reason: "dodela_lookup_error", warning: dodelaError.message });
    }

    const rawPassengers = await fillMissingPassengerGps(client, activeGrad, dodelaRows ?? []);

    console.log(
      `[v3-compute-eta] slot=${String(activeSlot.id).slice(0, 8)} dodela=${(dodelaRows ?? []).length} passengers=${rawPassengers.length} locSource=${driverLocation.source}`,
    );

    if ((dodelaRows ?? []).length === 0) {
      await client.from("v3_eta_results").delete().in("slot_id", matchingSlotIds).eq("vozac_id", vozacId);
      // Terminalni razlozi umesto klijentskog v3AllPassengersCompleted
      // (3 REST poziva na svaki tick): slot nije moj → tuđi slot, ne diraj;
      // nema aktivnih putnika na tom terminu → nema sta da se vozi.
      // "nema dodela, ali ima aktivnih putnika" NIJE terminalno — auto-prepare
      // moze kasniti, klijent i dalje ne sme da gasi tracking.
      const slotOwner = String(activeSlot?.vozac_v3_auth_id ?? "").trim();
      if (slotOwner !== vozacId) {
        return json(200, { ok: false, reason: "slot_not_owner" });
      }
      const { data: terminRows } = await client
        .from("v3_operativna_nedelja")
        .select("id, polazak_at, pokupljen_at, otkazano_at")
        .eq("grad", activeGrad)
        .eq("datum", activeDatumIso);
      const hasActivePassengers = (terminRows ?? []).some(
        (r: any) =>
          normalizeTime(r?.polazak_at) === activeVemme &&
          !r?.pokupljen_at &&
          !r?.otkazano_at,
      );
      if (!hasActivePassengers) {
        return json(200, { ok: true, reason: "no_active_passengers", updated: 0 });
      }
      return json(200, { ok: true, reason: "no_passengers_for_this_vozac", updated: 0 });
    }

    if (rawPassengers.length === 0) {
      return json(200, { ok: false, reason: "missing_passenger_gps", updated: 0 });
    }

    // 2. Izbaci pokupljene/otkazane
    const terminIds = rawPassengers.map((p) => p.termin_id);
    const { data: operativnaRows, error: operativnaError } = await client
      .from("v3_operativna_nedelja")
      .select("id, pokupljen_at, otkazano_at")
      .in("id", terminIds);

    if (operativnaError) {
      console.warn(`[v3-compute-eta] operativna status lookup error: ${operativnaError.message}`);
    }

    const completedTerminIds = new Set<string>(
      (operativnaRows ?? [])
        .filter((r: any) => r.pokupljen_at || r.otkazano_at)
        .map((r: any) => String(r.id)),
    );

    const remaining = rawPassengers.filter((p) => !completedTerminIds.has(p.termin_id));

    if (remaining.length === 0) {
      // Svi duplikat slotovi — redovi na drugom duplikatu ne smeju da zastanu.
      await client.from("v3_eta_results").delete().in("slot_id", matchingSlotIds).eq("vozac_id", vozacId);
      return json(200, { ok: true, reason: "no_remaining_passengers", updated: 0 });
    }

    const remainingPutnikIds = new Set<string>(remaining.map((p) => p.putnik_id));
    const { data: existingEtaRows } = await client
      .from("v3_eta_results")
      .select("slot_id, termin_id, putnik_id, eta_seconds, travel_seconds, route_at, optimized_order")
      .in("slot_id", matchingSlotIds)
      .eq("vozac_id", vozacId);
    const toDelete = (existingEtaRows ?? [])
      .map((r: any) => String(r.putnik_id ?? "").trim())
      .filter((pid: string) => pid && !remainingPutnikIds.has(pid));
    if (toDelete.length > 0) {
      await client.from("v3_eta_results").delete()
        .in("slot_id", matchingSlotIds)
        .eq("vozac_id", vozacId)
        .in("putnik_id", toDelete);
    }

    // 3. Cheap path: isti set putnika + svezi route_at → preskoči OSRM /trip.
    //    eta_seconds = preostali travel (travel_seconds - routeAge) + svez
    //    standstill; computed_at = now, pa putnicki countdown radi identično.
    //    OSRM se poziva max jednom u OSRM_MIN_INTERVAL_MS ili čim se set
    //    putnika promeni (pokupljenje/otkazivanje → nova ruta).
    const survivingRows = (existingEtaRows ?? []).filter(
      (r: any) => remainingPutnikIds.has(String(r?.putnik_id ?? "")),
    );
    const routeReady = survivingRows.length > 0 && survivingRows.every(
      (r: any) => r.travel_seconds != null && r.route_at != null,
    );
    if (routeReady) {
      const rowPutnikIds = new Set(survivingRows.map((r: any) => String(r.putnik_id)));
      const samePassengers =
        rowPutnikIds.size === remainingPutnikIds.size &&
        [...remainingPutnikIds].every((id) => rowPutnikIds.has(id));
      const routeAtMs = Math.max(
        ...survivingRows
          .map((r: any) => Date.parse(String(r.route_at)))
          .filter((ms: number) => Number.isFinite(ms)),
      );
      const routeAgeMs = Number.isFinite(routeAtMs) ? Math.max(0, Date.now() - routeAtMs) : Infinity;
      if (samePassengers && routeAgeMs <= OSRM_MIN_INTERVAL_MS) {
        // termin_id iz `remaining` (prvi termin tog putnika) — drži cache
        // ključ termin:putnik svežim i bez OSRM poziva.
        const firstTerminByPutnik = new Map<string, string>();
        for (const p of remaining) {
          if (!firstTerminByPutnik.has(p.putnik_id)) firstTerminByPutnik.set(p.putnik_id, p.termin_id);
        }
        const nowCheap = new Date().toISOString();
        const cheapRows = survivingRows.map((r: any) => {
          const putnikId = String(r.putnik_id);
          const travelRemaining = Math.max(
            0,
            Math.round(Number(r.travel_seconds) - routeAgeMs / 1000),
          );
          return {
            slot_id: String(r.slot_id),
            termin_id: firstTerminByPutnik.get(putnikId) ?? String(r.termin_id),
            putnik_id: putnikId,
            vozac_id: vozacId,
            travel_seconds: Number(r.travel_seconds),
            route_at: String(r.route_at),
            eta_seconds: travelRemaining + standstillPenalty,
            computed_at: nowCheap,
            optimized_order: Array.isArray(r.optimized_order) ? r.optimized_order : [],
          };
        });
        const { error: cheapError } = await client
          .from("v3_eta_results")
          .upsert(cheapRows, { onConflict: "slot_id,putnik_id" });
        if (!cheapError) {
          const order = Array.isArray(survivingRows[0]?.optimized_order)
            ? survivingRows[0].optimized_order
            : [];
          console.log(
            `[v3-compute-eta] cheap tick vozac=${vozacId.slice(0, 8)} rows=${cheapRows.length} routeAge=${Math.round(routeAgeMs / 1000)}s`,
          );
          return json(200, {
            ok: true,
            updated: cheapRows.length,
            eta_results: cheapRows.map((r: any) => ({
              termin_id: r.termin_id,
              putnik_id: r.putnik_id,
              eta_seconds: r.eta_seconds,
            })),
            optimized_order: order,
          });
        }
        console.warn(`[v3-compute-eta] cheap upsert error: ${cheapError.message} — OSRM fallback`);
      }
    }

    // 4. ETA: OSRM /trip — reoptimizacija preostalih putnika (max 1/30s).
    const destLat = activeGrad === "BC" ? 45.118736452002345 : 44.90281796231954;
    const destLng = activeGrad === "BC" ? 21.301195520159723 : 21.424364904529384;

    const orderedPassengers = remaining;

    const waypointCount = orderedPassengers.length + 2;
    if (waypointCount > OSRM_MAX_WAYPOINTS) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_too_many_waypoints", {
        count: waypointCount,
        max: OSRM_MAX_WAYPOINTS,
      });
    }

    const osrmCoords = [
      coordStr(driverLat, driverLng),
      ...orderedPassengers.map((p) => coordStr(p.lat, p.lng)),
      coordStr(destLat, destLng),
    ].join(";");

    const osrmUrl =
      `${osrmBaseUrl}/trip/v1/driving/${osrmCoords}?source=first&destination=last&roundtrip=false&steps=false&overview=false`;

    console.log(
      `[v3-compute-eta] remaining=${remaining.length} mode=trip coords=${osrmCoords}`,
    );

    let osrmResponse: Response;
    try {
      osrmResponse = await fetchWithRetry(osrmUrl);
    } catch (e) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_fetch_error", {
        warning: e instanceof Error ? e.message : "Unknown error",
      });
    }

    if (!osrmResponse.ok) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_http_error", {
        status: osrmResponse.status,
      });
    }

    const osrmData = await osrmResponse.json();

    if (osrmData.code !== "Ok") {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_code_error", {
        code: osrmData.code,
      });
    }

    const upsertCtx = { slotId: activeSlot.id, vozacId, now, standstillSeconds: standstillPenalty };
    let upsertRows: Array<{
      slot_id: string;
      termin_id: string;
      putnik_id: string;
      vozac_id: string;
      eta_seconds: number;
      travel_seconds: number;
      route_at: string;
      computed_at: string;
      optimized_order?: unknown;
    }> = [];

    const rawWaypoints = osrmData.waypoints;
    const rawTrips = osrmData.trips;
    const expectedWaypointCount = orderedPassengers.length + 2;
    if (!Array.isArray(rawWaypoints) || rawWaypoints.length !== expectedWaypointCount) {
      console.warn(`[v3-compute-eta] waypoints mismatch: expected=${expectedWaypointCount} got=${rawWaypoints?.length}`);
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_waypoints_mismatch", {
        expected: expectedWaypointCount,
        got: rawWaypoints?.length,
      });
    }
    if (!Array.isArray(rawTrips) || rawTrips.length === 0) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_no_trips");
    }

    const legs = rawTrips[0].legs;
    if (!Array.isArray(legs)) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_no_legs");
    }

    const passengerWaypoints = rawWaypoints
      .map((waypoint: any, inputIndex: number) => ({ waypoint, inputIndex }))
      .slice(1, -1)
      .sort((a: any, b: any) => Number(a?.waypoint?.waypoint_index ?? 0) - Number(b?.waypoint?.waypoint_index ?? 0));

    const originalIndexToEntry: Record<number, PassengerEntry> = {};
    for (let i = 0; i < orderedPassengers.length; i++) {
      originalIndexToEntry[i + 1] = orderedPassengers[i];
    }

    const tripOrdered: PassengerEntry[] = [];
    for (const pw of passengerWaypoints) {
      const entry = originalIndexToEntry[Number(pw.inputIndex)];
      if (entry) tripOrdered.push(entry);
    }
    const builtRows = etaRowsFromFixedOrder(tripOrdered, legs, upsertCtx);
    if (builtRows === null) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "osrm_invalid_leg");
    }
    upsertRows = builtRows;

    // Isti putnik može imati više termina na slotu (2+ reda u dodeli) —
    // upsert sa onConflict "slot_id,putnik_id" pada na duplikatu
    // ("cannot affect row a second time") i ceo odgovor propadne.
    // Zadrži prvi (najraniji) unos po putniku.
    const seenPutnikIds = new Set<string>();
    upsertRows = upsertRows.filter((r) => {
      if (seenPutnikIds.has(r.putnik_id)) return false;
      seenPutnikIds.add(r.putnik_id);
      return true;
    });

    if (upsertRows.length === 0) {
      return await buildOsrmFallbackResponse(client, matchingSlotIds, vozacId, "no_eta_rows");
    }

    // 5. Upsert v3_eta_results — koristi slot_id za conflict resolution
    // optimized_order = putnik_id[] (usklađeno sa Flutter sort po putnik.id)
    const optimizedOrder = upsertRows.map((r) => r.putnik_id);
    const upsertRowsWithOrder = upsertRows.map((r) => ({ ...r, optimized_order: optimizedOrder }));
    const { error: upsertError } = await client
      .from("v3_eta_results")
      .upsert(upsertRowsWithOrder, { onConflict: "slot_id,putnik_id" });

    if (upsertError) {
      console.error(`[v3-compute-eta] upsert_error: ${upsertError.message}`);
      return json(200, { ok: false, reason: "upsert_error", warning: upsertError.message });
    }

    console.log(`[v3-compute-eta] ✅ vozac=${vozacId.substring(0, 8)} updated=${upsertRows.length} putnika`);
    return json(200, {
      ok: true,
      updated: upsertRows.length,
      eta_results: upsertRows.map((r) => ({ termin_id: r.termin_id, putnik_id: r.putnik_id, eta_seconds: r.eta_seconds })),
      optimized_order: optimizedOrder,
    });
  } catch (error) {
    return json(200, {
      ok: false,
      reason: "unexpected_error",
      warning: error instanceof Error ? error.message : "Unknown error",
    });
  }
});
