-- Push notification audit fixes (2026-11-21):
-- 1) notify_push: dodat x-api-key header (shared-secret provera u edge fn,
--    vrednost iz vault secret-a 'gavra_api_key' — NE unositi u repo).
-- 2) fn_v3_notify_putnik_on_zahtev_update: SECURITY DEFINER (radi kao postgres,
--    pa notify_push ne zavisi od EXECUTE grant-a pozivaoca) + GUC marker
--    'gavra.zahtev_cancel_notified' za dedup operativna-propagacije.
-- 3) fn_v3_notify_putnik_on_operativna_update: funkcija je bila mrtva (nije
--    postojao trigger). Prepravljena da javlja putniku samo na NOVO
--    otkazivanje operativne stavke (admin/ops put) sa dedup-om preko GUC-a.
-- 4) Novi trigger trg_v3_notify_putnik_on_operativna_otkazano.
-- 5) REVOKE EXECUTE sa anon/authenticated/PUBLIC na push funkcijama.
-- 6) DROP mrtvog 11-param overload-a v3_notify_vozaci_weather_alert.

-- ─── 1) notify_push ─────────────────────────────────────────────────────────
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
      'data_only',
        CASE
          WHEN payload_data ? 'data_only' THEN (payload_data->>'data_only')::boolean
          ELSE false
        END,
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
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Push notification error: %', SQLERRM;
END;
$function$;

-- ─── 2) zahtev notify: SECURITY DEFINER + GUC dedup marker ──────────────────
CREATE OR REPLACE FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_tokens jsonb;
  v_title text;
  v_body text;
  v_data jsonb;
  v_grad text;
  v_vreme text;
  v_ime text;
  v_termin text;
  v_recipient uuid;
  v_alt_pre text;
  v_alt_posle text;
  v_title_en text;
  v_title_ru text;
  v_title_de text;
  v_body_en text;
  v_body_ru text;
  v_body_de text;
BEGIN
  IF old.status IS NOT DISTINCT FROM new.status THEN
    IF NOT (
      new.status = 'alternativa'
      AND (
        old.alternativa_pre_at IS DISTINCT FROM new.alternativa_pre_at
        OR old.alternativa_posle_at IS DISTINCT FROM new.alternativa_posle_at
      )
    ) THEN
      RETURN new;
    END IF;
  END IF;

  v_recipient := COALESCE(new.created_by, new.updated_by);
  IF v_recipient IS NULL THEN
    RETURN new;
  END IF;

  v_grad := CASE
    WHEN new.grad = 'BC' THEN 'Bela Crkva'
    WHEN new.grad = 'VS' THEN 'Vrsac'
    ELSE new.grad
  END;

  SELECT COALESCE(NULLIF(BTRIM(a.ime), ''), 'putnik')
  INTO v_ime
  FROM public.v3_auth a
  WHERE a.id = v_recipient
  LIMIT 1;

  SELECT jsonb_agg(tkn)
  INTO v_tokens
  FROM (
    SELECT jsonb_build_object('token', a.push_token, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token IS NOT NULL
      AND BTRIM(a.push_token) <> ''
    UNION
    SELECT jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token_2 IS NOT NULL
      AND BTRIM(a.push_token_2) <> ''
    UNION
    SELECT jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token_3 IS NOT NULL
      AND BTRIM(a.push_token_3) <> ''
    UNION
    SELECT jsonb_build_object('token', a.push_token_hms, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token_hms IS NOT NULL
      AND BTRIM(a.push_token_hms) <> ''
    UNION
    SELECT jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token_hms_2 IS NOT NULL
      AND BTRIM(a.push_token_hms_2) <> ''
    UNION
    SELECT jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms') AS tkn
    FROM public.v3_auth a
    WHERE a.id = v_recipient
      AND a.push_token_hms_3 IS NOT NULL
      AND BTRIM(a.push_token_hms_3) <> ''
  ) s;

  IF v_tokens IS NULL OR jsonb_array_length(v_tokens) = 0 THEN
    RETURN new;
  END IF;

  v_vreme := COALESCE(
    to_char(new.polazak_at, 'HH24:MI'),
    to_char(new.trazeni_polazak_at, 'HH24:MI'),
    ''
  );

  v_termin := CASE
    WHEN v_vreme <> '' THEN format('%s %s u %s', to_char(new.datum::date, 'DD.MM.YYYY.'), v_grad, v_vreme)
    ELSE format('%s %s', to_char(new.datum::date, 'DD.MM.YYYY.'), v_grad)
  END;

  IF new.status = 'odobreno' THEN
    v_title := 'Zahtev odobren';
    v_body  := format('Postovani %s, vas zahtev za termin %s je odobren.', v_ime, v_termin);
    v_title_en := 'Request approved';
    v_body_en  := format('Dear %s, your request for %s has been approved.', v_ime, v_termin);
    v_title_ru := 'Заявка одобрена';
    v_body_ru  := format('Уважаемый(ая) %s, ваша заявка на %s одобрена.', v_ime, v_termin);
    v_title_de := 'Anfrage genehmigt';
    v_body_de  := format('Sehr geehrte(r) %s, Ihre Anfrage für %s wurde genehmigt.', v_ime, v_termin);
    v_data  := jsonb_build_object(
      'type', 'v3_zahtev_odobren',
      'entity_id', new.id,
      'zahtev_id', new.id,
      'recipient_id', v_recipient,
      'id', new.id,
      'datum', new.datum,
      'grad', new.grad,
      'vreme', v_vreme,
      'status', new.status,
      'screen', 'v3_putnik_profil',
      'title_sr', v_title,
      'title_en', v_title_en,
      'title_ru', v_title_ru,
      'title_de', v_title_de,
      'body_sr', v_body,
      'body_en', v_body_en,
      'body_ru', v_body_ru,
      'body_de', v_body_de
    );

  ELSIF new.status = 'alternativa' THEN
    v_alt_pre   := COALESCE(to_char(new.alternativa_pre_at,   'HH24:MI'), '');
    v_alt_posle := COALESCE(to_char(new.alternativa_posle_at, 'HH24:MI'), '');

    v_title := 'Informacija o dostupnosti termina';
    v_body  := 'Trenutno nema slobodnih mesta u zeljenom terminu. Pripremili smo najblize dostupne alternative za Vas.';
    v_title_en := 'Appointment availability update';
    v_body_en  := 'There are currently no free spots in the requested time slot. We have prepared the closest available alternatives for you.';
    v_title_ru := 'Информация о доступности термина';
    v_body_ru  := 'В настоящее время нет свободных мест в желаемое время. Мы подготовили для вас ближайшие доступные альтернативы.';
    v_title_de := 'Information zur Terminverfügbarkeit';
    v_body_de  := 'Im gewünschten Termin sind derzeit keine freien Plätze verfügbar. Wir haben die nächstgelegenen verfügbaren Alternativen für Sie vorbereitet.';

    v_data  := jsonb_build_object(
      'type',               'v3_alternativa',
      'zahtev_id',          new.id,
      'recipient_id',       v_recipient,
      'alt_pre',            v_alt_pre,
      'alt_posle',          v_alt_posle,
      'datum',              new.datum,
      'grad',               new.grad,
      'status',             new.status,
      'screen',             'v3_putnik_profil',
      'action_pre_label',   CASE WHEN v_alt_pre   <> '' THEN v_alt_pre   ELSE null END,
      'action_posle_label', CASE WHEN v_alt_posle <> '' THEN v_alt_posle ELSE null END,
      'action_reject_label','Odbij',
      'title_sr', v_title,
      'title_en', v_title_en,
      'title_ru', v_title_ru,
      'title_de', v_title_de,
      'body_sr', v_body,
      'body_en', v_body_en,
      'body_ru', v_body_ru,
      'body_de', v_body_de
    );

  ELSIF new.status = 'odbijeno' THEN
    v_title := 'Termin popunjen';
    v_body  := 'Nazalost, u terminu ' || COALESCE(v_vreme, '') || ' nema slobodnih mesta (' || v_grad || ').';
    v_title_en := 'Time slot full';
    v_body_en  := 'Unfortunately, there are no free spots at ' || COALESCE(v_vreme, '') || ' (' || v_grad || ').';
    v_title_ru := 'Термин заполнен';
    v_body_ru  := 'К сожалению, в термине ' || COALESCE(v_vreme, '') || ' нет свободных мест (' || v_grad || ').';
    v_title_de := 'Termin ausgebucht';
    v_body_de  := 'Leider sind im Termin ' || COALESCE(v_vreme, '') || ' keine freien Plätze verfügbar (' || v_grad || ').';
    v_data  := jsonb_build_object(
      'type', 'v3_zahtev_odbijen',
      'entity_id', new.id,
      'zahtev_id', new.id,
      'recipient_id', v_recipient,
      'id', new.id,
      'datum', new.datum,
      'grad', new.grad,
      'status', new.status,
      'screen', 'v3_putnik_profil',
      'title_sr', v_title,
      'title_en', v_title_en,
      'title_ru', v_title_ru,
      'title_de', v_title_de,
      'body_sr', v_body,
      'body_en', v_body_en,
      'body_ru', v_body_ru,
      'body_de', v_body_de
    );

  ELSIF new.status = 'otkazano' THEN
    v_title := 'Prevoz otkazan';
    v_body  := 'Vas prevoz za ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') je otkazan.';
    v_title_en := 'Ride cancelled';
    v_body_en  := 'Your ride at ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') has been cancelled.';
    v_title_ru := 'Поездка отменена';
    v_body_ru  := 'Ваша поездка в ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') отменена.';
    v_title_de := 'Fahrt storniert';
    v_body_de  := 'Ihre Fahrt um ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') wurde storniert.';
    v_data  := jsonb_build_object(
      'type', 'v3_otkazano',
      'entity_id', new.id,
      'zahtev_id', new.id,
      'recipient_id', v_recipient,
      'id', new.id,
      'datum', new.datum,
      'grad', new.grad,
      'status', new.status,
      'screen', 'v3_putnik_profil',
      'title_sr', v_title,
      'title_en', v_title_en,
      'title_ru', v_title_ru,
      'title_de', v_title_de,
      'body_sr', v_body,
      'body_en', v_body_en,
      'body_ru', v_body_ru,
      'body_de', v_body_de
    );
  END IF;

  IF v_title IS NOT NULL THEN
    PERFORM public.notify_push(v_tokens, v_title, v_body, v_data);

    -- transfer_to_operativna_nedelja propagira ove statuse u
    -- v3_operativna_nedelja.otkazano_at istom transakcijom. Marker sprecava
    -- trg_v3_notify_putnik_on_operativna_otkazano da posalje dupli push.
    IF new.status IN ('alternativa', 'odbijeno', 'otkazano') THEN
      PERFORM set_config(
        'gavra.zahtev_cancel_notified',
        COALESCE(current_setting('gavra.zahtev_cancel_notified', true), '')
          || v_recipient::text || ',',
        true
      );
    END IF;
  END IF;

  RETURN new;
END;
$$;

-- ─── 3) operativna notify: samo novo otkazivanje (direktna izmena) ──────────
CREATE OR REPLACE FUNCTION public.fn_v3_notify_putnik_on_operativna_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_tokens  jsonb;
  v_title   text;
  v_body    text;
  v_data    jsonb;
  v_grad    text;
  v_vreme   text;
  v_datum   text;
  v_ime     text;
  v_recipient uuid;
  v_title_en text;
  v_title_ru text;
  v_title_de text;
  v_body_en text;
  v_body_ru text;
  v_body_de text;
BEGIN
  -- Reaguje samo na novo postavljeno otkazivanje. Otkazivanja propagirana iz
  -- v3_zahtevi (status alternativa/odbijeno/otkazano) vec su dobila push kroz
  -- zahtev trigger — isti tx nosi GUC marker gavra.zahtev_cancel_notified.
  IF TG_OP <> 'UPDATE'
     OR NEW.otkazano_at IS NULL
     OR OLD.otkazano_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  v_recipient := NEW.created_by;
  IF v_recipient IS NULL THEN
    RETURN NEW;
  END IF;

  IF position(v_recipient::text || ','
              IN COALESCE(current_setting('gavra.zahtev_cancel_notified', true), '')) > 0 THEN
    RETURN NEW;
  END IF;

  SELECT
    COALESCE(NULLIF(BTRIM(a.ime), ''), 'putnik'),
    (
      SELECT jsonb_agg(tkn)
      FROM (
        SELECT jsonb_build_object('token', a2.push_token, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token IS NOT NULL
          AND BTRIM(a2.push_token) <> ''
        UNION
        SELECT jsonb_build_object('token', a2.push_token_2, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token_2 IS NOT NULL
          AND BTRIM(a2.push_token_2) <> ''
        UNION
        SELECT jsonb_build_object('token', a2.push_token_3, 'provider', 'fcm') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token_3 IS NOT NULL
          AND BTRIM(a2.push_token_3) <> ''
        UNION
        SELECT jsonb_build_object('token', a2.push_token_hms, 'provider', 'hms') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token_hms IS NOT NULL
          AND BTRIM(a2.push_token_hms) <> ''
        UNION
        SELECT jsonb_build_object('token', a2.push_token_hms_2, 'provider', 'hms') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token_hms_2 IS NOT NULL
          AND BTRIM(a2.push_token_hms_2) <> ''
        UNION
        SELECT jsonb_build_object('token', a2.push_token_hms_3, 'provider', 'hms') AS tkn
        FROM public.v3_auth a2
        WHERE a2.id = v_recipient
          AND a2.push_token_hms_3 IS NOT NULL
          AND BTRIM(a2.push_token_hms_3) <> ''
      ) s
    )
  INTO v_ime, v_tokens
  FROM public.v3_auth a
  WHERE a.id = v_recipient
  LIMIT 1;

  IF v_tokens IS NULL OR jsonb_array_length(v_tokens) = 0 THEN
    RETURN NEW;
  END IF;

  v_grad := CASE
    WHEN NEW.grad = 'BC' THEN 'Bela Crkva'
    WHEN NEW.grad = 'VS' THEN 'Vrsac'
    ELSE NEW.grad
  END;

  v_vreme := COALESCE(TO_CHAR(NEW.polazak_at, 'HH24:MI'), '');
  v_datum := TO_CHAR(NEW.datum::date, 'DD.MM.YYYY.');

  v_title := 'Prevoz otkazan';
  v_body  := 'Vas prevoz ' || v_datum || ' u ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') je otkazan.';
  v_title_en := 'Ride cancelled';
  v_body_en  := 'Your ride on ' || v_datum || ' at ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') has been cancelled.';
  v_title_ru := 'Поездка отменена';
  v_body_ru  := 'Ваша поездка ' || v_datum || ' в ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') отменена.';
  v_title_de := 'Fahrt storniert';
  v_body_de  := 'Ihre Fahrt am ' || v_datum || ' um ' || COALESCE(v_vreme, '') || ' (' || v_grad || ') wurde storniert.';

  v_data := jsonb_build_object(
    'type',         'v3_otkazano',
    'status',       'otkazano',
    'entity_id',    NEW.id,
    'recipient_id', v_recipient,
    'v3_auth_id',   v_recipient,
    'grad',         NEW.grad,
    'datum',        NEW.datum,
    'vreme',        v_vreme,
    'screen',       'v3_putnik_profil',
    'title_sr', v_title,
    'title_en', v_title_en,
    'title_ru', v_title_ru,
    'title_de', v_title_de,
    'body_sr', v_body,
    'body_en', v_body_en,
    'body_ru', v_body_ru,
    'body_de', v_body_de
  );

  PERFORM public.notify_push(v_tokens, v_title, v_body, v_data);

  RETURN NEW;
END;
$$;

-- ─── 4) trigger na operativnoj (novi — ranije nije postojao) ────────────────
DROP TRIGGER IF EXISTS trg_v3_notify_putnik_on_operativna_otkazano ON public.v3_operativna_nedelja;
CREATE TRIGGER trg_v3_notify_putnik_on_operativna_otkazano
  AFTER UPDATE OF otkazano_at ON public.v3_operativna_nedelja
  FOR EACH ROW EXECUTE FUNCTION public.fn_v3_notify_putnik_on_operativna_update();

-- ─── 5) revokes: push interni detalji ne smeju biti RPC-pozivljivi ──────────
-- notify_push zovu samo DB funkcije (SECURITY DEFINER kontekst) i service_role.
REVOKE EXECUTE ON FUNCTION public.notify_push(jsonb, text, text, jsonb) FROM anon, authenticated;

-- Trigger funkcije ne trebaju EXECUTE nikome (trigger ih poziva bez provere).
REVOKE EXECUTE ON FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_v3_notify_putnik_on_operativna_update() FROM PUBLIC, anon, authenticated;

-- Weather alert zove iskljucivo v3-weather-alert edge funkcija (service_role).
REVOKE EXECUTE ON FUNCTION public.v3_notify_vozaci_weather_alert(text, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.v3_notify_vozaci_weather_alert(text, text, text, text, text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- App (anon RPC) poziva v3_notify_passengers_driver_started — claim je
-- atomican (driver_started_notified_at), ali PUBLIC grant je suvisan.
REVOKE EXECUTE ON FUNCTION public.v3_notify_passengers_driver_started(uuid, date, text, time without time zone) FROM PUBLIC;

-- ─── 6) mrtav 11-param overload (bez HMS/zh; svi pozivaoci koriste 13-param) ─
DROP FUNCTION IF EXISTS public.v3_notify_vozaci_weather_alert(text, text, text, text, text, text, text, text, text, text, text);
