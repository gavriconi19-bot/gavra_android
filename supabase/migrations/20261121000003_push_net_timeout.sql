-- Povecanje pg_net timeouta sa default 5s na 15s za interne edge-fn pozive.
-- Pozadina: ~37% net.http_post poziva belezi "Timeout of 5000 ms reached" u
-- net._http_response iako se edge funkcija uspesno izvrsi (FCM OAuth refresh,
-- cold start workera). Timeout NE prekida edge izvrsavanje — pg_net samo
-- prestaje da ceka odgovor, pa se push isporuci ali se snimi kao neuspeh.
-- net.http_post je async (odmah vraca request id) — veci timeout ne blokira
-- pozivaoca, samo produzava cekanje workera na response zapis.

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
    ),
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Push notification error: %', SQLERRM;
END;
$function$;

CREATE OR REPLACE FUNCTION public.v3_trigger_auto_prepare()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_supabase_url text;
  v_anon_key text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret INTO v_anon_key
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_anon_key'
  ORDER BY updated_at DESC
  LIMIT 1;

  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RAISE NOTICE 'v3_trigger_auto_prepare: missing supabase_url vault secret';
    RETURN;
  END IF;

  IF v_anon_key IS NULL OR v_anon_key = '' THEN
    RAISE NOTICE 'v3_trigger_auto_prepare: missing supabase_anon_key vault secret';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_supabase_url || '/functions/v1/v3-auto-prepare-termins',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'apikey', v_anon_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 15000
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.v3_trigger_weather_alert()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_supabase_url text;
  v_anon_key text;
BEGIN
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  ORDER BY updated_at DESC
  LIMIT 1;

  SELECT decrypted_secret INTO v_anon_key
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_anon_key'
  ORDER BY updated_at DESC
  LIMIT 1;

  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RAISE NOTICE 'v3_trigger_weather_alert: missing supabase_url vault secret';
    RETURN;
  END IF;

  IF v_anon_key IS NULL OR v_anon_key = '' THEN
    RAISE NOTICE 'v3_trigger_weather_alert: missing supabase_anon_key vault secret';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_supabase_url || '/functions/v1/v3-weather-alert',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_anon_key,
      'apikey', v_anon_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 15000
  );
END;
$function$;

-- CREATE OR REPLACE cuva postojece ACL-ove, ali za svaki slucaj ponavljamo
-- revoke iz 20261121000002 (idempotentno).
REVOKE EXECUTE ON FUNCTION public.notify_push(jsonb, text, text, jsonb) FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.v3_trigger_auto_prepare() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.v3_trigger_weather_alert() FROM anon, authenticated, PUBLIC;
