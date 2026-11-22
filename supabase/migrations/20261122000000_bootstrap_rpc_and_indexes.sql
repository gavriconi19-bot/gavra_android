-- 2026-11-22 — bootstrap RPC + updated_at indexi za cold-start ubrzanje.
--
-- fn_v3_bootstrap(p_phase) vraca sve bootstrap tabele kao jedan JSONB objekat
--   {table_name: [rows]} u JEDNOM round-trip-u (ranije: 16 paralelnih REST
--   zahteva kroz Tailscale Funnel, ~150-700ms svaki). Posto funkcija vraca
--   jedan red (jsonb), PostgREST max_rows (1000) vise ne sece v3_finansije.
--   Faze: 'critical' (ekrani koji gate-uju init), 'secondary' (teske tabele
--   koje stizu u pozadini), 'all' (oba odjednom — resync/backup putanja).
--
-- fn_v3_bootstrap_delta(p_watermarks) vraca samo redove novije od watermark-a
--   po tabeli — koristi se na cold startu sa perzistentim kesom i na
--   reconnect delta resync-u (jedan RPC umesto 16 REST poziva).
--
-- Slim projekcije:
--   v3_finansije  — bez broj_voznji/ime/naplatio_ime/poslednja_dopuna
--                   (verifikovano da ih app ne cita; teske *_json kolone ostaju
--                   jer ih cache potrosaci citaju).
--   v3_zahtevi    — dodati mesto_ponuda*/alternativa_offered_at/updated_by
--                   (ranije izostavljeni: cold-start putnik nije video
--                   ponudjeno mesto dok ne stigne realtime event).
--   v3_racuni     — izbacen iz bootstrapa (nista ne cita racuniCache).

CREATE OR REPLACE FUNCTION public.fn_v3_bootstrap(p_phase text DEFAULT 'all')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
  result jsonb := '{}'::jsonb;
BEGIN
  IF p_phase IN ('all', 'critical') THEN
    result := result || jsonb_build_object(
      'v3_adrese',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_adrese) t),
      'v3_auth',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_auth) t),
      'v3_vozila',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_vozila) t),
      'v3_zahtevi',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (
          SELECT id, datum, grad, trazeni_polazak_at, status, polazak_at,
                 koristi_sekundarnu, adresa_override_id, alternativa_pre_at,
                 alternativa_posle_at, alternativa_offered_at, mesto_ponuda,
                 mesto_ponuda_at, mesto_ponuda_odbijena, mesto_ponuda_expired_at,
                 created_at, updated_at, created_by, updated_by, scheduled_at
          FROM public.v3_zahtevi) t),
      'v3_trenutna_dodela',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_trenutna_dodela) t),
      'v3_trenutna_dodela_slot',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_trenutna_dodela_slot) t),
      'v3_operativna_nedelja',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_operativna_nedelja) t),
      'v3_kapacitet_slots',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_kapacitet_slots) t),
      'v3_app_settings',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_app_settings) t)
    );
  END IF;

  IF p_phase IN ('all', 'secondary') THEN
    result := result || jsonb_build_object(
      'v3_finansije',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (
          SELECT id, naziv, kategorija, iznos, isplata_iz, mesec, godina,
                 created_at, updated_at, tip, putnik_v3_auth_id, naplaceno_by,
                 nenaplacene_voznje_json, realizovane_voznje_json,
                 otkazane_voznje_json, uplate_json, visak_iznos,
                 preneti_visak_ulaz, preneti_visak_izlaz
          FROM public.v3_finansije) t),
      'v3_gorivo',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_gorivo) t),
      'v3_krediti',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_krediti) t),
      'v3_uplata_pazara',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_uplata_pazara) t),
      'v3_eta_results',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_eta_results) t),
      'v3_vozac_location',
        (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (SELECT * FROM public.v3_vozac_location) t)
    );
  END IF;

  RETURN result;
END;
$func$;

CREATE OR REPLACE FUNCTION public.fn_v3_bootstrap_delta(p_watermarks jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
  result jsonb := '{}'::jsonb;
  epoch timestamptz := '1970-01-01T00:00:00Z'::timestamptz;
  wm text;
BEGIN
  wm := p_watermarks ->> 'v3_adrese';
  result := result || jsonb_build_object('v3_adrese',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_adrese t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_auth';
  result := result || jsonb_build_object('v3_auth',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_auth t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_vozila';
  result := result || jsonb_build_object('v3_vozila',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_vozila t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_zahtevi';
  result := result || jsonb_build_object('v3_zahtevi',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (
      SELECT id, datum, grad, trazeni_polazak_at, status, polazak_at,
             koristi_sekundarnu, adresa_override_id, alternativa_pre_at,
             alternativa_posle_at, alternativa_offered_at, mesto_ponuda,
             mesto_ponuda_at, mesto_ponuda_odbijena, mesto_ponuda_expired_at,
             created_at, updated_at, created_by, updated_by, scheduled_at
      FROM public.v3_zahtevi) t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_trenutna_dodela';
  result := result || jsonb_build_object('v3_trenutna_dodela',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_trenutna_dodela t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_trenutna_dodela_slot';
  result := result || jsonb_build_object('v3_trenutna_dodela_slot',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_trenutna_dodela_slot t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_operativna_nedelja';
  result := result || jsonb_build_object('v3_operativna_nedelja',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_operativna_nedelja t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_kapacitet_slots';
  result := result || jsonb_build_object('v3_kapacitet_slots',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_kapacitet_slots t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_app_settings';
  result := result || jsonb_build_object('v3_app_settings',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_app_settings t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_finansije';
  result := result || jsonb_build_object('v3_finansije',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM (
      SELECT id, naziv, kategorija, iznos, isplata_iz, mesec, godina,
             created_at, updated_at, tip, putnik_v3_auth_id, naplaceno_by,
             nenaplacene_voznje_json, realizovane_voznje_json,
             otkazane_voznje_json, uplate_json, visak_iznos,
             preneti_visak_ulaz, preneti_visak_izlaz
      FROM public.v3_finansije) t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_gorivo';
  result := result || jsonb_build_object('v3_gorivo',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_gorivo t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_krediti';
  result := result || jsonb_build_object('v3_krediti',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_krediti t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_uplata_pazara';
  result := result || jsonb_build_object('v3_uplata_pazara',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_uplata_pazara t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_eta_results';
  result := result || jsonb_build_object('v3_eta_results',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_eta_results t
     WHERE t.computed_at >= coalesce(wm::timestamptz, epoch)));

  wm := p_watermarks ->> 'v3_vozac_location';
  result := result || jsonb_build_object('v3_vozac_location',
    (SELECT coalesce(jsonb_agg(t), '[]'::jsonb) FROM public.v3_vozac_location t
     WHERE t.updated_at >= coalesce(wm::timestamptz, epoch)));

  RETURN result;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.fn_v3_bootstrap(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_bootstrap_delta(jsonb) TO anon, authenticated;

-- updated_at indexi za delta sync (REST fallback putanja koristi
-- .gte('updated_at', ...) — bez indexa svaki delta je seq scan).
CREATE INDEX IF NOT EXISTS idx_v3_vozila_updated_at
  ON public.v3_vozila (updated_at);
CREATE INDEX IF NOT EXISTS idx_v3_krediti_updated_at
  ON public.v3_krediti (updated_at);
CREATE INDEX IF NOT EXISTS idx_v3_racuni_updated_at
  ON public.v3_racuni (updated_at);
CREATE INDEX IF NOT EXISTS idx_v3_trenutna_dodela_updated_at
  ON public.v3_trenutna_dodela (updated_at);
CREATE INDEX IF NOT EXISTS idx_v3_trenutna_dodela_slot_updated_at
  ON public.v3_trenutna_dodela_slot (updated_at);
CREATE INDEX IF NOT EXISTS idx_v3_uplata_pazara_updated_at
  ON public.v3_uplata_pazara (updated_at);

-- PostgREST schema reload da se RPC-ovi odmah vide.
NOTIFY pgrst, 'reload schema';
