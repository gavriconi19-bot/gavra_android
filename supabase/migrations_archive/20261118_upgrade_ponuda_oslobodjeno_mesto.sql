-- Upgrade ponude za oslobođeno mesto:
--
-- Do sada je fn_v3_offer_freed_seats nudio oslobođeno mesto samo putnicima
-- čiji je zahtev za baš taj termin bio 'odbijeno'. Sada, tek kad se taj red
-- iscrpi (odbijeni zadržavaju apsolutni prioritet — njima mesto najviše treba),
-- nudimo ga i putnicima koji su prvobitno tražili baš taj termin, a odobreni
-- su na neki drugi slot istog dana/grada (prihvatili alternativu ili se
-- naknadno prebukirali).
--
-- Prihvatanje takve ponude = premestanje na željeni termin: operativna stavka
-- se pomera preko postojećeg trigera transfer_to_operativna_nedelja (polazak_at
-- na odobrenom zahtevu), a oslobođeni stari slot se kaskadno nudi sledećem
-- u redu.
--
-- Ponude se ne šalju (i accept se odbija) ako je vožnja već pripremljena —
-- postoji v3_trenutna_dodela za taj zahtev ili v3_trenutna_dodela_slot za
-- ciljni slot — jer bi tada premestanje razbilo već izračunatu rutu vozača.

CREATE OR REPLACE FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

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

  -- Istekle ponude za ovaj slot (odbijeni + upgrade) prvo zatvoriti.
  UPDATE public.v3_zahtevi
  SET mesto_ponuda = false,
      mesto_ponuda_odbijena = true,
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

  -- ─── FAZA 1: red odbijenih zahteva (nepromenjeno) ───────────────────
  FOR r IN
    SELECT z.id, z.created_by, z.updated_by, z.datum, z.grad, z.trazeni_polazak_at
    FROM public.v3_zahtevi z
    WHERE z.status = 'odbijeno'
      AND COALESCE(z.mesto_ponuda, false) = false
      AND COALESCE(z.mesto_ponuda_odbijena, false) = false
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
  LOOP
    UPDATE public.v3_zahtevi
    SET mesto_ponuda = true,
        mesto_ponuda_at = now(),
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
          -- putnik vec ima dodelu — njegova voznja je pripremljena
          SELECT 1
          FROM public.v3_trenutna_dodela d
          WHERE d.termin_id = z.id
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
    LOOP
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = true,
          mesto_ponuda_at = now(),
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
$function$;

-- Istek upgrade ponuda isto kao i odbijenih: posle 10 min bez odgovora
-- zatvara se i mesto se nudi sledećem u redu.
CREATE OR REPLACE FUNCTION public.fn_v3_expire_mesto_ponuda()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_expired integer := 0;
  v_vreme text;
BEGIN
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
        mesto_ponuda_odbijena = true,
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

  RETURN v_expired;
END;
$function$;

-- fn_v3_alternativa_action: nova grana za upgrade ponude (odobreno + mesto_ponuda).
-- Reject/expire rade isto kao za odbijene; accept = premestanje na trazeni
-- (oslobođeni) termin uz kaskadnu ponudu oslobođenog starog slota.
CREATE OR REPLACE FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text DEFAULT ''::text, p_hardware_id text DEFAULT ''::text, p_installation_id text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

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

  IF (v_is_mesto OR v_is_upgrade)
     AND coalesce(v_zahtev.mesto_ponuda_at, v_zahtev.updated_at) <= now() - interval '10 minutes' THEN
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
        SET mesto_ponuda = false, mesto_ponuda_at = null, updated_at = now()
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
        SET mesto_ponuda = false, mesto_ponuda_at = null, updated_at = now()
        WHERE id = v_zahtev.id;
      END IF;
      RETURN jsonb_build_object('ok', false, 'reason', 'selected_slot_full', 'selected_time', v_selected,
                                'max_mesta', v_max, 'occupied', v_occupied,
                                'offer_kind', v_offer_kind);
    END IF;
  END IF;

  IF v_is_upgrade THEN
    v_old_vreme := public.v3_norm_hhmm(coalesce(v_zahtev.polazak_at, '')::text);

    -- Premestanje je nemoguce kad je vožnja vec pripremljena: putnik ima
    -- dodelu za svoj termin ili je ciljni slot vec u v3_trenutna_dodela_slot.
    IF EXISTS (SELECT 1 FROM public.v3_trenutna_dodela d WHERE d.termin_id = v_zahtev.id)
       OR EXISTS (SELECT 1 FROM public.v3_trenutna_dodela_slot s
                  WHERE s.datum = v_zahtev.datum::date
                    AND upper(btrim(coalesce(s.grad, ''))) = v_grad
                    AND public.v3_norm_hhmm(s.vreme::text) = v_selected) THEN
      UPDATE public.v3_zahtevi
      SET mesto_ponuda = false, mesto_ponuda_odbijena = true, mesto_ponuda_at = null, updated_at = now()
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
      SET mesto_ponuda = false, mesto_ponuda_odbijena = true, mesto_ponuda_at = null, updated_at = now()
      WHERE id = v_zahtev.id;
      RETURN jsonb_build_object('ok', false, 'reason', 'upgrade_operativna_missing', 'offer_kind', v_offer_kind);
    END IF;

    -- Status ostaje 'odobreno'; samo se termin pomera na oslobođeni (trazeni).
    -- Trigger transfer_to_operativna_nedelja pomera i operativnu stavku.
    UPDATE public.v3_zahtevi
    SET polazak_at = v_selected::time,
        mesto_ponuda = false,
        mesto_ponuda_at = null,
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
      updated_at = now()
  WHERE id = v_zahtev.id;

  RETURN jsonb_build_object('ok', true, 'action', p_action, 'zahtev_id', v_zahtev.id,
                            'selected_time', v_selected, 'offer_kind', v_offer_kind);
END;
$function$;
