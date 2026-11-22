-- 2026-11-22 — RPC konsolidacija mutacija: 1 round-trip po akciji umesto
-- 4-9 sekvencijalnih REST poziva kroz Funnel (~300-500ms po pozivu).
--
-- Server-side triggeri vec propagiraju vecinu posla (transfer_to_operativna_
-- nedelja, fn_v3_operativna_sync_dodela, v3_sync_*_to_finansije, notify_*),
-- pa su funkcije namerno tanke: diraju samo ono sto klijent danas dira,
-- a triggeri rade ostatak isto kao i do sada.
--
-- Pokriveno:
--   fn_v3_putnik_otkazi        — putnik ponistava polazak po kontekstu
--   fn_v3_putnik_polazak       — putnik bira/menja polazak (reset na obrada)
--   fn_v3_vozac_putnik_upsert  — vozac dodaje/pomera putnika na termin
--   fn_v3_vozac_otkazi         — vozac otkazuje operativnu stavku
--   fn_v3_pokupi               — pokupljenje + evidencija u finansije
--   fn_v3_mesecna_naplata      — uplata mesecne karte (viask/nenaplacene/uplate)
--   fn_v3_pazar_sacuvaj        — dnevna predaja pazara (merge u dnevne_uplate)
--   fn_v3_pazar_sync_zahtev    — sync zahtevan_unos na svezem stanju
--   fn_v3_dodela_termina       — admin: dodela/uklanjanje celog termina vozacu
--   + GRANT anon na fn_v3_alternativa_action (app zove RPC-first, edge fallback)
--
-- Napomena o bezbednosti: RLS politike na ovim tabelama su vec permissive
-- (true/true za anon), pa SECURITY DEFINER ne smanjuje bezbednost u odnosu
-- na postojeci direktan REST pristup. Identity provera (device token/hw)
-- postoji tamo gde je imala smisla i ranije (fn_v3_alternativa_action).

-- ════════════════════════════════════════════════════════════════════
-- 0) fn_v3_alternativa_action — funkcija vec radi device-identity proveru
--    (device_token/hardware_id/installation_id protiv v3_auth slotova),
--    edge funkcija je samo omotac. App poziva RPC-first (~0.3s) umesto
--    edge invoke (~1-4s cold start) — isti pattern kao fn_v3_verify_login.
-- ════════════════════════════════════════════════════════════════════
GRANT EXECUTE ON FUNCTION public.fn_v3_alternativa_action(uuid, text, text, text, text)
  TO anon, authenticated;

-- ════════════════════════════════════════════════════════════════════
-- Interni helper: filtrira + sortira nenaplacene_voznje_json stavke
-- (port _readNenaplaceneVoznje: baca stavke bez operativna_id/datum,
--  sortira po datumu rastuce).
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_nenaplacene_list(p_stavke jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $func$
  SELECT COALESCE(jsonb_agg(e.item ORDER BY
      CASE WHEN COALESCE(e.item->>'datum','') ~ '^\d{4}-\d{2}-\d{2}'
           THEN (e.item->>'datum')::timestamptz
           ELSE '-infinity'::timestamptz END), '[]'::jsonb)
    FROM jsonb_array_elements(COALESCE(p_stavke, '[]'::jsonb)) AS e(item)
   WHERE btrim(COALESCE(e.item->>'operativna_id', '')) <> ''
     AND btrim(COALESCE(e.item->>'datum', '')) <> '';
$func$;

-- ════════════════════════════════════════════════════════════════════
-- Interni helper: port _consumeNenaplaceneVoznje — trosi uplacen iznos
-- kroz nenaplacene stavke (hronoloski). Delimicna uplata umanjuje cenu
-- prve stavke; preostatak vraca kao "preostalo" (postaje visak).
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_consume_nenaplacene(
  p_stavke jsonb,
  p_uplaceno numeric,
  p_default_cena numeric
) RETURNS TABLE(stavke jsonb, preostalo numeric)
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $func$
DECLARE
  v_item jsonb;
  v_out jsonb := '[]'::jsonb;
  v_preostalo numeric := COALESCE(p_uplaceno, 0);
  v_cena numeric;
  v_stop boolean := false;
BEGIN
  FOR v_item IN
    SELECT e.item
      FROM jsonb_array_elements(public.fn_v3_nenaplacene_list(p_stavke)) AS e(item)
  LOOP
    IF v_stop OR v_preostalo <= 0.009 THEN
      v_out := v_out || v_item;
      CONTINUE;
    END IF;

    v_cena := COALESCE((v_item->>'cena')::numeric, 0);
    IF v_cena <= 0.009 THEN
      v_cena := COALESCE(p_default_cena, 0);
    END IF;

    IF v_cena <= 0.009 THEN
      -- Stavka bez cene i bez default cene: prekid trosenja, ostaju sve.
      v_out := v_out || v_item;
      v_stop := true;
      CONTINUE;
    END IF;

    IF v_preostalo + 0.009 >= v_cena THEN
      v_preostalo := v_preostalo - v_cena;  -- stavka otplacena, ispada
      CONTINUE;
    END IF;

    -- Delimicna uplata: umanji cenu prve stavke.
    v_out := v_out || jsonb_set(v_item, '{cena}', to_jsonb(v_cena - v_preostalo));
    v_preostalo := 0;
  END LOOP;

  stavke := v_out;
  preostalo := v_preostalo;
  RETURN NEXT;
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- Interni helper: port _primeniPrenetiVisakNaPostojeciRed — prenosi visak
-- sa hronoloski poslednjeg prethodnog master reda (preskace mesece bez
-- kredita) na tekuci: kreditira cilj, prazni donora.
-- Vraca svezu verziju tekuceg reda.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_apply_preneti_visak(
  p_putnik_id uuid,
  p_godina integer,
  p_mesec integer,
  p_tekuci_id uuid,
  p_default_cena numeric
) RETURNS public.v3_finansije
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_prev public.v3_finansije%ROWTYPE;
  v_tekuci public.v3_finansije%ROWTYPE;
  v_preneti numeric;
  v_cons record;
  v_novi_ulaz numeric;
  v_novi_izlaz numeric;
BEGIN
  SELECT * INTO v_tekuci FROM public.v3_finansije WHERE id = p_tekuci_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Hronoloski najskoriji prethodni mesec koji jos nosi visak
  -- (key = godina*12+mesec; tie-break: veci visak, pa noviji created_at).
  SELECT * INTO v_prev
    FROM public.v3_finansije f
   WHERE f.putnik_v3_auth_id = p_putnik_id
     AND lower(btrim(COALESCE(f.tip, ''))) = 'prihod'
     AND lower(btrim(COALESCE(f.kategorija, ''))) IN ('operativna_naplata', 'operativna_realizacija')
     AND f.godina IS NOT NULL AND f.mesec IS NOT NULL
     AND (f.godina * 12 + f.mesec) < (p_godina * 12 + p_mesec)
     AND COALESCE(f.visak_iznos, 0) > 0.009
   ORDER BY (f.godina * 12 + f.mesec) DESC,
            f.visak_iznos DESC,
            f.created_at DESC NULLS LAST
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN v_tekuci;
  END IF;

  v_preneti := COALESCE(v_prev.visak_iznos, 0);

  SELECT * INTO v_cons
    FROM public.fn_v3_consume_nenaplacene(
      v_tekuci.nenaplacene_voznje_json, v_preneti, p_default_cena);

  v_novi_ulaz := COALESCE(v_tekuci.preneti_visak_ulaz, 0) + v_preneti;
  v_novi_izlaz := COALESCE(v_prev.preneti_visak_izlaz, 0) + v_preneti;

  UPDATE public.v3_finansije
     SET nenaplacene_voznje_json = v_cons.stavke,
         visak_iznos = COALESCE(v_tekuci.visak_iznos, 0) + v_cons.preostalo,
         preneti_visak_ulaz = v_novi_ulaz,
         updated_at = now()
   WHERE id = v_tekuci.id
  RETURNING * INTO v_tekuci;

  UPDATE public.v3_finansije
     SET visak_iznos = 0,
         preneti_visak_izlaz = v_novi_izlaz,
         updated_at = now()
   WHERE id = v_prev.id;

  RETURN v_tekuci;
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_v3_nenaplacene_list(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_consume_nenaplacene(jsonb, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_apply_preneti_visak(uuid, integer, integer, uuid, numeric) FROM PUBLIC, anon, authenticated;

-- ════════════════════════════════════════════════════════════════════
-- 1) fn_v3_putnik_otkazi — putnik ponistava polazak po kontekstu
--    (putnik+datum+grad). Najnoviji vidljivi zahtev -> 'otkazano';
--    trigger transfer_to_operativna_nedelja ponistava operativne redove;
--    UPDATE ispod je catch-all za redove bez zahteva (legacy/anomalija).
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_putnik_otkazi(
  p_putnik_id uuid,
  p_datum date,
  p_grad text,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_zahtev public.v3_zahtevi%ROWTYPE;
  v_found boolean;
  v_operativna_count integer := 0;
  v_operativna jsonb;
BEGIN
  SELECT * INTO v_zahtev
    FROM public.v3_zahtevi z
   WHERE z.created_by = p_putnik_id
     AND z.datum = p_datum
     AND upper(btrim(COALESCE(z.grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND lower(btrim(COALESCE(z.status, ''))) NOT IN ('otkazano', 'odbijeno', 'cancelled', 'rejected')
   ORDER BY GREATEST(z.created_at, COALESCE(z.updated_at, z.created_at)) DESC, z.id
   LIMIT 1
   FOR UPDATE;
  v_found := FOUND;

  IF v_found THEN
    UPDATE public.v3_zahtevi
       SET status = 'otkazano',
           updated_by = p_actor
     WHERE id = v_zahtev.id
    RETURNING * INTO v_zahtev;
  END IF;

  UPDATE public.v3_operativna_nedelja o
     SET otkazano_at = now(),
         otkazano_by = p_actor,
         updated_at = now(),
         updated_by = p_actor
   WHERE o.created_by = p_putnik_id
     AND o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND o.otkazano_at IS NULL;
  GET DIAGNOSTICS v_operativna_count = ROW_COUNT;

  SELECT COALESCE(jsonb_agg(to_jsonb(o)), '[]'::jsonb) INTO v_operativna
    FROM public.v3_operativna_nedelja o
   WHERE o.created_by = p_putnik_id
     AND o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = upper(btrim(COALESCE(p_grad, '')));

  IF NOT v_found AND v_operativna_count = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'nothing_to_cancel');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'zahtev', CASE WHEN v_found THEN to_jsonb(v_zahtev) ELSE NULL END,
    'operativna_otkazano', v_operativna_count,
    'operativna', v_operativna);
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 2) fn_v3_putnik_polazak — putnik bira/menja polazak. Najnoviji vidljivi
--    zahtev -> reset na 'obrada' (port resetToObrada); ako nema -> INSERT.
--    Trigger 'obrada' grana ponistava aktivne operativne redove — cron
--    process_pending_zahtevi ih ponovo uspostavlja (istekao 10-min wait
--    se resetuje kroz created_at=now() kao i do sada).
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_putnik_polazak(
  p_putnik_id uuid,
  p_datum date,
  p_grad text,
  p_vreme time,
  p_koristi_sekundarnu boolean DEFAULT NULL,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_zahtev public.v3_zahtevi%ROWTYPE;
  v_operativna jsonb;
BEGIN
  IF p_vreme IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_vreme');
  END IF;

  SELECT * INTO v_zahtev
    FROM public.v3_zahtevi z
   WHERE z.created_by = p_putnik_id
     AND z.datum = p_datum
     AND upper(btrim(COALESCE(z.grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND lower(btrim(COALESCE(z.status, ''))) NOT IN ('otkazano', 'odbijeno', 'cancelled', 'rejected')
   ORDER BY GREATEST(z.created_at, COALESCE(z.updated_at, z.created_at)) DESC, z.id
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    UPDATE public.v3_zahtevi
       SET status = 'obrada',
           trazeni_polazak_at = p_vreme,
           polazak_at = NULL,
           scheduled_at = NULL,
           alternativa_pre_at = NULL,
           alternativa_posle_at = NULL,
           alternativa_offered_at = NULL,
           mesto_ponuda = false,
           mesto_ponuda_odbijena = false,
           mesto_ponuda_at = NULL,
           created_at = now(),
           koristi_sekundarnu = COALESCE(p_koristi_sekundarnu, koristi_sekundarnu),
           updated_by = p_actor
     WHERE id = v_zahtev.id
    RETURNING * INTO v_zahtev;
  ELSE
    INSERT INTO public.v3_zahtevi (
      datum, grad, trazeni_polazak_at, status,
      koristi_sekundarnu, created_by, updated_by, created_at
    ) VALUES (
      p_datum, p_grad, p_vreme, 'obrada',
      COALESCE(p_koristi_sekundarnu, false),
      COALESCE(p_actor, p_putnik_id), p_actor, now()
    )
    RETURNING * INTO v_zahtev;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(o)), '[]'::jsonb) INTO v_operativna
    FROM public.v3_operativna_nedelja o
   WHERE o.created_by = p_putnik_id
     AND o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = upper(btrim(COALESCE(p_grad, '')));

  RETURN jsonb_build_object('ok', true, 'zahtev', to_jsonb(v_zahtev),
                            'operativna', v_operativna);
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 3) fn_v3_vozac_putnik_upsert — vozac dodaje/pomera putnika na termin.
--    Port createOrUpdateByVozac + _syncZahtevForVozacContext, ali kroz
--    zahtev granu 'odobreno' triggera koji sam upsertuje/pomera kanonski
--    operativna red i guši duplikate:
--      1) stale vidljivi zahtevi (svi osim najnovijeg) -> 'otkazano'
--         (trigger ponistava njihove aktivne operativne redove)
--      2) primarni zahtev -> 'odobreno' + ciljni termin (trigger
--         upisuje/pomera/ozivljava kanonski operativna red, kopira
--         koristi_sekundarnu/adresa_override_id i ponistava duplikate)
--      3) nema zahteva -> INSERT 'odobreno' (trigger pravi operativna red)
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_vozac_putnik_upsert(
  p_putnik_id uuid,
  p_datum date,
  p_grad text,
  p_polazak_at time,
  p_actor uuid DEFAULT NULL,
  p_koristi_sekundarnu boolean DEFAULT NULL,
  p_adresa_override_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_zahtev public.v3_zahtevi%ROWTYPE;
  v_operativna public.v3_operativna_nedelja%ROWTYPE;
  v_operativna_sve jsonb;
  v_stale integer := 0;
BEGIN
  IF p_polazak_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_polazak_at');
  END IF;

  SELECT * INTO v_zahtev
    FROM public.v3_zahtevi z
   WHERE z.created_by = p_putnik_id
     AND z.datum = p_datum
     AND upper(btrim(COALESCE(z.grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND lower(btrim(COALESCE(z.status, ''))) NOT IN ('otkazano', 'odbijeno', 'cancelled', 'rejected')
   ORDER BY GREATEST(z.created_at, COALESCE(z.updated_at, z.created_at)) DESC, z.id
   LIMIT 1
   FOR UPDATE;

  -- Prvo stali zahtevi pa primarni: otkazivanje stalog zahteva triggerom
  -- ponistava SVE aktivne operativne redove konteksta — zato stali idu
  -- pre, a 'odobreno' update primarnog posle ozivi/pomeri kanonski red.
  UPDATE public.v3_zahtevi
     SET status = 'otkazano',
         updated_by = p_actor
   WHERE created_by = p_putnik_id
     AND datum = p_datum
     AND upper(btrim(COALESCE(grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND lower(btrim(COALESCE(status, ''))) NOT IN ('otkazano', 'odbijeno', 'cancelled', 'rejected')
     AND (v_zahtev.id IS NULL OR id <> v_zahtev.id);
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  IF v_zahtev.id IS NOT NULL THEN
    UPDATE public.v3_zahtevi
       SET status = 'odobreno',
           trazeni_polazak_at = p_polazak_at,
           polazak_at = p_polazak_at,
           alternativa_pre_at = NULL,
           alternativa_posle_at = NULL,
           koristi_sekundarnu = COALESCE(p_koristi_sekundarnu, koristi_sekundarnu),
           adresa_override_id = p_adresa_override_id,
           updated_by = p_actor
     WHERE id = v_zahtev.id
    RETURNING * INTO v_zahtev;
  ELSE
    INSERT INTO public.v3_zahtevi (
      datum, grad, created_by, status,
      trazeni_polazak_at, polazak_at,
      koristi_sekundarnu, adresa_override_id, updated_by
    ) VALUES (
      p_datum, p_grad, p_putnik_id, 'odobreno',
      p_polazak_at, p_polazak_at,
      COALESCE(p_koristi_sekundarnu, false), p_adresa_override_id, p_actor
    )
    RETURNING * INTO v_zahtev;
  END IF;

  -- Rezultujuci aktivni operativna red (napravio ga/oziveo trigger).
  SELECT * INTO v_operativna
    FROM public.v3_operativna_nedelja o
   WHERE o.created_by = p_putnik_id
     AND o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = upper(btrim(COALESCE(p_grad, '')))
     AND o.otkazano_at IS NULL
   ORDER BY o.updated_at DESC NULLS LAST, o.created_at DESC NULLS LAST, o.id
   LIMIT 1;

  SELECT COALESCE(jsonb_agg(to_jsonb(o)), '[]'::jsonb) INTO v_operativna_sve
    FROM public.v3_operativna_nedelja o
   WHERE o.created_by = p_putnik_id
     AND o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = upper(btrim(COALESCE(p_grad, '')));

  RETURN jsonb_build_object(
    'ok', true,
    'zahtev', to_jsonb(v_zahtev),
    'operativna', CASE WHEN v_operativna.id IS NULL THEN NULL ELSE to_jsonb(v_operativna) END,
    'operativna_sve', v_operativna_sve,
    'stale_otkazano', v_stale);
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 4) fn_v3_vozac_otkazi — vozac otkazuje operativnu stavku po id-u.
--    Trigger fn_v3_operativna_sync_dodela brise dodelu; finansije/ponude/
--    push idu kroz svoje triggere.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_vozac_otkazi(
  p_operativna_id uuid,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_op public.v3_operativna_nedelja%ROWTYPE;
  v_exists boolean;
BEGIN
  SELECT (o.otkazano_at IS NULL) INTO v_exists
    FROM public.v3_operativna_nedelja o WHERE o.id = p_operativna_id;
  IF v_exists IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT v_exists THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_canceled');
  END IF;

  UPDATE public.v3_operativna_nedelja
     SET otkazano_at = now(),
         otkazano_by = p_actor,
         updated_by = p_actor
   WHERE id = p_operativna_id
  RETURNING * INTO v_op;

  RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op));
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 5) fn_v3_pokupi — vozac oznacava putnika pokupljenim + evidencija u
--    finansije (port _evidentirajRealizacijuPriPokupljanjuOnce):
--    preneti visak -> po-danu guard (vecVozioDanas / postojeća stavka) ->
--    visak trosi cenu, ostatak ide u nenaplacene.
--    realizovane_voznje_json odrzava postojeci DB trigger.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_pokupi(
  p_operativna_id uuid,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_op public.v3_operativna_nedelja%ROWTYPE;
  v_putnik uuid;
  v_tip text;
  v_cena_danu numeric;
  v_cena_pok numeric;
  v_is_po_danu boolean;
  v_cena numeric;
  v_mesec integer;
  v_godina integer;
  v_master public.v3_finansije%ROWTYPE;
  v_has_master boolean;
  v_stavke jsonb;
  v_trenutni_visak numeric;
  v_preostala_cena numeric;
  v_novi_visak numeric;
  v_dan_iso text;
BEGIN
  UPDATE public.v3_operativna_nedelja
     SET pokupljen_at = now(),
         pokupljen_by = p_actor
   WHERE id = p_operativna_id
  RETURNING * INTO v_op;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'operativna_not_found');
  END IF;

  v_putnik := v_op.created_by;
  IF v_putnik IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op), 'finansije', NULL);
  END IF;

  SELECT lower(btrim(COALESCE(a.tip, ''))), COALESCE(a.cena_po_danu, 0), COALESCE(a.cena_po_pokupljenju, 0)
    INTO v_tip, v_cena_danu, v_cena_pok
    FROM public.v3_auth a WHERE a.id = v_putnik;

  IF v_tip = 'vozac' THEN
    RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op), 'finansije', NULL);
  END IF;

  v_is_po_danu := v_tip IN ('radnik', 'ucenik');
  v_cena := CASE WHEN v_is_po_danu THEN v_cena_danu ELSE v_cena_pok END;
  v_mesec := extract(month FROM v_op.datum)::int;
  v_godina := extract(year FROM v_op.datum)::int;
  v_dan_iso := to_char(v_op.datum, 'YYYY-MM-DD');

  -- Serijalizacija po putnik+mesec (zamenjuje _mesecnaNaplataLocks +
  -- unique-race retry na ux_v3_finansije_naplata_master).
  PERFORM pg_advisory_xact_lock(hashtext('fin:' || v_putnik::text || ':' || v_mesec || ':' || v_godina));

  -- Master red: najnoviji po created_at medju prihod redovima za mesec.
  SELECT * INTO v_master
    FROM public.v3_finansije f
   WHERE f.putnik_v3_auth_id = v_putnik
     AND f.godina = v_godina
     AND f.mesec = v_mesec
     AND lower(btrim(COALESCE(f.tip, ''))) = 'prihod'
   ORDER BY f.created_at DESC NULLS LAST, f.id
   LIMIT 1
   FOR UPDATE;
  v_has_master := FOUND;

  IF v_has_master THEN
    v_master := public.fn_v3_apply_preneti_visak(
      v_putnik, v_godina, v_mesec, v_master.id, v_cena);

    IF v_is_po_danu THEN
      -- Vec vozio danas (druga operativna stavka sa pokupljen_at)?
      IF EXISTS (
        SELECT 1 FROM public.v3_operativna_nedelja o
         WHERE o.created_by = v_putnik
           AND o.datum = v_op.datum
           AND o.pokupljen_at IS NOT NULL
           AND o.id <> v_op.id) THEN
        RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op),
                                  'finansije', to_jsonb(v_master), 'skipped', 'vec_vozio_danas');
      END IF;
      -- Vec postoji nenaplacena stavka za danas?
      IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          public.fn_v3_nenaplacene_list(v_master.nenaplacene_voznje_json)) e(item)
         WHERE e.item->>'datum' = v_dan_iso) THEN
        RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op),
                                  'finansije', to_jsonb(v_master), 'skipped', 'vec_nenaplacena');
      END IF;
    END IF;

    v_trenutni_visak := COALESCE(v_master.visak_iznos, 0);
    v_preostala_cena := GREATEST(v_cena - v_trenutni_visak, 0);
    v_novi_visak := GREATEST(v_trenutni_visak - v_cena, 0);
    v_stavke := public.fn_v3_nenaplacene_list(v_master.nenaplacene_voznje_json);

    IF v_preostala_cena > 0.009
       AND NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_stavke) e(item)
          WHERE e.item->>'operativna_id' = v_op.id::text) THEN
      v_stavke := v_stavke || jsonb_build_object(
        'operativna_id', v_op.id::text, 'datum', v_dan_iso, 'cena', v_preostala_cena);
    END IF;

    UPDATE public.v3_finansije
       SET nenaplacene_voznje_json = v_stavke,
           visak_iznos = v_novi_visak,
           updated_at = now()
     WHERE id = v_master.id
    RETURNING * INTO v_master;
  ELSE
    INSERT INTO public.v3_finansije (
      naziv, kategorija, tip, iznos, putnik_v3_auth_id,
      nenaplacene_voznje_json, visak_iznos, preneti_visak_ulaz, mesec, godina
    ) VALUES (
      'Evidencija prevoza ' || v_mesec || '/' || v_godina,
      'operativna_naplata', 'prihod', 0, v_putnik,
      jsonb_build_array(jsonb_build_object(
        'operativna_id', v_op.id::text, 'datum', v_dan_iso, 'cena', v_cena)),
      0, 0, v_mesec, v_godina
    )
    RETURNING * INTO v_master;

    v_master := public.fn_v3_apply_preneti_visak(
      v_putnik, v_godina, v_mesec, v_master.id, v_cena);
  END IF;

  RETURN jsonb_build_object('ok', true, 'operativna', to_jsonb(v_op),
                            'finansije', to_jsonb(v_master));
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 6) fn_v3_mesecna_naplata — uplata mesecne karte
--    (port _sacuvajMesecnuNaplatuOnce): preneti visak -> consume
--    nenaplacene -> append uplata -> skalarno izvedeno iz uplate_json.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_mesecna_naplata(
  p_putnik_id uuid,
  p_naplatio_by uuid,
  p_iznos numeric,
  p_mesec integer,
  p_godina integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_now timestamptz := now();
  v_uplata jsonb;
  v_tip text;
  v_cena_danu numeric;
  v_cena_pok numeric;
  v_cena numeric;
  v_master public.v3_finansije%ROWTYPE;
  v_current jsonb;
  v_cons record;
  v_has_bez_cene boolean;
  v_should_pretvori boolean;
  v_novi_visak numeric;
  v_uplate jsonb;
  v_iznos numeric;
  v_naplatio_by uuid;
BEGIN
  IF p_putnik_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_putnik_id');
  END IF;
  IF COALESCE(p_iznos, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_iznos');
  END IF;

  v_uplata := jsonb_build_object(
    'uplata_id', 'upl:' || gen_random_uuid()::text,
    'datum', v_now,
    'iznos', p_iznos,
    'naplatio_by', p_naplatio_by,
    'naplatio_at', v_now);

  SELECT lower(btrim(COALESCE(a.tip, ''))), COALESCE(a.cena_po_danu, 0), COALESCE(a.cena_po_pokupljenju, 0)
    INTO v_tip, v_cena_danu, v_cena_pok
    FROM public.v3_auth a WHERE a.id = p_putnik_id;
  v_cena := CASE WHEN v_tip IN ('radnik', 'ucenik') THEN v_cena_danu ELSE v_cena_pok END;

  PERFORM pg_advisory_xact_lock(hashtext('naplata:' || p_putnik_id::text || ':' || p_mesec || ':' || p_godina));

  SELECT * INTO v_master
    FROM public.v3_finansije f
   WHERE f.putnik_v3_auth_id = p_putnik_id
     AND f.godina = p_godina
     AND f.mesec = p_mesec
     AND lower(btrim(COALESCE(f.tip, ''))) = 'prihod'
   ORDER BY f.created_at DESC NULLS LAST, f.id
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    v_master := public.fn_v3_apply_preneti_visak(
      p_putnik_id, p_godina, p_mesec, v_master.id, v_cena);

    v_current := public.fn_v3_nenaplacene_list(v_master.nenaplacene_voznje_json);

    SELECT * INTO v_cons
      FROM public.fn_v3_consume_nenaplacene(v_current, p_iznos, v_cena);

    v_has_bez_cene := EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_current) e(item)
       WHERE COALESCE((e.item->>'cena')::numeric, 0) <= 0.009);
    v_should_pretvori := NOT (v_cena <= 0.009 AND v_has_bez_cene);
    v_novi_visak := COALESCE(v_master.visak_iznos, 0)
                    + (CASE WHEN v_should_pretvori THEN v_cons.preostalo ELSE 0 END);

    -- append uplata + sort po 'datum' (port _appendUplata)
    SELECT COALESCE(jsonb_agg(e.item ORDER BY
        CASE WHEN COALESCE(e.item->>'datum','') ~ '^\d{4}-\d{2}-\d{2}'
             THEN (e.item->>'datum')::timestamptz
             ELSE '-infinity'::timestamptz END), '[]'::jsonb)
      INTO v_uplate
      FROM jsonb_array_elements(COALESCE(v_master.uplate_json, '[]'::jsonb) || v_uplata) e(item)
     WHERE btrim(COALESCE(e.item->>'uplata_id', '')) <> ''
       AND btrim(COALESCE(e.item->>'datum', '')) <> '';

    SELECT COALESCE(sum(COALESCE((e.item->>'iznos')::numeric, 0)), 0)
      INTO v_iznos
      FROM jsonb_array_elements(v_uplate) e(item);

    SELECT (e.item->>'naplatio_by')::uuid
      INTO v_naplatio_by
      FROM jsonb_array_elements(v_uplate) e(item)
     ORDER BY
       CASE WHEN COALESCE(e.item->>'naplatio_at','') ~ '^\d{4}-\d{2}-\d{2}'
            THEN (e.item->>'naplatio_at')::timestamptz
            WHEN COALESCE(e.item->>'datum','') ~ '^\d{4}-\d{2}-\d{2}'
            THEN (e.item->>'datum')::timestamptz
            ELSE '-infinity'::timestamptz END DESC
     LIMIT 1;

    UPDATE public.v3_finansije
       SET iznos = v_iznos,
           naplaceno_by = v_naplatio_by,
           nenaplacene_voznje_json = v_cons.stavke,
           uplate_json = v_uplate,
           visak_iznos = v_novi_visak,
           updated_at = v_now
     WHERE id = v_master.id
    RETURNING * INTO v_master;
  ELSE
    INSERT INTO public.v3_finansije (
      naziv, kategorija, tip, iznos, putnik_v3_auth_id, naplaceno_by,
      nenaplacene_voznje_json, uplate_json, visak_iznos, preneti_visak_ulaz,
      mesec, godina
    ) VALUES (
      'Evidencija prevoza ' || p_mesec || '/' || p_godina,
      'operativna_naplata', 'prihod', p_iznos, p_putnik_id, p_naplatio_by,
      '[]'::jsonb, jsonb_build_array(v_uplata),
      CASE WHEN v_cena > 0.009 THEN p_iznos ELSE 0 END, 0,
      p_mesec, p_godina
    )
    RETURNING * INTO v_master;

    v_master := public.fn_v3_apply_preneti_visak(
      p_putnik_id, p_godina, p_mesec, v_master.id, v_cena);
  END IF;

  RETURN jsonb_build_object('ok', true, 'finansije', to_jsonb(v_master));
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 7) fn_v3_pazar_sacuvaj — dnevna predaja pazara (port sacuvajDnevnuUplatu):
--    merge dnevne stavke u dnevne_uplate_json na svezem (FOR UPDATE) redu.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_pazar_sacuvaj(
  p_vozac_id uuid,
  p_datum date,
  p_predao numeric,
  p_ukupno numeric,
  p_zahtevan_unos boolean DEFAULT false,
  p_saberi_sa_postojecim boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_row public.v3_uplata_pazara%ROWTYPE;
  v_dan integer := extract(day FROM p_datum)::int;
  v_mesec integer := extract(month FROM p_datum)::int;
  v_godina integer := extract(year FROM p_datum)::int;
  v_prev jsonb;
  v_eff_predao numeric;
  v_nova jsonb;
  v_lista jsonb;
BEGIN
  SELECT * INTO v_row
    FROM public.v3_uplata_pazara
   WHERE vozac_id = p_vozac_id AND mesec = v_mesec AND godina = v_godina
   FOR UPDATE;

  IF FOUND THEN
    SELECT e.item INTO v_prev
      FROM jsonb_array_elements(COALESCE(v_row.dnevne_uplate_json, '[]'::jsonb)) e(item)
     WHERE COALESCE((e.item->>'dan')::int, 0) = v_dan
     LIMIT 1;

    v_eff_predao := CASE WHEN p_saberi_sa_postojecim
                         THEN COALESCE((v_prev->>'predao')::numeric, 0) + p_predao
                         ELSE p_predao END;
    v_nova := jsonb_build_object(
      'dan', v_dan, 'predao', v_eff_predao, 'ukupno', p_ukupno,
      'razlika', v_eff_predao - p_ukupno,
      'zahtevan_unos', COALESCE(p_zahtevan_unos, false));

    SELECT COALESCE(jsonb_agg(e.item ORDER BY COALESCE((e.item->>'dan')::int, 0)), '[]'::jsonb)
      INTO v_lista
      FROM jsonb_array_elements(
        (SELECT COALESCE(jsonb_agg(x.item), '[]'::jsonb)
           FROM jsonb_array_elements(COALESCE(v_row.dnevne_uplate_json, '[]'::jsonb)) x(item)
          WHERE COALESCE((x.item->>'dan')::int, 0) <> v_dan) || v_nova) e(item);

    UPDATE public.v3_uplata_pazara
       SET dnevne_uplate_json = v_lista, updated_at = now()
     WHERE id = v_row.id
    RETURNING * INTO v_row;
  ELSE
    v_nova := jsonb_build_object(
      'dan', v_dan, 'predao', p_predao, 'ukupno', p_ukupno,
      'razlika', p_predao - p_ukupno,
      'zahtevan_unos', COALESCE(p_zahtevan_unos, false));

    INSERT INTO public.v3_uplata_pazara (vozac_id, mesec, godina, dnevne_uplate_json)
    VALUES (p_vozac_id, v_mesec, v_godina, jsonb_build_array(v_nova))
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object('ok', true, 'uplata', to_jsonb(v_row));
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 8) fn_v3_pazar_sync_zahtev — port syncZahtevanUnos: merge na svezem
--    redu; predao se cita iz baze; zahtevan_unos se postavlja samo na
--    rast ukupnog; bila_predaja = reblokada zavrsenog unosa.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_pazar_sync_zahtev(
  p_vozac_id uuid,
  p_datum date,
  p_ukupno numeric
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_row public.v3_uplata_pazara%ROWTYPE;
  v_dan integer := extract(day FROM p_datum)::int;
  v_mesec integer := extract(month FROM p_datum)::int;
  v_godina integer := extract(year FROM p_datum)::int;
  v_prev jsonb;
  v_prev_ukupno numeric;
  v_prev_zu boolean;
  v_predao numeric;
  v_porastao boolean;
  v_novi_zu boolean;
  v_bila boolean;
  v_nova jsonb;
  v_lista jsonb;
BEGIN
  SELECT * INTO v_row
    FROM public.v3_uplata_pazara
   WHERE vozac_id = p_vozac_id AND mesec = v_mesec AND godina = v_godina
   FOR UPDATE;

  IF FOUND THEN
    SELECT e.item INTO v_prev
      FROM jsonb_array_elements(COALESCE(v_row.dnevne_uplate_json, '[]'::jsonb)) e(item)
     WHERE COALESCE((e.item->>'dan')::int, 0) = v_dan
     LIMIT 1;
  END IF;

  -- Nema zapisa i nema pazara — nema sta da se zahteva.
  IF v_prev IS NULL AND COALESCE(p_ukupno, 0) <= 0 THEN
    RETURN jsonb_build_object('ok', true,
      'uplata', CASE WHEN v_row.id IS NULL THEN NULL ELSE to_jsonb(v_row) END,
      'bila_predaja', false);
  END IF;

  v_predao := COALESCE((v_prev->>'predao')::numeric, 0);
  v_prev_ukupno := COALESCE((v_prev->>'ukupno')::numeric, 0);
  v_prev_zu := COALESCE((v_prev->>'zahtevan_unos')::boolean, false);
  v_porastao := v_prev IS NULL OR (p_ukupno - v_prev_ukupno) > 0.009;
  v_novi_zu := v_prev_zu OR v_porastao;
  v_bila := v_prev IS NOT NULL AND v_prev_zu = false AND v_novi_zu;

  -- Nista se nije promenilo — bez suvisnog upisa.
  IF v_prev IS NOT NULL AND v_prev_zu = v_novi_zu AND abs(p_ukupno - v_prev_ukupno) <= 0.009 THEN
    RETURN jsonb_build_object('ok', true, 'uplata', to_jsonb(v_row), 'bila_predaja', false);
  END IF;

  v_nova := jsonb_build_object(
    'dan', v_dan, 'predao', v_predao, 'ukupno', p_ukupno,
    'razlika', v_predao - p_ukupno, 'zahtevan_unos', v_novi_zu);

  IF v_row.id IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(e.item ORDER BY COALESCE((e.item->>'dan')::int, 0)), '[]'::jsonb)
      INTO v_lista
      FROM jsonb_array_elements(
        (SELECT COALESCE(jsonb_agg(x.item), '[]'::jsonb)
           FROM jsonb_array_elements(COALESCE(v_row.dnevne_uplate_json, '[]'::jsonb)) x(item)
          WHERE COALESCE((x.item->>'dan')::int, 0) <> v_dan) || v_nova) e(item);

    UPDATE public.v3_uplata_pazara
       SET dnevne_uplate_json = v_lista, updated_at = now()
     WHERE id = v_row.id
    RETURNING * INTO v_row;
  ELSE
    INSERT INTO public.v3_uplata_pazara (vozac_id, mesec, godina, dnevne_uplate_json)
    VALUES (p_vozac_id, v_mesec, v_godina, jsonb_build_array(v_nova))
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object('ok', true, 'uplata', to_jsonb(v_row), 'bila_predaja', v_bila);
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- 9) fn_v3_dodela_termina — admin raspored: dodela celog termina vozacu
--    (p_vozac_id NULL = uklanjanje). Port assignTerminDefault /
--    clearTerminDefault + canAssign + _putnikPostoji uslova.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.fn_v3_dodela_termina(
  p_datum date,
  p_grad text,
  p_vreme time,
  p_vozac_id uuid DEFAULT NULL,
  p_vozilo_id uuid DEFAULT NULL,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $func$
DECLARE
  v_slot_id uuid;
  v_termin_ids uuid[];
  v_count integer := 0;
  v_grad text := upper(btrim(COALESCE(p_grad, '')));
BEGIN
  -- Aktivne operativne stavke na slotu ciji putnik postoji u v3_auth
  -- (tip <> 'vozac'), bez otkazivanja/pokupljanja.
  SELECT array_agg(o.id) INTO v_termin_ids
    FROM public.v3_operativna_nedelja o
   WHERE o.datum = p_datum
     AND upper(btrim(COALESCE(o.grad, ''))) = v_grad
     AND to_char(o.polazak_at, 'HH24:MI') = to_char(p_vreme, 'HH24:MI')
     AND o.otkazano_at IS NULL
     AND o.pokupljen_at IS NULL
     AND EXISTS (
       SELECT 1 FROM public.v3_auth a
        WHERE a.id = o.created_by
          AND lower(btrim(COALESCE(a.tip, ''))) <> ''
          AND lower(btrim(COALESCE(a.tip, ''))) <> 'vozac');
  v_termin_ids := COALESCE(v_termin_ids, '{}'::uuid[]);
  v_count := cardinality(v_termin_ids);

  IF p_vozac_id IS NULL THEN
    -- clearTerminDefault: obrisi slot + dodele za te termine.
    DELETE FROM public.v3_trenutna_dodela_slot
     WHERE datum = p_datum AND grad = v_grad
       AND to_char(vreme, 'HH24:MI') = to_char(p_vreme, 'HH24:MI');

    DELETE FROM public.v3_trenutna_dodela
     WHERE termin_id = ANY(v_termin_ids);

    RETURN jsonb_build_object('ok', true, 'cleared', v_count);
  END IF;

  DELETE FROM public.v3_trenutna_dodela
   WHERE termin_id = ANY(v_termin_ids);

  INSERT INTO public.v3_trenutna_dodela_slot (
    datum, grad, vreme, vozac_v3_auth_id, vozilo_id, updated_by
  ) VALUES (
    p_datum, v_grad, p_vreme, p_vozac_id, p_vozilo_id, p_actor
  )
  ON CONFLICT (datum, grad, vreme) DO UPDATE
    SET vozac_v3_auth_id = excluded.vozac_v3_auth_id,
        vozilo_id = excluded.vozilo_id,
        updated_by = excluded.updated_by
  RETURNING id INTO v_slot_id;

  INSERT INTO public.v3_trenutna_dodela (
    termin_id, putnik_v3_auth_id, vozac_v3_auth_id, slot_id, updated_by
  )
  SELECT o.id, o.created_by, p_vozac_id, v_slot_id, p_actor
    FROM public.v3_operativna_nedelja o
   WHERE o.id = ANY(v_termin_ids)
  ON CONFLICT (termin_id) DO UPDATE
    SET vozac_v3_auth_id = excluded.vozac_v3_auth_id,
        putnik_v3_auth_id = excluded.putnik_v3_auth_id,
        slot_id = excluded.slot_id,
        updated_by = excluded.updated_by;

  RETURN jsonb_build_object('ok', true, 'slot_id', v_slot_id, 'assigned', v_count);
END;
$func$;

-- ════════════════════════════════════════════════════════════════════
-- GRANT-ovi (app zove sa anon kljucem — isto kao REST danas)
-- ════════════════════════════════════════════════════════════════════
GRANT EXECUTE ON FUNCTION public.fn_v3_putnik_otkazi(uuid, date, text, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_putnik_polazak(uuid, date, text, time, boolean, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_vozac_putnik_upsert(uuid, date, text, time, uuid, boolean, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_vozac_otkazi(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_pokupi(uuid, uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_mesecna_naplata(uuid, uuid, numeric, integer, integer) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_pazar_sacuvaj(uuid, date, numeric, numeric, boolean, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_pazar_sync_zahtev(uuid, date, numeric) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_dodela_termina(date, text, time, uuid, uuid, uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
