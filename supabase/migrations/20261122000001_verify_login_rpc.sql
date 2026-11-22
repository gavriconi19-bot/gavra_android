-- 2026-11-22 — fn_v3_verify_login RPC: isti verdict kao edge funkcija
-- verify-login, ali kao PostgREST RPC (~0.1-0.5s kroz Tailscale Funnel
-- naspram ~1-4s edge-runtime poziva; edge-runtime cold start zna da
-- pojede ceo 15s _startupTimeout na welcome ekranu pa auto-login tiho
-- padne i korisnik mora rucno da klikne "Prijavi se").
--
-- Logika je namerno replicirana 1:1 sa supabase/functions/verify-login —
-- ako se pravila device-slot/PIN provere menjaju, menjati NA OBA mesta.
-- App (v3_closed_auth_service.verifyLogin) prvo zove ovaj RPC, a na
-- gresku/timeout pada nazad na edge funkciju (rolling deploy safety).

-- Helper: canonical 0X format identican edge normalizePhone()
-- (digits-only → "381X" => "0X", "00381X" => "0X", "6X" => "06X").
-- Interna fn — bez EXECUTE za anon/authenticated.
CREATE OR REPLACE FUNCTION public.fn_v3_phone_canonical_local(p_telefon text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $func$
DECLARE
  v_digits text;
  v_rest   text;
BEGIN
  v_digits := regexp_replace(btrim(coalesce(p_telefon, '')), '\D', '', 'g');
  IF v_digits = '' THEN
    RETURN '';
  END IF;

  IF left(v_digits, 3) = '381' THEN
    v_rest := substring(v_digits from 4);
    RETURN CASE WHEN left(v_rest, 1) = '0' THEN v_rest ELSE '0' || v_rest END;
  END IF;

  IF left(v_digits, 2) = '00' AND left(substring(v_digits from 3), 3) = '381' THEN
    v_rest := substring(v_digits from 6);
    RETURN CASE WHEN left(v_rest, 1) = '0' THEN v_rest ELSE '0' || v_rest END;
  END IF;

  RETURN CASE WHEN left(v_digits, 1) = '0' THEN v_digits ELSE '0' || v_digits END;
END;
$func$;

CREATE OR REPLACE FUNCTION public.fn_v3_verify_login(
  p_telefon         text,
  p_v3_auth_id      text,
  p_installation_id text DEFAULT NULL,
  p_hardware_id     text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  -- Isti hardkodovani review nalozi kao u edge verify-login.
  c_apple_review_id  CONSTANT uuid := 'db969766-e0ec-422c-95d7-620c8c9b8df5';
  c_google_review_id CONSTANT uuid := '3927044f-52c7-4c4a-825f-0eb824f702b0';
  v_phone       text;
  v_id          uuid;
  v_account     public.v3_auth%rowtype;
  v_inst        text := btrim(coalesce(p_installation_id, ''));
  v_hw          text := btrim(coalesce(p_hardware_id, ''));
  v_pin_set     boolean;
  v_recognized  boolean := false;
  v_slots_full  boolean := false;
  v_allowed     boolean := true;
  v_is_review   boolean;
BEGIN
  v_phone := public.fn_v3_phone_canonical_local(p_telefon);
  IF v_phone = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_phone');
  END IF;

  IF btrim(coalesce(p_v3_auth_id, '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_v3_auth_id');
  END IF;
  BEGIN
    v_id := btrim(p_v3_auth_id)::uuid;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'v3_auth_lookup_error',
                              'warning', 'invalid uuid');
  END;

  SELECT * INTO v_account FROM public.v3_auth a WHERE a.id = v_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'login_pair_not_found',
                              'telefon', v_phone);
  END IF;

  IF v_phone IS DISTINCT FROM public.fn_v3_phone_canonical_local(v_account.telefon)
     AND v_phone IS DISTINCT FROM public.fn_v3_phone_canonical_local(v_account.telefon_2) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'uuid_phone_mismatch',
      'expected_v3_auth_id', v_id::text,
      'resolved_v3_auth_id', v_id::text,
      'telefon', v_phone);
  END IF;

  v_pin_set   := btrim(coalesce(v_account.pin_hash, '')) <> '';
  v_is_review := v_id IN (c_apple_review_id, c_google_review_id);

  IF v_is_review THEN
    -- Review nalozi uvek prolaze bez PIN provere, bez obzira na uredjaj/slotove.
    v_recognized := true;
    v_allowed    := true;
  ELSIF v_inst <> '' OR v_hw <> '' THEN
    v_recognized :=
      (v_inst <> '' AND v_inst IN (
        btrim(coalesce(v_account.installation_id, '')),
        btrim(coalesce(v_account.installation_id_2, '')),
        btrim(coalesce(v_account.installation_id_3, ''))))
      OR
      (v_hw <> '' AND v_hw IN (
        btrim(coalesce(v_account.hardware_id, '')),
        btrim(coalesce(v_account.hardware_id_2, '')),
        btrim(coalesce(v_account.hardware_id_3, ''))));

    v_slots_full := btrim(coalesce(v_account.installation_id, '')) <> ''
                AND btrim(coalesce(v_account.installation_id_2, '')) <> ''
                AND btrim(coalesce(v_account.installation_id_3, '')) <> '';

    -- PIN podešen + neprepoznat uredjaj → obavezna PIN potvrda (isti komentar
    -- kao u edge fn: bez PIN-a fallback na slobodan slot).
    IF v_recognized THEN
      v_allowed := true;
    ELSIF v_pin_set THEN
      v_allowed := false;
    ELSE
      v_allowed := NOT v_slots_full;
    END IF;
  END IF;

  IF NOT v_allowed THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', CASE WHEN (NOT v_recognized) AND v_pin_set
                     THEN 'device_pin_required' ELSE 'device_limit_reached' END,
      'v3_auth_id', v_id::text,
      'telefon', v_phone,
      'device_recognized', v_recognized,
      'device_slots_full', v_slots_full,
      'pin_required', NOT v_pin_set);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'v3_auth_id', v_id::text,
    'telefon', v_phone,
    'device_recognized', v_recognized,
    'device_slots_full', v_slots_full,
    'pin_required', CASE WHEN v_is_review THEN false ELSE NOT v_pin_set END);
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_v3_phone_canonical_local(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_v3_phone_canonical_local(text) TO service_role;

REVOKE ALL ON FUNCTION public.fn_v3_verify_login(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_v3_verify_login(text, text, text, text)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
