-- =============================================================================
-- 20261121000001_fix_oslobodjeno_mesto_logic.sql
--
-- Ispravke logike "oslobodjeno mesto" (mesto_ponuda) toka:
--
--  1) process_pending_zahtevi_slots sada uracunava AKTIVNE mesto_ponuda ponude
--     u zauzetost slota (existing_mesta i usage_by_slot za alternative).
--     Ranije je 'obrada' zahtev mogao biti odobren na mesto koje je upravo
--     ponudjeno drugom putniku — nosiocu ponude bi accept pao na
--     'selected_slot_full' iako mu je push rekao "prihvati ili odbij".
--  2) Mrtav guard `d.termin_id = z.id`: v3_trenutna_dodela.termin_id je FK na
--     v3_operativna_nedelja(id), ne na v3_zahtevi(id) — poredjenje nikad nije
--     matchovalo. Oba mesta (offer faza-2 filter i upgrade_too_late provera)
--     sada join-uju kroz v3_operativna_nedelja.
--  3) 10-min timeout vise nije trajna odbijenica: nova kolona
--     mesto_ponuda_expired_at + cooldown od 30 min. Eksplicitni "Ne" i dalje
--     setuje mesto_ponuda_odbijena (trajno). Istekla ponuda vraca putnika u
--     red posle cooldown-a, a fn_v3_expire_mesto_ponuda periodicno rescenira
--     slotove sa isteklim cooldown-om (inace bi mesto ostalo prazno do
--     sledeceg eventa).
--  4) fn_v3_offer_freed_seats zakljucava kapacitet slot (FOR UPDATE) pre
--     brojanja — serijalizuje konkurentna oslobadjanja (isti lock kao accept
--     path). Kandidati se biraju sa FOR UPDATE OF z SKIP LOCKED da ne dodje
--     do deadlock-a sa konkurentnim accept-om.
--  5) Guard u fn_v3_on_operativna_otkazano_offer_seats sada pokriva sve
--     statuse zahteva (dodata 'alternativa' i 'obrada') — transfer trigger
--     ponistava operativnu i za te statuse, pa je ranije takvo mesto
--     ostajalo neponudjeno.
--  6) Latentni bug: coalesce(v_zahtev.polazak_at, '') — ''::time pada u
--     parse-fazi pa je SVAKI upgrade accept pucao na v_old_vreme liniji.
--     Sada se polazak_at cast-uje u text pre coalesce.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 0) Nova kolona: vreme isteka poslednje mesto_ponuda ponude (cooldown marker)
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.v3_zahtevi
    ADD COLUMN IF NOT EXISTS mesto_ponuda_expired_at timestamp with time zone;

COMMENT ON COLUMN public.v3_zahtevi.mesto_ponuda_expired_at IS
'Kad je poslednja mesto_ponuda ponuda istekla bez odgovora (ili pala na kapacitetu). Cooldown 30 min pre nego se putniku ponovo ponudi.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 1) fn_v3_offer_freed_seats — slot lock, cooldown filter, mrtav-guard fix,
--    expired umesto odbijena na stale cleanup
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_grad text := upper(btrim(coalesce(p_grad, '')));
  v_vreme text := public.v3_norm_hhmm(p_vreme);
  v_now_bg timestamp;
  v_max integer := 0;
  v_occupied integer := 0;
  v_pending integer := 0;
  v_free integer := 0;
  v_offered integer := 0;
  r record;
  v_tokens jsonb;
  v_grad_label text;
  v_title text;
  v_body text;
  v_data jsonb;
  v_cur_vreme text;
BEGIN
  IF p_datum IS NULL OR v_grad = '' OR v_vreme = '' THEN
    RETURN 0;
  END IF;

  -- Istekle ponude za ovaj slot zatvoriti kao EXPIRED (cooldown), ne kao
  -- odbijene — putnik koji nije odgovorio nije eksplicitno odbio.
  UPDATE public.v3_zahtevi
  SET mesto_ponuda = false,
      mesto_ponuda_expired_at = now(),
      mesto_ponuda_at = null,
      updated_at = now()
  WHERE status IN ('odbijeno', 'odobreno')
    AND COALESCE(mesto_ponuda, false) = true
    AND COALESCE(mesto_ponuda_odbijena, false) = false
    AND COALESCE(mesto_ponuda_at, updated_at) <= now() - interval '10 minutes'
    AND datum = p_datum
    AND upper(btrim(coalesce(grad, ''))) = v_grad
    AND public.v3_norm_hhmm(trazeni_polazak_at::text) = v_vreme;

  v_now_bg := timezone('Europe/Belgrade', now());
  IF v_now_bg::date > p_datum THEN
    RETURN 0;
  END IF;
  IF v_now_bg::date = p_datum AND to_char(v_now_bg, 'HH24:MI') >= v_vreme THEN
    RETURN 0;
  END IF;

  -- Isti lock kao accept path (fn_v3_alternativa_action) — serijalizuje
  -- konkurentna oslobadjanja da ne naprave vise ponuda nego slobodnih mesta.
  PERFORM 1
  FROM public.v3_kapacitet_slots ks
  WHERE upper(btrim(ks.grad)) = v_grad
    AND ks.datum = p_datum
    AND public.v3_norm_hhmm(ks.vreme::text) = v_vreme
  FOR UPDATE;

  SELECT COALESCE(MAX(ks.max_mesta), 0)
  INTO v_max
  FROM public.v3_kapacitet_slots ks
  WHERE upper(btrim(ks.grad)) = v_grad
    AND ks.datum = p_datum
    AND public.v3_norm_hhmm(ks.vreme::text) = v_vreme;

  IF v_max <= 0 THEN
    RETURN 0;
  END IF;

  SELECT COUNT(*)::int
  INTO v_occupied
  FROM public.v3_operativna_nedelja o
  LEFT JOIN public.v3_auth a ON a.id = o.created_by
  WHERE o.datum = p_datum
    AND upper(btrim(coalesce(o.grad, ''))) = v_grad
    AND public.v3_norm_hhmm(o.polazak_at::text) = v_vreme
    AND o.otkazano_at IS NULL
    AND lower(btrim(coalesce(a.tip, ''))) <> 'posiljka';

  -- Pending drži i upgrade ponude (odobreno + mesto_ponuda) — rezervišu mesto
  -- dok putnik razmišlja, pa ne smemo ponuditi više mesta nego što ima.
  SELECT COUNT(*)::int
  INTO v_pending
  FROM public.v3_zahtevi z
  WHERE z.status IN ('odbijeno', 'odobreno')
    AND COALESCE(z.mesto_ponuda, false) = true
    AND COALESCE(z.mesto_ponuda_odbijena, false) = false
    AND z.datum = p_datum
    AND upper(btrim(coalesce(z.grad, ''))) = v_grad
    AND public.v3_norm_hhmm(z.trazeni_polazak_at::text) = v_vreme;

  v_free := v_max - v_occupied - v_pending;
  IF v_free <= 0 THEN
    RETURN 0;
  END IF;

  v_grad_label := CASE
    WHEN v_grad = 'BC' THEN 'Bela Crkva'
    WHEN v_grad = 'VS' THEN 'Vrsac'
    ELSE v_grad
  END;

  -- ─── FAZA 1: red odbijenih zahteva ──────────────────────────────────
  -- SKIP LOCKED: zahtev koji je trenutno zakljucan (npr. konkurentni accept)
  -- se preskace — izbegava deadlock sa accept pathom (zahtev->slot).
  FOR r IN
    SELECT z.id, z.created_by, z.updated_by, z.datum, z.grad, z.trazeni_polazak_at
    FROM public.v3_zahtevi z
    WHERE z.status = 'odbijeno'
      AND COALESCE(z.mesto_ponuda, false) = false
      AND COALESCE(z.mesto_ponuda_odbijena, false) = false
      AND (z.mesto_ponuda_expired_at IS NULL
           OR z.mesto_ponuda_expired_at <= now() - interval '30 minutes')
      AND z.datum = p_datum
      AND upper(btrim(coalesce(z.grad, ''))) = v_grad
      AND public.v3_norm_hhmm(z.trazeni_polazak_at::text) = v_vreme
      AND z.created_by IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.v3_auth a
        WHERE a.id = z.created_by
          AND lower(btrim(coalesce(a.tip, ''))) = 'posiljka'
      )
      AND EXISTS (
        SELECT 1
        FROM public.v3_auth a
        WHERE a.id = z.created_by
          AND (
            btrim(coalesce(a.push_token, '')) <> ''
            OR btrim(coalesce(a.push_token_2, '')) <> ''
            OR btrim(coalesce(a.push_token_3, '')) <> ''
            OR btrim(coalesce(a.push_token_hms, '')) <> ''
            OR btrim(coalesce(a.push_token_hms_2, '')) <> ''
            OR btrim(coalesce(a.push_token_hms_3, '')) <> ''
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.v3_zahtevi z2
        WHERE z2.created_by = z.created_by
          AND z2.datum = z.datum
          AND upper(btrim(coalesce(z2.grad, ''))) = v_grad
          AND z2.id <> z.id
          AND z2.status IN ('obrada', 'odobreno', 'alternativa')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.v3_zahtevi z3
        WHERE z3.created_by = z.created_by
          AND z3.datum = z.datum
          AND upper(btrim(coalesce(z3.grad, ''))) = v_grad
          AND z3.status = 'otkazano'
          AND public.v3_norm_hhmm(coalesce(z3.polazak_at, z3.trazeni_polazak_at)::text) = v_vreme
      )
    ORDER BY z.created_at ASC NULLS LAST, z.id ASC
    LIMIT v_free
    FOR UPDATE OF z SKIP LOCKED
  LOOP
    UPDATE public.v3_zahtevi
    SET mesto_ponuda = true,
        mesto_ponuda_at = now(),
        mesto_ponuda_expired_at = null,
        updated_at = now()
    WHERE id = r.id
      AND status = 'odbijeno'
      AND COALESCE(mesto_ponuda, false) = false
      AND COALESCE(mesto_ponuda_odbijena, false) = false;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    SELECT jsonb_agg(tkn)
    INTO v_tokens
    FROM (
      SELECT jsonb_build_object('token', a.push_token, 'provider', 'fcm') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token IS NOT NULL
        AND btrim(a.push_token) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token_2 IS NOT NULL
        AND btrim(a.push_token_2) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token_3 IS NOT NULL
        AND btrim(a.push_token_3) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms, 'provider', 'hms') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token_hms IS NOT NULL
        AND btrim(a.push_token_hms) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token_hms_2 IS NOT NULL
        AND btrim(a.push_token_hms_2) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.created_by
        AND a.push_token_hms_3 IS NOT NULL
        AND btrim(a.push_token_hms_3) <> ''
    ) s;

    IF v_tokens IS NULL OR jsonb_array_length(v_tokens) = 0 THEN
      v_offered := v_offered + 1;
      CONTINUE;
    END IF;

    v_title := 'Oslobodilo se mesto';
    v_body := 'Oslobodilo se mesto u terminu ' || v_vreme || ' (' || v_grad_label || '). Prihvati ili odbij.';

    v_data := jsonb_build_object(
      'type', 'v3_alternativa',
      'offer_kind', 'mesto_oslobodjeno',
      'zahtev_id', r.id,
      'recipient_id', r.created_by,
      'alt_pre', v_vreme,
      'alt_posle', '',
      'datum', r.datum,
      'grad', r.grad,
      'status', 'odbijeno',
      'screen', 'v3_putnik_profil',
      'action_pre_label', 'Prihvati',
      'action_reject_label', 'Ne',
      'title_sr', v_title,
      'title_en', 'A seat opened up',
      'title_ru', 'Освободилось место',
      'title_de', 'Ein Platz ist frei geworden',
      'title_zh', '有空位了',
      'body_sr', v_body,
      'body_en', 'A seat opened up at ' || v_vreme || ' (' || v_grad_label || '). Accept or decline.',
      'body_ru', 'Освободилось место в ' || v_vreme || ' (' || v_grad_label || '). Примите или отклоните.',
      'body_de', 'Ein Platz ist um ' || v_vreme || ' (' || v_grad_label || ') frei geworden. Annehmen oder ablehnen.',
      'body_zh', v_vreme || '（' || v_grad_label || '）有空位了。请选择接受或拒绝。'
    );

    PERFORM public.notify_push(v_tokens, v_title, v_body, v_data);
    v_offered := v_offered + 1;
  END LOOP;

  -- ─── FAZA 2: upgrade kandidati ────────────────────────────────────
  -- Putnici koji su prvobitno tražili baš ovaj oslobođeni termin, a odobreni
  -- su na neki drugi slot istog dana/grada. Dobijaju istu mesto_ponuda ponudu,
  -- ali tek kad red odbijenih iscrpi (preostala slobodna mesta).
  IF v_offered < v_free THEN
    FOR r IN
      SELECT z.id, z.created_by, z.datum, z.grad, z.trazeni_polazak_at, z.polazak_at
      FROM public.v3_zahtevi z
      WHERE z.status = 'odobreno'
        AND COALESCE(z.mesto_ponuda, false) = false
        AND COALESCE(z.mesto_ponuda_odbijena, false) = false
        AND (z.mesto_ponuda_expired_at IS NULL
             OR z.mesto_ponuda_expired_at <= now() - interval '30 minutes')
        AND z.datum = p_datum
        AND upper(btrim(coalesce(z.grad, ''))) = v_grad
        AND public.v3_norm_hhmm(coalesce(z.polazak_at, z.trazeni_polazak_at)::text) <> v_vreme
        AND (
          -- prihvatio alternativu: trazio bas ovaj termin, vozi drugi
          public.v3_norm_hhmm(z.trazeni_polazak_at::text) = v_vreme
          -- prebukirao se rucno: stariji odbijeni zahtev pokazuje sta je hteo
          OR EXISTS (
            SELECT 1
            FROM public.v3_zahtevi z0
            WHERE z0.created_by = z.created_by
              AND z0.datum = z.datum
              AND upper(btrim(coalesce(z0.grad, ''))) = v_grad
              AND z0.status = 'odbijeno'
              AND public.v3_norm_hhmm(z0.trazeni_polazak_at::text) = v_vreme
          )
        )
        AND z.created_by IS NOT NULL
        AND NOT EXISTS (
          SELECT 1
          FROM public.v3_auth a
          WHERE a.id = z.created_by
            AND lower(btrim(coalesce(a.tip, ''))) = 'posiljka'
        )
        AND EXISTS (
          SELECT 1
          FROM public.v3_auth a
          WHERE a.id = z.created_by
            AND (
              btrim(coalesce(a.push_token, '')) <> ''
              OR btrim(coalesce(a.push_token_2, '')) <> ''
              OR btrim(coalesce(a.push_token_3, '')) <> ''
              OR btrim(coalesce(a.push_token_hms, '')) <> ''
              OR btrim(coalesce(a.push_token_hms_2, '')) <> ''
              OR btrim(coalesce(a.push_token_hms_3, '')) <> ''
            )
        )
        AND NOT EXISTS (
          -- drugi zahtev u obradi/alternativi — neka se taj tok prvo razresi
          SELECT 1
          FROM public.v3_zahtevi z2
          WHERE z2.created_by = z.created_by
            AND z2.datum = z.datum
            AND upper(btrim(coalesce(z2.grad, ''))) = v_grad
            AND z2.id <> z.id
            AND z2.status IN ('obrada', 'alternativa')
        )
        AND NOT EXISTS (
          -- sam je otkazao bas taj slot — ne nuditi ga nazad
          SELECT 1
          FROM public.v3_zahtevi z3
          WHERE z3.created_by = z.created_by
            AND z3.datum = z.datum
            AND upper(btrim(coalesce(z3.grad, ''))) = v_grad
            AND z3.status = 'otkazano'
            AND public.v3_norm_hhmm(coalesce(z3.polazak_at, z3.trazeni_polazak_at)::text) = v_vreme
        )
        AND NOT EXISTS (
          -- putnik vec ima dodelu — njegova voznja je pripremljena.
          -- termin_id pokazuje na v3_operativna_nedelja.id (ne zahtev.id) —
          -- zato se dodela trazi kroz njegov aktivni operativni red.
          SELECT 1
          FROM public.v3_trenutna_dodela d
          JOIN public.v3_operativna_nedelja od ON od.id = d.termin_id
          WHERE od.created_by = z.created_by
            AND od.datum = z.datum
            AND od.otkazano_at IS NULL
            AND upper(btrim(coalesce(od.grad, ''))) = v_grad
        )
        AND NOT EXISTS (
          -- ciljni slot je vec spremljen — accept ne bi bio moguc
          SELECT 1
          FROM public.v3_trenutna_dodela_slot s
          WHERE s.datum = z.datum::date
            AND upper(btrim(coalesce(s.grad, ''))) = v_grad
            AND public.v3_norm_hhmm(s.vreme::text) = v_vreme
        )
      ORDER BY z.created_at ASC NULLS LAST, z.id ASC
      LIMIT (v_free - v_offered)
      FOR UPDATE OF z SKIP LOCKED
    LOOP
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = true,
          mesto_ponuda_at = now(),
          mesto_ponuda_expired_at = null,
          updated_at = now()
      WHERE id = r.id
        AND status = 'odobreno'
        AND COALESCE(mesto_ponuda, false) = false
        AND COALESCE(mesto_ponuda_odbijena, false) = false;

      IF NOT FOUND THEN
        CONTINUE;
      END IF;

      v_cur_vreme := public.v3_norm_hhmm(coalesce(r.polazak_at, r.trazeni_polazak_at)::text);

      SELECT jsonb_agg(tkn)
      INTO v_tokens
      FROM (
        SELECT jsonb_build_object('token', a.push_token, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token IS NOT NULL
          AND btrim(a.push_token) <> ''
        UNION
        SELECT jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token_2 IS NOT NULL
          AND btrim(a.push_token_2) <> ''
        UNION
        SELECT jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token_3 IS NOT NULL
          AND btrim(a.push_token_3) <> ''
        UNION
        SELECT jsonb_build_object('token', a.push_token_hms, 'provider', 'hms') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token_hms IS NOT NULL
          AND btrim(a.push_token_hms) <> ''
        UNION
        SELECT jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token_hms_2 IS NOT NULL
          AND btrim(a.push_token_hms_2) <> ''
        UNION
        SELECT jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms') AS tkn
        FROM public.v3_auth a
        WHERE a.id = r.created_by
          AND a.push_token_hms_3 IS NOT NULL
          AND btrim(a.push_token_hms_3) <> ''
      ) s;

      IF v_tokens IS NULL OR jsonb_array_length(v_tokens) = 0 THEN
        v_offered := v_offered + 1;
        CONTINUE;
      END IF;

      v_title := 'Oslobodilo se mesto';
      v_body := 'Oslobodilo se mesto u terminu ' || v_vreme || ' (' || v_grad_label
                || ') — termin koji ste prvobitno trazili (trenutno imate '
                || v_cur_vreme || '). Prihvati ili odbij.';

      v_data := jsonb_build_object(
        'type', 'v3_alternativa',
        'offer_kind', 'mesto_oslobodjeno',
        'offer_subtype', 'upgrade',
        'zahtev_id', r.id,
        'recipient_id', r.created_by,
        'alt_pre', v_vreme,
        'alt_posle', '',
        'trenutni_vreme', v_cur_vreme,
        'datum', r.datum,
        'grad', r.grad,
        'status', 'odobreno',
        'screen', 'v3_putnik_profil',
        'action_pre_label', 'Prihvati',
        'action_reject_label', 'Ne',
        'title_sr', v_title,
        'title_en', 'A seat opened up',
        'title_ru', 'Освободилось место',
        'title_de', 'Ein Platz ist frei geworden',
        'title_zh', '有空位了',
        'body_sr', v_body,
        'body_en', 'A seat opened up at ' || v_vreme || ' (' || v_grad_label
                   || ') — your originally requested time (you currently have '
                   || v_cur_vreme || '). Accept or decline.',
        'body_ru', 'Освободилось место в ' || v_vreme || ' (' || v_grad_label
                   || ') — изначально запрошенное время (у вас сейчас '
                   || v_cur_vreme || '). Примите или отклоните.',
        'body_de', 'Ein Platz ist um ' || v_vreme || ' (' || v_grad_label
                   || ') frei geworden — Ihre ursprünglich gewünschte Zeit (aktuell '
                   || v_cur_vreme || '). Annehmen oder ablehnen.',
        'body_zh', v_vreme || '（' || v_grad_label || '）有空位了——这是您最初请求的时间（您当前为 '
                   || v_cur_vreme || '）。请选择接受或拒绝。'
      );

      PERFORM public.notify_push(v_tokens, v_title, v_body, v_data);
      v_offered := v_offered + 1;
    END LOOP;
  END IF;

  RETURN v_offered;
END;
$$;

ALTER FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.fn_v3_offer_freed_seats(date, text, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_offer_freed_seats(date, text, text) TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2) fn_v3_expire_mesto_ponuda — expired_at umesto odbijena + rescan slotova
--    cijim kandidatima je istekao cooldown
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_v3_expire_mesto_ponuda() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  r record;
  v_expired integer := 0;
  v_vreme text;
BEGIN
  -- 1) Istekle aktivne ponude -> expired_at (cooldown), pa ponudi sledecem.
  FOR r IN
    SELECT z.id, z.datum, z.grad, z.trazeni_polazak_at
    FROM public.v3_zahtevi z
    WHERE z.status IN ('odbijeno', 'odobreno')
      AND COALESCE(z.mesto_ponuda, false) = true
      AND COALESCE(z.mesto_ponuda_odbijena, false) = false
      AND COALESCE(z.mesto_ponuda_at, z.updated_at) <= now() - interval '10 minutes'
  LOOP
    UPDATE public.v3_zahtevi
    SET mesto_ponuda = false,
        mesto_ponuda_expired_at = now(),
        mesto_ponuda_at = null,
        updated_at = now()
    WHERE id = r.id
      AND status IN ('odbijeno', 'odobreno')
      AND COALESCE(mesto_ponuda, false) = true
      AND COALESCE(mesto_ponuda_odbijena, false) = false;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_expired := v_expired + 1;
    v_vreme := public.v3_norm_hhmm(r.trazeni_polazak_at::text);
    IF r.datum IS NOT NULL AND btrim(coalesce(r.grad, '')) <> '' AND v_vreme <> '' THEN
      BEGIN
        PERFORM public.fn_v3_offer_freed_seats(
          r.datum::date,
          r.grad::text,
          v_vreme
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_v3_expire_mesto_ponuda offer: %', SQLERRM;
      END;
    END IF;
  END LOOP;

  -- 2) Rescan: slotovi sa kandidatima ciji je cooldown istekao. Bez ovoga bi
  --    putnik cija je ponuda istekla ostao neponudjen do sledeceg eventa
  --    (novo otkazivanje / capacity bump), a mesto bi dzabalezarilo.
  --    Idempotentno: offer fn sam izlazi ako nema slobodnih mesta ili je
  --    termin prosao.
  FOR r IN
    SELECT DISTINCT z.datum, z.grad,
           public.v3_norm_hhmm(z.trazeni_polazak_at::text) AS vreme
    FROM public.v3_zahtevi z
    WHERE z.status IN ('odbijeno', 'odobreno')
      AND COALESCE(z.mesto_ponuda, false) = false
      AND COALESCE(z.mesto_ponuda_odbijena, false) = false
      AND z.mesto_ponuda_expired_at IS NOT NULL
      AND z.mesto_ponuda_expired_at <= now() - interval '30 minutes'
  LOOP
    IF r.datum IS NOT NULL AND btrim(coalesce(r.grad, '')) <> '' AND r.vreme <> '' THEN
      BEGIN
        PERFORM public.fn_v3_offer_freed_seats(
          r.datum::date,
          r.grad::text,
          r.vreme
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_v3_expire_mesto_ponuda rescan: %', SQLERRM;
      END;
    END IF;
  END LOOP;

  RETURN v_expired;
END;
$$;

ALTER FUNCTION public.fn_v3_expire_mesto_ponuda() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.fn_v3_expire_mesto_ponuda() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_expire_mesto_ponuda() TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3) fn_v3_on_operativna_otkazano_offer_seats — guard pokriva sve statuse
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_vreme text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.otkazano_at IS NULL
     AND NEW.otkazano_at IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.v3_auth a
      WHERE a.id = NEW.created_by
        AND lower(btrim(coalesce(a.tip, ''))) = 'posiljka'
    ) THEN
      RETURN NEW;
    END IF;

    v_vreme := public.v3_norm_hhmm(COALESCE(NEW.polazak_at, OLD.polazak_at)::text);
    IF v_vreme = '' THEN
      RETURN NEW;
    END IF;

    -- otkazano = otkazana vožnja; odbijeno = odbijen zahtev. Nije isto.
    -- Ponudu šaljemo samo kad je mesto stvarno otkazano, ne kad je zahtev odbijen.
    -- 'odbijeno' je uključeno jer kod odbijanja alternative putnikov zahtev
    -- prelazi u 'odbijeno' pre nego što se operativna otkaže — i tada je mesto
    -- stvarno slobodno pa treba da se ponudi sledećem.
    -- Svi statusi su pokriveni: transfer_to_operativna_nedelja ponistava
    -- operativni red i za 'obrada'/'alternativa', pa bi ih izostavljanje
    -- ostavilo oslobodjeno mesto neponudjeno.
    IF NOT EXISTS (
      SELECT 1
      FROM public.v3_zahtevi z
      WHERE z.created_by = NEW.created_by
        AND z.datum = NEW.datum::date
        AND upper(btrim(coalesce(z.grad, ''))) = upper(btrim(coalesce(NEW.grad, '')))
        AND public.v3_norm_hhmm(coalesce(z.polazak_at, z.trazeni_polazak_at)::text) = v_vreme
        AND z.status IN ('otkazano', 'odobreno', 'odbijeno', 'alternativa', 'obrada')
    ) THEN
      RETURN NEW;
    END IF;

    BEGIN
      PERFORM public.fn_v3_offer_freed_seats(
        NEW.datum::date,
        NEW.grad::text,
        v_vreme
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'fn_v3_offer_freed_seats: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() FROM public, anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4) process_pending_zahtevi_slots — pending mesto_ponuda ponude se racunaju
--    u zauzetost (approve path vidi rezervacije)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_pending_zahtevi_slots(p_ignore_schedule boolean DEFAULT false)
RETURNS TABLE(processed integer, approved integer, alternative integer, message text)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
    zahtev_record record;
    current_ts timestamptz := now();
    v_now_bg timestamp := timezone('Europe/Belgrade', now());
    v_today_bg date := v_now_bg::date;
    v_now_hhmm text := to_char(v_now_bg, 'HH24:MI');
    processed int := 0;
    approved int := 0;
    alternative int := 0;
    capacity_check boolean;
    should_approve boolean;
    slot_past boolean;
    max_kapacitet integer;
    existing_mesta integer;
    pending_ponude integer;
    best_alt_pre time;
    best_alt_posle time;
    alt_reason text;
    v_trazeni time;
begin
    for zahtev_record in
        select z.*, a.tip as tip_putnika, a.ime as ime_prezime
        from v3_zahtevi z
        left join v3_auth a on a.id = z.created_by
        where z.status = 'obrada'
          and (p_ignore_schedule
               or (z.scheduled_at is not null and z.scheduled_at <= current_ts))
          and not exists (
              select 1
              from public.v3_app_settings s
              cross join lateral jsonb_array_elements(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_obj)
              where d.day_obj->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
                and (d.day_obj->>'date')::date = z.datum::date
                and (
                  lower(btrim(coalesce(d.day_obj->>'scope', 'all'))) = 'all'
                  or upper(btrim(coalesce(d.day_obj->>'scope', ''))) = upper(btrim(z.grad))
                )
          )
        order by z.scheduled_at asc nulls last, z.created_at asc, z.id asc
        for update of z skip locked
    loop
        should_approve := true;
        capacity_check := true;
        best_alt_pre := null;
        best_alt_posle := null;
        alt_reason := 'Trenutno nema slobodnih mesta za zeljeni termin.';
        pending_ponude := 0;

        v_trazeni := zahtev_record.trazeni_polazak_at;

        -- Termin koji je vec prosao (ili datum u proslosti) ne sme biti
        -- odobren; nude se samo alternative u buducnosti.
        slot_past := zahtev_record.datum::date < v_today_bg
                     or (zahtev_record.datum::date = v_today_bg
                         and v_trazeni is not null
                         and public.v3_norm_hhmm(v_trazeni::text) <= v_now_hhmm);

        if slot_past then
            should_approve := false;
            alt_reason := 'Zeljeni termin je vec prosao.';
        end if;

        if zahtev_record.tip_putnika = 'posiljka' then
            capacity_check := false;
        end if;

        if capacity_check and not slot_past then
            -- Isti lock redosled kao fn_v3_alternativa_action (zahtev -> slot):
            -- serijalizuje approve path sa konkurentnim accept-ima.
            perform 1
            from v3_kapacitet_slots ks
            where ks.grad = zahtev_record.grad
              and ks.vreme = v_trazeni
              and ks.datum = zahtev_record.datum::date
            for update;

            select ks.max_mesta into max_kapacitet
            from v3_kapacitet_slots ks
            where ks.grad = zahtev_record.grad
              and ks.vreme = v_trazeni
              and ks.datum = zahtev_record.datum::date
            limit 1;

            if max_kapacitet is null then
                -- Datum bez ijednog slot reda = raspored jos nije zasejan
                -- (buduca nedelja) -> sacekaj seeding. Ako datum vec ima
                -- slotove, trazeni termin nije u rasporedu -> idi na
                -- alternativu/odbijeno umesto beskonacnog cekanja.
                if v_trazeni is not null
                   and zahtev_record.datum::date >= v_today_bg
                   and not exists (
                       select 1
                       from v3_kapacitet_slots ks2
                       where ks2.datum = zahtev_record.datum::date
                   ) then
                    continue;
                end if;
                should_approve := false;
                alt_reason := 'Trazeni termin nije u rasporedu.';
            else
                select count(*)::int into existing_mesta
                from v3_operativna_nedelja o
                left join v3_auth pa on pa.id = o.created_by
                where o.datum::date = zahtev_record.datum::date
                  and o.grad = zahtev_record.grad
                  and o.polazak_at = v_trazeni
                  and o.otkazano_at is null
                  and lower(btrim(coalesce(pa.tip, ''))) <> 'posiljka';

                -- Aktivne mesto_ponuda ponude za ovaj slot su soft-rezervacija:
                -- nosaocu ponude ne sme "otici" mesto dok razmislja (inace mu
                -- accept puca na selected_slot_full posle push-a).
                select count(*)::int into pending_ponude
                from v3_zahtevi zp
                where zp.status in ('odbijeno', 'odobreno')
                  and coalesce(zp.mesto_ponuda, false)
                  and not coalesce(zp.mesto_ponuda_odbijena, false)
                  and zp.datum = zahtev_record.datum::date
                  and zp.grad = zahtev_record.grad
                  and zp.trazeni_polazak_at = v_trazeni;

                if (existing_mesta + pending_ponude + 1) > max_kapacitet then
                    should_approve := false;
                end if;
            end if;
        end if;

        processed := processed + 1;

        if should_approve then
            update v3_zahtevi
            set status = 'odobreno',
                polazak_at = v_trazeni,
                alternativa_pre_at = null,
                alternativa_posle_at = null,
                alternativa_offered_at = null,
                updated_at = current_ts,
                updated_by = '4feffa3a-8b4d-4e28-9b8b-c0af3c48ea4e'::uuid
            where id = zahtev_record.id;
            approved := approved + 1;
        else
            if capacity_check then
                -- Alternative samo iz slotova koji jos nisu prosli (istog dana);
                -- za buduce datume svi slotovi vaze. used_mesta ukljucuje i
                -- aktivne mesto_ponuda ponude (soft-rezervacije).
                with usage_by_slot as (
                    select ks.vreme, ks.max_mesta,
                           coalesce(occ.used_mesta, 0) + coalesce(po.ponude, 0) as used_mesta
                    from v3_kapacitet_slots ks
                    left join (
                        select o.polazak_at as vreme, count(*)::int as used_mesta
                        from v3_operativna_nedelja o
                        left join v3_auth pa on pa.id = o.created_by
                        where o.datum::date = zahtev_record.datum::date
                          and o.grad = zahtev_record.grad
                          and o.otkazano_at is null
                          and o.polazak_at is not null
                          and lower(btrim(coalesce(pa.tip, ''))) <> 'posiljka'
                        group by o.polazak_at
                    ) occ on occ.vreme = ks.vreme
                    left join (
                        select zp.trazeni_polazak_at as vreme, count(*)::int as ponude
                        from v3_zahtevi zp
                        where zp.datum = zahtev_record.datum::date
                          and zp.grad = zahtev_record.grad
                          and zp.status in ('odbijeno', 'odobreno')
                          and coalesce(zp.mesto_ponuda, false)
                          and not coalesce(zp.mesto_ponuda_odbijena, false)
                          and zp.trazeni_polazak_at is not null
                        group by zp.trazeni_polazak_at
                    ) po on po.vreme = ks.vreme
                    where ks.grad = zahtev_record.grad
                      and ks.datum = zahtev_record.datum::date
                )
                select max(vreme) into best_alt_pre
                from usage_by_slot
                where vreme < v_trazeni
                  and vreme >= (v_trazeni - interval '180 minutes')
                  and (used_mesta + 1) <= max_mesta
                  and (zahtev_record.datum::date > v_today_bg
                       or public.v3_norm_hhmm(vreme::text) > v_now_hhmm);

                with usage_by_slot as (
                    select ks.vreme, ks.max_mesta,
                           coalesce(occ.used_mesta, 0) + coalesce(po.ponude, 0) as used_mesta
                    from v3_kapacitet_slots ks
                    left join (
                        select o.polazak_at as vreme, count(*)::int as used_mesta
                        from v3_operativna_nedelja o
                        left join v3_auth pa on pa.id = o.created_by
                        where o.datum::date = zahtev_record.datum::date
                          and o.grad = zahtev_record.grad
                          and o.otkazano_at is null
                          and o.polazak_at is not null
                          and lower(btrim(coalesce(pa.tip, ''))) <> 'posiljka'
                        group by o.polazak_at
                    ) occ on occ.vreme = ks.vreme
                    left join (
                        select zp.trazeni_polazak_at as vreme, count(*)::int as ponude
                        from v3_zahtevi zp
                        where zp.datum = zahtev_record.datum::date
                          and zp.grad = zahtev_record.grad
                          and zp.status in ('odbijeno', 'odobreno')
                          and coalesce(zp.mesto_ponuda, false)
                          and not coalesce(zp.mesto_ponuda_odbijena, false)
                          and zp.trazeni_polazak_at is not null
                        group by zp.trazeni_polazak_at
                    ) po on po.vreme = ks.vreme
                    where ks.grad = zahtev_record.grad
                      and ks.datum = zahtev_record.datum::date
                )
                select min(vreme) into best_alt_posle
                from usage_by_slot
                where vreme > v_trazeni
                  and (
                    vreme <= (v_trazeni + interval '180 minutes')
                    -- wrap preko ponoci: bound < trazeni znaci da je window
                    -- [trazeni, 24:00) — svaki kasniji slot tog dana je u oknu
                    or (v_trazeni + interval '180 minutes') <= v_trazeni
                  )
                  and (used_mesta + 1) <= max_mesta
                  and (zahtev_record.datum::date > v_today_bg
                       or public.v3_norm_hhmm(vreme::text) > v_now_hhmm);
            end if;

            if best_alt_pre is not null and best_alt_posle is not null then
                alt_reason := 'Trenutno nema slobodnih mesta za zeljeni termin, ali imate slobodne termine pre i posle.';
            elsif best_alt_pre is not null then
                alt_reason := 'Trenutno nema slobodnih mesta za zeljeni termin, ali imate slobodan raniji termin.';
            elsif best_alt_posle is not null then
                alt_reason := 'Trenutno nema slobodnih mesta za zeljeni termin, ali imate slobodan kasniji termin.';
            else
                alt_reason := alt_reason || ' Nema slobodnih termina pre/posle.';
            end if;

            if best_alt_pre is null and best_alt_posle is null then
                update v3_zahtevi
                set status = 'odbijeno',
                    alternativa_pre_at = null,
                    alternativa_posle_at = null,
                    alternativa_offered_at = null,
                    updated_at = current_ts,
                    updated_by = '4feffa3a-8b4d-4e28-9b8b-c0af3c48ea4e'::uuid
                where id = zahtev_record.id;
            else
                update v3_zahtevi
                set status = 'alternativa',
                    alternativa_pre_at = best_alt_pre,
                    alternativa_posle_at = best_alt_posle,
                    alternativa_offered_at = current_ts,
                    updated_at = current_ts,
                    updated_by = '4feffa3a-8b4d-4e28-9b8b-c0af3c48ea4e'::uuid
                where id = zahtev_record.id;
                alternative := alternative + 1;
            end if;
        end if;
    end loop;

    return query select
        processed,
        approved,
        alternative,
        format('Obradjeno %s zahteva - %s odobreno, %s alternativa', processed, approved, alternative);
end;
$_$;

ALTER FUNCTION public.process_pending_zahtevi_slots(p_ignore_schedule boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.process_pending_zahtevi_slots(p_ignore_schedule boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_pending_zahtevi_slots(p_ignore_schedule boolean) TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5) fn_v3_alternativa_action — mrtav-guard fix (upgrade_too_late) +
--    expired_at umesto odbijena na svim ne-reject zatvaranjima ponude
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text DEFAULT ''::text, p_hardware_id text DEFAULT ''::text, p_installation_id text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_zahtev public.v3_zahtevi%ROWTYPE;
  v_auth public.v3_auth%ROWTYPE;
  v_auth_found boolean;
  v_status text;
  v_is_mesto boolean;
  v_is_upgrade boolean;
  v_is_posiljka boolean;
  v_selected text;
  v_old_vreme text;
  v_grad text;
  v_max integer := 0;
  v_occupied integer := 0;
  v_device_ok boolean;
  v_has_device_identity boolean;
  v_offer_kind text := '';
  v_now_bg timestamp;
BEGIN
  IF p_zahtev_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_zahtev_id');
  END IF;

  IF p_action IS NULL OR p_action NOT IN ('accept_pre', 'accept_posle', 'reject') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_action');
  END IF;

  SELECT * INTO v_zahtev
  FROM public.v3_zahtevi z
  WHERE z.id = p_zahtev_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'zahtev_not_found');
  END IF;

  SELECT * INTO v_auth FROM public.v3_auth a WHERE a.id = v_zahtev.created_by;
  v_auth_found := FOUND;

  IF v_auth_found THEN
    v_device_ok := coalesce(
      (btrim(coalesce(p_device_token, '')) <> '' AND p_device_token IN (
        v_auth.push_token, v_auth.push_token_2, v_auth.push_token_3, v_auth.push_token_hms, v_auth.push_token_hms_2, v_auth.push_token_hms_3))
      OR (btrim(coalesce(p_hardware_id, '')) <> '' AND p_hardware_id IN (
        v_auth.hardware_id, v_auth.hardware_id_2, v_auth.hardware_id_3))
      OR (btrim(coalesce(p_installation_id, '')) <> '' AND p_installation_id IN (
        v_auth.installation_id, v_auth.installation_id_2, v_auth.installation_id_3)),
      false
    );

    v_has_device_identity :=
      btrim(coalesce(v_auth.push_token, '')) <> ''
      OR btrim(coalesce(v_auth.push_token_2, '')) <> ''
      OR btrim(coalesce(v_auth.push_token_3, '')) <> ''
      OR btrim(coalesce(v_auth.push_token_hms, '')) <> ''
      OR btrim(coalesce(v_auth.push_token_hms_2, '')) <> ''
      OR btrim(coalesce(v_auth.push_token_hms_3, '')) <> ''
      OR btrim(coalesce(v_auth.hardware_id, '')) <> ''
      OR btrim(coalesce(v_auth.hardware_id_2, '')) <> ''
      OR btrim(coalesce(v_auth.hardware_id_3, '')) <> ''
      OR btrim(coalesce(v_auth.installation_id, '')) <> ''
      OR btrim(coalesce(v_auth.installation_id_2, '')) <> ''
      OR btrim(coalesce(v_auth.installation_id_3, '')) <> '';

    IF v_has_device_identity AND NOT v_device_ok THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unauthorized');
    END IF;
  END IF;

  v_status := lower(btrim(coalesce(v_zahtev.status, '')));
  v_is_mesto := coalesce(v_zahtev.mesto_ponuda, false) AND v_status = 'odbijeno';
  -- Upgrade ponuda: odobren zahtev (drugi termin) sa mesto_ponuda flagom.
  v_is_upgrade := coalesce(v_zahtev.mesto_ponuda, false) AND v_status = 'odobreno';
  IF v_is_mesto OR v_is_upgrade THEN
    v_offer_kind := 'mesto_oslobodjeno';
  END IF;

  IF v_status <> 'alternativa' AND NOT v_is_mesto AND NOT v_is_upgrade THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'zahtev_not_in_alternativa', 'status', v_status);
  END IF;

  -- Inline expiry i za obicnu 'alternativa' ponudu — ne oslanjamo se samo na
  -- cron (expire_unanswered_alternativa_10m); zastarela ponuda se zatvara
  -- odmah, identicno cron putanji.
  IF v_status = 'alternativa'
     AND coalesce(v_zahtev.alternativa_offered_at, v_zahtev.updated_at) <= now() - interval '10 minutes' THEN
    UPDATE public.v3_zahtevi
    SET status = 'odbijeno',
        alternativa_pre_at = null,
        alternativa_posle_at = null,
        alternativa_offered_at = null,
        updated_at = now()
    WHERE id = v_zahtev.id;

    RETURN jsonb_build_object('ok', false, 'reason', 'offer_expired', 'offer_kind', 'alternativa');
  END IF;

  IF (v_is_mesto OR v_is_upgrade)
     AND coalesce(v_zahtev.mesto_ponuda_at, v_zahtev.updated_at) <= now() - interval '10 minutes' THEN
    -- Expired (cooldown), ne odbijena — putnik se vraca u red posle 30 min.
    UPDATE public.v3_zahtevi
    SET mesto_ponuda = false,
        mesto_ponuda_expired_at = now(),
        mesto_ponuda_at = null,
        updated_at = now()
    WHERE id = v_zahtev.id;

    IF v_zahtev.datum IS NOT NULL
       AND btrim(coalesce(v_zahtev.grad, '')) <> ''
       AND v_zahtev.trazeni_polazak_at IS NOT NULL THEN
      BEGIN
        PERFORM public.fn_v3_offer_freed_seats(
          v_zahtev.datum,
          v_zahtev.grad::text,
          public.v3_norm_hhmm(v_zahtev.trazeni_polazak_at::text)
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_v3_alternativa_action offer next: %', SQLERRM;
      END;
    END IF;

    RETURN jsonb_build_object('ok', false, 'reason', 'offer_expired', 'offer_kind', 'mesto_oslobodjeno');
  END IF;

  IF p_action = 'reject' THEN
    IF v_is_mesto OR v_is_upgrade THEN
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = false,
          mesto_ponuda_odbijena = true,
          mesto_ponuda_at = null,
          updated_at = now()
      WHERE id = v_zahtev.id;

      IF v_zahtev.datum IS NOT NULL
         AND btrim(coalesce(v_zahtev.grad, '')) <> ''
         AND v_zahtev.trazeni_polazak_at IS NOT NULL THEN
        BEGIN
          PERFORM public.fn_v3_offer_freed_seats(
            v_zahtev.datum,
            v_zahtev.grad::text,
            public.v3_norm_hhmm(v_zahtev.trazeni_polazak_at::text)
          );
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'fn_v3_alternativa_action offer next: %', SQLERRM;
        END;
      END IF;

      RETURN jsonb_build_object('ok', true, 'action', 'reject', 'zahtev_id', v_zahtev.id, 'offer_kind', 'mesto_oslobodjeno');
    END IF;

    UPDATE public.v3_zahtevi
    SET status = 'odbijeno',
        alternativa_pre_at = null,
        alternativa_posle_at = null,
        alternativa_offered_at = null,
        updated_at = now()
    WHERE id = v_zahtev.id;

    RETURN jsonb_build_object('ok', true, 'action', 'reject', 'zahtev_id', v_zahtev.id);
  END IF;

  v_selected := CASE
    WHEN v_is_mesto OR v_is_upgrade THEN public.v3_norm_hhmm(v_zahtev.trazeni_polazak_at::text)
    WHEN p_action = 'accept_pre' THEN public.v3_norm_hhmm(v_zahtev.alternativa_pre_at::text)
    ELSE public.v3_norm_hhmm(v_zahtev.alternativa_posle_at::text)
  END;

  IF v_selected = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'selected_alternativa_missing', 'action', p_action);
  END IF;

  -- Termin koji je vec prosao (po Beogradu) ne sme biti prihvacen — ista
  -- granica kao u fn_v3_offer_freed_seats. Ponuda se pritom zatvara:
  -- alternativa -> 'odbijeno' (kao expiry), mesto ponuda -> cisti se flag.
  v_now_bg := timezone('Europe/Belgrade', now());
  IF v_zahtev.datum IS NOT NULL
     AND (v_zahtev.datum::date < v_now_bg::date
          OR (v_zahtev.datum::date = v_now_bg::date
              AND v_selected <= to_char(v_now_bg, 'HH24:MI'))) THEN
    IF v_is_mesto OR v_is_upgrade THEN
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = false, mesto_ponuda_expired_at = now(), mesto_ponuda_at = null, updated_at = now()
      WHERE id = v_zahtev.id;
    ELSIF v_status = 'alternativa' THEN
      UPDATE public.v3_zahtevi
      SET status = 'odbijeno',
          alternativa_pre_at = null,
          alternativa_posle_at = null,
          alternativa_offered_at = null,
          updated_at = now()
      WHERE id = v_zahtev.id;
    END IF;

    RETURN jsonb_build_object('ok', false, 'reason', 'selected_slot_past',
                              'selected_time', v_selected, 'offer_kind', v_offer_kind);
  END IF;

  v_is_posiljka := v_auth_found AND lower(btrim(coalesce(v_auth.tip, ''))) = 'posiljka';
  v_grad := upper(btrim(coalesce(v_zahtev.grad, '')));

  IF NOT v_is_posiljka THEN
    PERFORM 1
    FROM public.v3_kapacitet_slots ks
    WHERE upper(btrim(ks.grad)) = v_grad
      AND ks.datum = v_zahtev.datum
      AND public.v3_norm_hhmm(ks.vreme::text) = v_selected
    FOR UPDATE;

    SELECT COALESCE(MAX(ks.max_mesta), 0)
    INTO v_max
    FROM public.v3_kapacitet_slots ks
    WHERE upper(btrim(ks.grad)) = v_grad
      AND ks.datum = v_zahtev.datum
      AND public.v3_norm_hhmm(ks.vreme::text) = v_selected;

    IF v_max <= 0 THEN
      IF v_is_mesto OR v_is_upgrade THEN
        UPDATE public.v3_zahtevi
        SET mesto_ponuda = false, mesto_ponuda_expired_at = now(), mesto_ponuda_at = null, updated_at = now()
        WHERE id = v_zahtev.id;
      END IF;
      RETURN jsonb_build_object('ok', false, 'reason', 'no_capacity_slot', 'selected_time', v_selected,
                                'offer_kind', v_offer_kind);
    END IF;

    SELECT COUNT(*)::int
    INTO v_occupied
    FROM public.v3_operativna_nedelja o
    LEFT JOIN public.v3_auth a ON a.id = o.created_by
    WHERE o.datum = v_zahtev.datum
      AND upper(btrim(coalesce(o.grad, ''))) = v_grad
      AND public.v3_norm_hhmm(o.polazak_at::text) = v_selected
      AND o.otkazano_at IS NULL
      AND lower(btrim(coalesce(a.tip, ''))) <> 'posiljka';

    IF v_occupied >= v_max THEN
      IF v_is_mesto OR v_is_upgrade THEN
        UPDATE public.v3_zahtevi
        SET mesto_ponuda = false, mesto_ponuda_expired_at = now(), mesto_ponuda_at = null, updated_at = now()
        WHERE id = v_zahtev.id;
      END IF;
      RETURN jsonb_build_object('ok', false, 'reason', 'selected_slot_full', 'selected_time', v_selected,
                                'max_mesta', v_max, 'occupied', v_occupied,
                                'offer_kind', v_offer_kind);
    END IF;
  END IF;

  IF v_is_upgrade THEN
    -- polazak_at cast-ovati u text PRE coalesce — ''::time u parse-fazi pada.
    v_old_vreme := public.v3_norm_hhmm(coalesce(v_zahtev.polazak_at::text, ''));

    -- Premestanje je nemoguce kad je vožnja vec pripremljena: putnik ima
    -- dodelu za svoj termin ili je ciljni slot vec u v3_trenutna_dodela_slot.
    -- NAPOMENA: v3_trenutna_dodela.termin_id pokazuje na operativnu stavku
    -- (FK -> v3_operativna_nedelja.id), ne na zahtev — zato join kroz nju.
    IF EXISTS (
         SELECT 1
         FROM public.v3_trenutna_dodela d
         JOIN public.v3_operativna_nedelja o ON o.id = d.termin_id
         WHERE o.created_by = v_zahtev.created_by
           AND o.datum = v_zahtev.datum::date
           AND o.otkazano_at IS NULL
           AND upper(btrim(coalesce(o.grad, ''))) = v_grad
       )
       OR EXISTS (SELECT 1 FROM public.v3_trenutna_dodela_slot s
                  WHERE s.datum = v_zahtev.datum::date
                    AND upper(btrim(coalesce(s.grad, ''))) = v_grad
                    AND public.v3_norm_hhmm(s.vreme::text) = v_selected) THEN
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = false, mesto_ponuda_expired_at = now(), mesto_ponuda_at = null, updated_at = now()
      WHERE id = v_zahtev.id;
      RETURN jsonb_build_object('ok', false, 'reason', 'upgrade_too_late', 'offer_kind', v_offer_kind);
    END IF;

    -- Aktivna operativna stavka mora postojati — ako je putniku vožnja u
    -- medjuvremenu otkazana, nemamo sta da pomeramo.
    IF NOT EXISTS (SELECT 1 FROM public.v3_operativna_nedelja o
                   WHERE o.created_by = v_zahtev.created_by
                     AND o.datum = v_zahtev.datum::date
                     AND upper(btrim(coalesce(o.grad, ''))) = v_grad
                     AND o.otkazano_at IS NULL) THEN
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = false, mesto_ponuda_expired_at = now(), mesto_ponuda_at = null, updated_at = now()
      WHERE id = v_zahtev.id;
      RETURN jsonb_build_object('ok', false, 'reason', 'upgrade_operativna_missing', 'offer_kind', v_offer_kind);
    END IF;

    -- Status ostaje 'odobreno'; samo se termin pomera na oslobođeni (trazeni).
    -- Trigger transfer_to_operativna_nedelja pomera i operativnu stavku.
    UPDATE public.v3_zahtevi
    SET polazak_at = v_selected::time,
        mesto_ponuda = false,
        mesto_ponuda_at = null,
        mesto_ponuda_expired_at = null,
        updated_at = now()
    WHERE id = v_zahtev.id;

    -- Kaskada: staro mesto se oslobodilo — ponudi ga sledećem u redu.
    IF v_old_vreme <> '' AND v_old_vreme <> v_selected THEN
      BEGIN
        PERFORM public.fn_v3_offer_freed_seats(
          v_zahtev.datum::date,
          v_grad,
          v_old_vreme
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'fn_v3_alternativa_action upgrade cascade: %', SQLERRM;
      END;
    END IF;

    RETURN jsonb_build_object('ok', true, 'action', p_action, 'zahtev_id', v_zahtev.id,
                              'selected_time', v_selected, 'previous_time', v_old_vreme,
                              'offer_kind', v_offer_kind);
  END IF;

  UPDATE public.v3_zahtevi
  SET status = 'odobreno',
      polazak_at = v_selected::time,
      alternativa_pre_at = null,
      alternativa_posle_at = null,
      alternativa_offered_at = null,
      mesto_ponuda = false,
      mesto_ponuda_at = null,
      mesto_ponuda_expired_at = null,
      updated_at = now()
  WHERE id = v_zahtev.id;

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'zahtev_id', v_zahtev.id,
                            'selected_time', v_selected, 'offer_kind', v_offer_kind);
END;
$$;

ALTER FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.fn_v3_alternativa_action(uuid, text, text, text, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_alternativa_action(uuid, text, text, text, text) TO service_role;
