-- Fix-ovi tracking/push audit-a:
-- 1) v3_notify_passengers_driver_started: device-identity provera pozivaoca
--    (isti OR-pattern kao fn_v3_alternativa_action — device_token/hardware_id/
--    installation_id protiv VOZAC-evih v3_auth slotova). Ranije je anon GRANT +
--    SECURITY DEFINER omogucavao bilo kome sa anon kljucem da claim-uje
--    driver_started_notified_at za tudji termin: putnici bi dobili prerani push,
--    a pravi start vise ne bi slao nista (flag vec set).
--    NAPOMENA: poziv bez ijednog identity parama se odbija kad vozac ima
--    zabelezen identity (a vozac koji track-uje ga uvek ima, jer je morao da
--    se uloguje) — stare app verzije koje ne salju parametre dobijaju
--    ok=false/unauthorized; tracking im i dalje radi, samo push putnicima
--    ne izlazi dok se ne azuriraju.
-- 2) notify_push: siguran data_only cast — ranije
--    (payload_data->>'data_only')::boolean je bacala exception za
--    ne-boolean vrednosti pa se push tiho gubio kroz WHEN OTHERS.

CREATE OR REPLACE FUNCTION public.v3_notify_passengers_driver_started(
  p_vozac_id uuid,
  p_datum date,
  p_grad text,
  p_vreme time without time zone,
  p_device_token text DEFAULT ''::text,
  p_hardware_id text DEFAULT ''::text,
  p_installation_id text DEFAULT ''::text
) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_grad text := upper(trim(coalesce(p_grad, '')));
  v_tokens jsonb;
  v_notified integer := 0;
  v_event_id text;
  v_termin_ids uuid[];
  v_auth public.v3_auth%ROWTYPE;
  v_device_ok boolean;
  v_has_device_identity boolean;
BEGIN
  IF p_vozac_id IS NULL OR p_datum IS NULL OR v_grad = '' OR p_vreme IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_args');
  END IF;

  -- Device-identity gate: pozivalac mora dokazati da je uredjaj ulogovanog
  -- vozaca (installation_id / hardware_id / push token protiv njegovih slotova).
  SELECT * INTO v_auth FROM public.v3_auth a WHERE a.id = p_vozac_id;
  IF FOUND THEN
    v_device_ok := coalesce(
      (btrim(coalesce(p_device_token, '')) <> '' AND p_device_token IN (
        v_auth.push_token, v_auth.push_token_2, v_auth.push_token_3,
        v_auth.push_token_hms, v_auth.push_token_hms_2, v_auth.push_token_hms_3))
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

  WITH claimed AS (
    UPDATE public.v3_trenutna_dodela td
    SET driver_started_notified_at = now()
    FROM public.v3_operativna_nedelja o
    WHERE o.id = td.termin_id
      AND td.vozac_v3_auth_id = p_vozac_id
      AND td.driver_started_notified_at IS NULL
      AND o.created_by IS NOT NULL
      AND o.otkazano_at IS NULL
      AND o.pokupljen_at IS NULL
      AND o.datum = p_datum
      AND upper(trim(coalesce(o.grad, ''))) = v_grad
      AND date_trunc('minute', o.polazak_at) = date_trunc('minute', p_vreme)
    RETURNING td.termin_id
  )
  SELECT coalesce(array_agg(DISTINCT termin_id), '{}'::uuid[])
  INTO v_termin_ids
  FROM claimed;

  IF coalesce(array_length(v_termin_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'notified', 0);
  END IF;

  WITH target_putnici AS (
    SELECT DISTINCT o.created_by AS putnik_id
    FROM public.v3_operativna_nedelja o
    WHERE o.id = ANY (v_termin_ids)
  ),
  token_rows AS (
    SELECT jsonb_build_object('token', a.push_token, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token IS NOT NULL AND btrim(a.push_token) <> ''

    UNION

    SELECT jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token_2 IS NOT NULL AND btrim(a.push_token_2) <> ''

    UNION

    SELECT jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token_3 IS NOT NULL AND btrim(a.push_token_3) <> ''

    UNION

    SELECT jsonb_build_object('token', a.push_token_hms, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token_hms IS NOT NULL AND btrim(a.push_token_hms) <> ''

    UNION

    SELECT jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token_hms_2 IS NOT NULL AND btrim(a.push_token_hms_2) <> ''

    UNION

    SELECT jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    JOIN target_putnici tp ON tp.putnik_id = a.id
    WHERE a.push_token_hms_3 IS NOT NULL AND btrim(a.push_token_hms_3) <> ''
  )
  SELECT coalesce(jsonb_agg(tkn), '[]'::jsonb), count(*)
  INTO v_tokens, v_notified
  FROM token_rows;

  v_event_id := format(
    'driver_started:%s:%s:%s:%s',
    p_vozac_id::text,
    p_datum::text,
    v_grad,
    to_char(p_vreme, 'HH24:MI')
  );

  IF v_notified > 0 THEN
    PERFORM public.notify_push(
      v_tokens,
      'Vozač je krenuo, molimo budite spremni na vreme',
      'Procenjeno vreme dolaska možete pratiti uživo na vašem profilu.',
      jsonb_build_object(
        'type', 'putnik_eta_start',
        'event_id', v_event_id,
        'vozac_id', p_vozac_id,
        'datum', p_datum,
        'grad', v_grad,
        'vreme', to_char(p_vreme, 'HH24:MI'),
        'screen', 'v3_putnik_profil',
        'title_sr', 'Vozač je krenuo, molimo budite spremni na vreme',
        'title_en', 'Driver is on the way, please be ready on time',
        'title_ru', 'Водитель выехал, пожалуйста, будьте готовы вовремя',
        'title_de', 'Der Fahrer ist unterwegs, bitte seien Sie pünktlich bereit',
        'title_zh', '司机已出发，请准时准备好',
        'body_sr', 'Procenjeno vreme dolaska možete pratiti uživo na vašem profilu.',
        'body_en', 'You can track the estimated arrival time live on your profile.',
        'body_ru', 'Вы можете отслеживать предполагаемое время прибытия в реальном времени в своем профиле.',
        'body_de', 'Die geschätzte Ankunftszeit können Sie live in Ihrem Profil verfolgen.',
        'body_zh', '您可以在个人资料中实时跟踪预计到达时间。'
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'notified', v_notified,
    'event_id', v_event_id,
    'termin_count', coalesce(array_length(v_termin_ids, 1), 0)
  );
END;
$$;

COMMENT ON FUNCTION public.v3_notify_passengers_driver_started(uuid, date, text, time without time zone, text, text, text) IS 'Push putnicima da je vozač krenuo — race-safe: atomicki claim preko UPDATE ... RETURNING, pa notify. Ukljucuje HMS tokene. Device-identity gate: pozivalac mora biti uredjaj ulogovanog vozaca (installation/hardware/token protiv njegovih v3_auth slotova).';

-- Stari potpis (4 parama) visi kao preklapanje — drop da anon ne moze
-- zaobici identity gate kroz njega.
DROP FUNCTION IF EXISTS public.v3_notify_passengers_driver_started(uuid, date, text, time without time zone);

REVOKE EXECUTE ON FUNCTION public.v3_notify_passengers_driver_started(uuid, date, text, time without time zone, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.v3_notify_passengers_driver_started(uuid, date, text, time without time zone, text, text, text) TO anon, authenticated, service_role;

-- ─── notify_push: siguran data_only cast ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  supabase_url text;
  anon_key text;
  gavra_api_key text;
  firebase_admin_sdk text;
  firebase_sa_078c775e7b11 text;
  firebase_sa_81779c4cc1fa text;
  huawei_client_id text;
  huawei_client_secret text;
  huawei_app_id text;
  payload_data jsonb;
  payload_event_id text;
  payload_type text;
  payload_entity_id text;
  payload_recipient_id text;
BEGIN
  SELECT decrypted_secret
  INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO anon_key
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_anon_key'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO gavra_api_key
  FROM vault.decrypted_secrets
  WHERE name = 'gavra_api_key'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO firebase_admin_sdk
  FROM vault.decrypted_secrets
  WHERE name = 'firebase_admin_sdk'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO firebase_sa_078c775e7b11
  FROM vault.decrypted_secrets
  WHERE name = 'firebase_sa_078c775e7b11'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO firebase_sa_81779c4cc1fa
  FROM vault.decrypted_secrets
  WHERE name = 'firebase_sa_81779c4cc1fa'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO huawei_client_id
  FROM vault.decrypted_secrets
  WHERE name = 'huawei_client_id'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO huawei_client_secret
  FROM vault.decrypted_secrets
  WHERE name = 'huawei_client_secret'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret
  INTO huawei_app_id
  FROM vault.decrypted_secrets
  WHERE name = 'huawei_app_id'
  ORDER BY updated_at DESC
  LIMIT 1;

  payload_data := COALESCE(data, '{}'::jsonb);
  payload_event_id := NULLIF(BTRIM(payload_data->>'event_id'), '');
  payload_type := NULLIF(BTRIM(payload_data->>'type'), '');
  payload_entity_id := COALESCE(
    NULLIF(BTRIM(payload_data->>'entity_id'), ''),
    NULLIF(BTRIM(payload_data->>'zahtev_id'), ''),
    NULLIF(BTRIM(payload_data->>'id'), '')
  );
  payload_recipient_id := COALESCE(
    NULLIF(BTRIM(payload_data->>'recipient_id'), ''),
    NULLIF(BTRIM(payload_data->>'putnik_id'), ''),
    NULLIF(BTRIM(payload_data->>'vozac_id'), '')
  );

  IF supabase_url IS NULL OR supabase_url = '' THEN
    RAISE NOTICE 'Push notification error: missing vault secret supabase_url';
    RETURN;
  END IF;

  IF anon_key IS NULL OR anon_key = '' THEN
    RAISE NOTICE 'Push notification error: missing vault secret supabase_anon_key';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := supabase_url || '/functions/v1/send-push-notification',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || anon_key,
      'apikey', anon_key,
      'x-api-key', COALESCE(gavra_api_key, '')
    ),
    body := jsonb_build_object(
      'tokens', tokens,
      'title', title,
      'body', body,
      'event_id', payload_event_id,
      'type', payload_type,
      'entity_id', payload_entity_id,
      'recipient_id', payload_recipient_id,
      'data', payload_data,
      'dedup', false,
      -- 'true' pokriva i boolean i string vrednost; raniji ::boolean cast
      -- je bacivao exception na ne-boolean ulazu i push se tiho gubio.
      'data_only', COALESCE(payload_data->>'data_only', '') = 'true',
      '_secrets', jsonb_strip_nulls(
        jsonb_build_object(
          'firebase_admin_sdk', firebase_admin_sdk,
          'firebase_sa_078c775e7b11', firebase_sa_078c775e7b11,
          'firebase_sa_81779c4cc1fa', firebase_sa_81779c4cc1fa,
          'huawei_client_id', huawei_client_id,
          'huawei_client_secret', huawei_client_secret,
          'huawei_app_id', huawei_app_id
        )
      )
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Push notification error: %', SQLERRM;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.notify_push(jsonb, text, text, jsonb) FROM anon, authenticated, PUBLIC;
