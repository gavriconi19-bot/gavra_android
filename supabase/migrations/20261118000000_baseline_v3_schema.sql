-- ============================================================================
-- BASELINE MIGRATION — kompletna public schema sa laptop stacka (2026-11-18)
-- Generisano iz pg_dump --schema-only + ručno dopunjeno:
--   * CREATE EXTENSION blok (pg_dump -n public ih ne izbacuje)
--   * supabase_realtime publikacija (pg_dump je ne dump-uje sa -n filterom)
--   * pg_cron jobovi (žive u cron.job tabeli — podatak, ne šema)
--
-- Laptop stack je od ove tačke JEDINI source of truth za šemu.
-- Stare inkrementalne migracije su arhivirane u supabase/migrations_archive/
-- jer je njihovo stanje već sadržano u ovom baseline-u.
-- ============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pgjwt with schema extensions;
create extension if not exists supabase_vault;
do $$ begin create extension if not exists vector with schema public;
  exception when others then raise warning 'vector ekstenzija preskocena: %', sqlerrm; end $$;
do $$ begin create extension if not exists pg_cron;
  exception when others then raise warning 'pg_cron ekstenzija preskocena (dozvoljena samo u postgres bazi): %', sqlerrm; end $$;

--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA IF NOT EXISTS public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: analyze_schema(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.analyze_schema() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  result jsonb := '[]'::jsonb;
  table_info jsonb;
  cols jsonb;
  constraints_list jsonb;
  sample jsonb;
  row_count bigint;
  t_name text;
BEGIN
  FOR t_name IN
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name LIKE 'v3_%'
    ORDER BY table_name
  LOOP
    -- Kolone
    SELECT jsonb_agg(jsonb_build_object(
      'column_name', c.column_name,
      'data_type', c.data_type,
      'is_nullable', c.is_nullable,
      'column_default', c.column_default
    ) ORDER BY c.ordinal_position)
    INTO cols
    FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.table_name = t_name;

    -- Check constraints
    SELECT jsonb_agg(jsonb_build_object(
      'constraint_name', cc.constraint_name,
      'check_clause', cc.check_clause
    ))
    INTO constraints_list
    FROM information_schema.check_constraints cc
    JOIN information_schema.table_constraints tc
      ON cc.constraint_name = tc.constraint_name
    WHERE tc.table_schema = 'public' AND tc.table_name = t_name;

    -- Row count
    EXECUTE format('SELECT COUNT(*) FROM %I', t_name) INTO row_count;

    -- Sample data (max 3 rows)
    EXECUTE format('SELECT jsonb_agg(t) FROM (SELECT * FROM %I LIMIT 3) t', t_name) INTO sample;

    table_info := jsonb_build_object(
      'table_name', t_name,
      'columns', COALESCE(cols, '[]'::jsonb),
      'constraints', COALESCE(constraints_list, '[]'::jsonb),
      'row_count', row_count,
      'sample_data', COALESCE(sample, '[]'::jsonb)
    );

    result := result || table_info;
  END LOOP;

  RETURN result;
END;
$$;


ALTER FUNCTION public.analyze_schema() OWNER TO postgres;

--
-- Name: ensure_polazak_at_on_odobreno(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.ensure_polazak_at_on_odobreno() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.status = 'odobreno' AND NEW.polazak_at IS NULL THEN
        NEW.polazak_at := NEW.trazeni_polazak_at;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.ensure_polazak_at_on_odobreno() OWNER TO postgres;

--
-- Name: expire_unanswered_alternativa_10m(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.expire_unanswered_alternativa_10m() RETURNS TABLE(expired_count integer, log_message text)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_count integer := 0;
BEGIN
  UPDATE public.v3_zahtevi z
  SET
    status = 'odbijeno',
    alternativa_pre_at = NULL,
    alternativa_posle_at = NULL,
    alternativa_offered_at = NULL,
    updated_at = now(),
    updated_by = '4feffa3a-8b4d-4e28-9b8b-c0af3c48ea4e'::uuid
  WHERE z.status = 'alternativa'
    AND COALESCE(z.alternativa_offered_at, z.updated_at) <= now() - interval '10 minutes';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN QUERY
  SELECT v_count, format('Alternativa timeout: zatvoreno %s zahteva.', v_count);
END;
$$;


ALTER FUNCTION public.expire_unanswered_alternativa_10m() OWNER TO postgres;

--
-- Name: fn_v3_alternativa_action(uuid, text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text DEFAULT ''::text, p_hardware_id text DEFAULT ''::text, p_installation_id text DEFAULT ''::text) RETURNS jsonb
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
$$;


ALTER FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text) OWNER TO postgres;

--
-- Name: fn_v3_expire_mesto_ponuda(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_expire_mesto_ponuda() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


ALTER FUNCTION public.fn_v3_expire_mesto_ponuda() OWNER TO postgres;

--
-- Name: FUNCTION fn_v3_expire_mesto_ponuda(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.fn_v3_expire_mesto_ponuda() IS 'Posle 10 minuta bez odgovora na oslobođeno mesto, nudi se sledećem odbijenom.';


--
-- Name: fn_v3_finansije_popuni_imena(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_finansije_popuni_imena() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_putnik_ime text;
  v_naplatio_ime text;
begin
  if new.putnik_v3_auth_id is not null and (new.ime is null or btrim(new.ime) = '') then
    select a.ime into v_putnik_ime
    from public.v3_auth a
    where a.id = new.putnik_v3_auth_id;

    if v_putnik_ime is not null and btrim(v_putnik_ime) <> '' then
      new.ime := v_putnik_ime;
    end if;
  end if;

  if new.naplaceno_by is not null and (new.naplatio_ime is null or btrim(new.naplatio_ime) = '') then
    select a.ime into v_naplatio_ime
    from public.v3_auth a
    where a.id = new.naplaceno_by;

    if v_naplatio_ime is not null and btrim(v_naplatio_ime) <> '' then
      new.naplatio_ime := v_naplatio_ime;
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.fn_v3_finansije_popuni_imena() OWNER TO postgres;

--
-- Name: fn_v3_notify_putnik_on_operativna_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_notify_putnik_on_operativna_update() RETURNS trigger
    LANGUAGE plpgsql
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
  IF TG_OP = 'INSERT' THEN
    IF NEW.polazak_at IS NULL THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.polazak_at IS NOT DISTINCT FROM OLD.polazak_at THEN
      RETURN NEW;
    END IF;
    IF NEW.polazak_at IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;

  v_recipient := NEW.created_by;
  IF v_recipient IS NULL THEN
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

  v_vreme := TO_CHAR(NEW.polazak_at, 'HH24:MI');
  v_datum := TO_CHAR(NEW.datum::date, 'DD.MM.YYYY.');

  v_title := 'Termin odobren';
  v_body  := FORMAT('Postovani %s, vas termin %s %s u %s je odobren.', v_ime, v_datum, v_grad, v_vreme);
  v_title_en := 'Appointment approved';
  v_body_en  := FORMAT('Dear %s, your appointment on %s %s at %s has been approved.', v_ime, v_datum, v_grad, v_vreme);
  v_title_ru := 'Термин одобрен';
  v_body_ru  := FORMAT('Уважаемый(ая) %s, ваш термин %s %s в %s одобрен.', v_ime, v_datum, v_grad, v_vreme);
  v_title_de := 'Termin genehmigt';
  v_body_de  := FORMAT('Sehr geehrte(r) %s, Ihr Termin am %s %s um %s wurde genehmigt.', v_ime, v_datum, v_grad, v_vreme);

  v_data := jsonb_build_object(
    'type',         'zahtev_status',
    'status',       'odobreno',
    'v3_auth_id',   v_recipient,
    'request_id',   '',
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


ALTER FUNCTION public.fn_v3_notify_putnik_on_operativna_update() OWNER TO postgres;

--
-- Name: fn_v3_notify_putnik_on_zahtev_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() RETURNS trigger
    LANGUAGE plpgsql
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
  END IF;

  RETURN new;
END;
$$;


ALTER FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() OWNER TO postgres;

--
-- Name: fn_v3_offer_freed_seats(date, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) RETURNS integer
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
$$;


ALTER FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) OWNER TO postgres;

--
-- Name: fn_v3_on_kapacitet_increased_offer_seats(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_vreme text;
  v_old_max integer := 0;
  v_new_max integer := 0;
BEGIN
  v_new_max := COALESCE(NEW.max_mesta, 0);
  IF TG_OP = 'UPDATE' THEN
    v_old_max := COALESCE(OLD.max_mesta, 0);
    IF v_new_max <= v_old_max THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    IF v_new_max <= 0 THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  v_vreme := public.v3_norm_hhmm(COALESCE(NEW.vreme, CASE WHEN TG_OP = 'UPDATE' THEN OLD.vreme ELSE NULL END)::text);
  IF v_vreme = '' OR NEW.datum IS NULL OR btrim(coalesce(NEW.grad, '')) = '' THEN
    RETURN NEW;
  END IF;

  BEGIN
    PERFORM public.fn_v3_offer_freed_seats(
      NEW.datum::date,
      NEW.grad::text,
      v_vreme
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'fn_v3_offer_freed_seats (kapacitet): %', SQLERRM;
  END;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() OWNER TO postgres;

--
-- Name: FUNCTION fn_v3_on_kapacitet_increased_offer_seats(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() IS 'Kad se max_mesta poveća (ili unese novi slot sa kapacitetom), nudi oslobođena mesta odbijenim putnicima.';


--
-- Name: fn_v3_on_operativna_otkazano_offer_seats(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() RETURNS trigger
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
    IF NOT EXISTS (
      SELECT 1
      FROM public.v3_zahtevi z
      WHERE z.created_by = NEW.created_by
        AND z.datum = NEW.datum::date
        AND upper(btrim(coalesce(z.grad, ''))) = upper(btrim(coalesce(NEW.grad, '')))
        AND public.v3_norm_hhmm(coalesce(z.polazak_at, z.trazeni_polazak_at)::text) = v_vreme
        AND z.status IN ('otkazano', 'odobreno', 'odbijeno')
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

--
-- Name: fn_v3_operativna_set_lifecycle_timestamps(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if new.otkazano_at is null and new.otkazano_by is not null then
    if tg_op = 'INSERT' or old.otkazano_by is distinct from new.otkazano_by or old.otkazano_at is null then
      new.otkazano_at := now();
    end if;
  end if;

  if new.pokupljen_at is null and new.pokupljen_by is not null then
    if tg_op = 'INSERT' or old.pokupljen_by is distinct from new.pokupljen_by or old.pokupljen_at is null then
      new.pokupljen_at := now();
    end if;
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps() OWNER TO postgres;

--
-- Name: fn_v3_operativna_sync_dodela(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_operativna_sync_dodela() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_slot_id uuid;
  v_slot_vozac uuid;
begin
  if new.otkazano_at is not null
     or new.pokupljen_at is not null
     or new.created_by is null
     or new.polazak_at is null then
    delete from public.v3_trenutna_dodela where termin_id = new.id;
    return new;
  end if;

  select s.id, s.vozac_v3_auth_id
    into v_slot_id, v_slot_vozac
    from public.v3_trenutna_dodela_slot s
   where s.datum = new.datum
     and s.grad = new.grad
     and s.vreme = new.polazak_at
   limit 1;

  if v_slot_id is null or v_slot_vozac is null then
    delete from public.v3_trenutna_dodela where termin_id = new.id;
    return new;
  end if;

  insert into public.v3_trenutna_dodela (
    termin_id,
    putnik_v3_auth_id,
    vozac_v3_auth_id,
    slot_id,
    updated_by
  ) values (
    new.id,
    new.created_by,
    v_slot_vozac,
    v_slot_id,
    new.updated_by
  )
  on conflict (termin_id) do update
    set slot_id = excluded.slot_id,
        putnik_v3_auth_id = excluded.putnik_v3_auth_id,
        updated_by = excluded.updated_by;

  return new;
end;
$$;


ALTER FUNCTION public.fn_v3_operativna_sync_dodela() OWNER TO postgres;

--
-- Name: fn_v3_trenutna_dodela_normalize(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_trenutna_dodela_normalize() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  return new;
end;
$$;


ALTER FUNCTION public.fn_v3_trenutna_dodela_normalize() OWNER TO postgres;

--
-- Name: fn_v3_trenutna_dodela_slot_normalize(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_v3_trenutna_dodela_slot_normalize() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.grad := upper(trim(coalesce(new.grad, '')));
  new.vreme := date_trunc('minute', new.vreme);
  return new;
end;
$$;


ALTER FUNCTION public.fn_v3_trenutna_dodela_slot_normalize() OWNER TO postgres;

--
-- Name: get_pending_zahtevi_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_pending_zahtevi_status() RETURNS TABLE(zahtev_id uuid, putnik_ime text, tip_putnika text, datum date, grad text, zeljeno_vreme time without time zone, created_at timestamp with time zone, scheduled_at timestamp with time zone, remaining_minutes integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
begin
  return query
  select
      z.id,
      coalesce(a.ime, 'Nepoznat korisnik') as putnik_ime,
      a.tip,
      z.datum,
      z.grad,
      z.trazeni_polazak_at as zeljeno_vreme,
      z.created_at,
      z.scheduled_at,
      case
          when z.scheduled_at > now() then extract(epoch from (z.scheduled_at - now()))::integer / 60
          else 0
      end as remaining_minutes
  from public.v3_zahtevi z
  left join public.v3_auth a on a.id = z.created_by
  where z.status = 'obrada'
    and not exists (
        select 1
        from public.v3_app_settings s
        cross join lateral jsonb_array_elements_text(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_txt)
        where d.day_txt ~ '^\d{4}-\d{2}-\d{2}$'
          and d.day_txt::date = z.datum::date
    )
  order by z.scheduled_at asc;
end;
$_$;


ALTER FUNCTION public.get_pending_zahtevi_status() OWNER TO postgres;

--
-- Name: manual_process_zahtevi(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.manual_process_zahtevi() RETURNS TABLE(processed_count integer, approved_count integer, alternative_count integer, log_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM public.process_pending_zahtevi_slots();
END;
$$;


ALTER FUNCTION public.manual_process_zahtevi() OWNER TO postgres;

--
-- Name: notify_push(jsonb, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb DEFAULT NULL::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  supabase_url text;
  anon_key text;
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
      'apikey', anon_key
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
$$;


ALTER FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) OWNER TO postgres;

--
-- Name: FUNCTION notify_push(tokens jsonb, title text, body text, data jsonb); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) IS 'Canonical push gateway (FCM-only). Called by domain-specific wrappers; keep grants restricted to service_role.';


--
-- Name: process_pending_zahtevi(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.process_pending_zahtevi() RETURNS TABLE(processed_count integer, approved_count integer, alternative_count integer, log_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
    pending_obrada int;
begin
    select count(*)::int
    into pending_obrada
    from public.v3_zahtevi z
    where z.status = 'obrada'
      and not exists (
          select 1
          from public.v3_app_settings s
          cross join lateral jsonb_array_elements_text(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_txt)
          where d.day_txt ~ '^\d{4}-\d{2}-\d{2}$'
            and d.day_txt::date = z.datum::date
      );

    if pending_obrada = 0 then
        return query select 0, 0, 0, 'Nema pending obrada zahteva (ili su na neradni dan).';
        return;
    end if;

    return query select * from public.process_pending_zahtevi_slots();
end;
$_$;


ALTER FUNCTION public.process_pending_zahtevi() OWNER TO postgres;

--
-- Name: process_pending_zahtevi_slots(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.process_pending_zahtevi_slots() RETURNS TABLE(processed integer, approved integer, alternative integer, message text)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
    zahtev_record record;
    current_ts timestamptz := now();
    processed int := 0;
    approved int := 0;
    alternative int := 0;
    capacity_check boolean;
    should_approve boolean;
    max_kapacitet integer;
    existing_mesta integer;
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
          and z.scheduled_at is not null
          and z.scheduled_at <= current_ts
          and not exists (
              select 1
              from public.v3_app_settings s
              cross join lateral jsonb_array_elements(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_obj)
              where d.day_obj->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
                and (d.day_obj->>'date')::date = z.datum::date
          )
        order by z.scheduled_at asc, z.created_at asc, z.id asc
        for update of z skip locked
    loop
        should_approve := true;
        capacity_check := true;
        best_alt_pre := null;
        best_alt_posle := null;
        alt_reason := 'Trenutno nema slobodnih mesta za zeljeni termin.';

        v_trazeni := zahtev_record.trazeni_polazak_at;

        if zahtev_record.tip_putnika = 'posiljka' then
            capacity_check := false;
        end if;

        if capacity_check then
            select ks.max_mesta into max_kapacitet
            from v3_kapacitet_slots ks
            where ks.grad = zahtev_record.grad
              and ks.vreme = v_trazeni
              and ks.datum = zahtev_record.datum::date
            limit 1;

            if max_kapacitet is null then
                continue;
            else
                select count(*)::int into existing_mesta
                from v3_operativna_nedelja o
                left join v3_auth pa on pa.id = o.created_by
                where o.datum::date = zahtev_record.datum::date
                  and o.grad = zahtev_record.grad
                  and o.polazak_at = v_trazeni
                  and o.otkazano_at is null
                  and lower(btrim(coalesce(pa.tip, ''))) <> 'posiljka';

                if (existing_mesta + 1) > max_kapacitet then
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
                with usage_by_slot as (
                    select ks.vreme, ks.max_mesta,
                           coalesce(occ.used_mesta, 0) as used_mesta
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
                    where ks.grad = zahtev_record.grad
                      and ks.datum = zahtev_record.datum::date
                )
                select max(vreme) into best_alt_pre
                from usage_by_slot
                where vreme < v_trazeni
                  and vreme >= (v_trazeni - interval '180 minutes')
                  and (used_mesta + 1) <= max_mesta;

                with usage_by_slot as (
                    select ks.vreme, ks.max_mesta,
                           coalesce(occ.used_mesta, 0) as used_mesta
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
                    where ks.grad = zahtev_record.grad
                      and ks.datum = zahtev_record.datum::date
                )
                select min(vreme) into best_alt_posle
                from usage_by_slot
                where vreme > v_trazeni
                  and vreme <= (v_trazeni + interval '180 minutes')
                  and (used_mesta + 1) <= max_mesta;
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


ALTER FUNCTION public.process_pending_zahtevi_slots() OWNER TO postgres;

--
-- Name: seed_kapacitet_slots_for_active_week(date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date DEFAULT NULL::date) RETURNS integer
    LANGUAGE plpgsql
    AS $$
declare
  v_week_start date;
  v_bc jsonb;
  v_vs jsonb;
  v_day text;
  v_day_idx int;
  v_time text;
  v_inserted int := 0;
  v_rows int := 0;
  v_deleted int := 0;
  v_max_mesta int;
begin
  select
    coalesce(p_week_start, active_week_start),
    coalesce(bc_custom_by_day, '{}'::jsonb),
    coalesce(vs_custom_by_day, '{}'::jsonb)
  into v_week_start, v_bc, v_vs
  from public.v3_app_settings
  where id = 'global'
  limit 1;

  if v_week_start is null then
    return 0;
  end if;

  delete from public.v3_kapacitet_slots
  where datum < v_week_start;
  get diagnostics v_deleted = row_count;
  if v_deleted > 0 then
    raise notice 'seed_kapacitet_slots_for_active_week: obrisano % starih slotova pre %', v_deleted, v_week_start;
  end if;

  for v_day_idx, v_day in
    select ordinality::int, day_name
    from unnest(array['Ponedeljak','Utorak','Sreda','Cetvrtak','Petak']) with ordinality as t(day_name, ordinality)
  loop
    for v_time in
      select trim(x.value #>> '{}')
      from jsonb_array_elements(coalesce(v_bc -> v_day, '[]'::jsonb)) as x(value)
    loop
      begin
        v_max_mesta := 9;
        if v_time in ('06:00', '07:00', '07:15') then
          v_max_mesta := 10;
        end if;

        insert into public.v3_kapacitet_slots (grad, vreme, datum, max_mesta)
        values ('BC', v_time::time, (v_week_start + (v_day_idx - 1)), v_max_mesta)
        on conflict (grad, vreme, datum) do nothing;
        get diagnostics v_rows = row_count;
        v_inserted := v_inserted + v_rows;
      exception when others then
        continue;
      end;
    end loop;

    for v_time in
      select trim(x.value #>> '{}')
      from jsonb_array_elements(coalesce(v_vs -> v_day, '[]'::jsonb)) as x(value)
    loop
      begin
        insert into public.v3_kapacitet_slots (grad, vreme, datum, max_mesta)
        values ('VS', v_time::time, (v_week_start + (v_day_idx - 1)), 9)
        on conflict (grad, vreme, datum) do nothing;
        get diagnostics v_rows = row_count;
        v_inserted := v_inserted + v_rows;
      exception when others then
        continue;
      end;
    end loop;
  end loop;

  return v_inserted;
end;
$$;


ALTER FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date) OWNER TO postgres;

--
-- Name: FUNCTION seed_kapacitet_slots_for_active_week(p_week_start date); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date) IS 'Brise v3_kapacitet_slots redove starije od aktivne nedelje i zasejava slotove za aktivnu nedelju iz bc/vs_custom_by_day rasporeda sa default kapacitetima (BC 06:00/07:00/07:15=10, svi ostali BC i VS=9). Poziva se nedeljno preko pg_cron joba seed_kapacitet_slots_active_week.';


--
-- Name: set_current_timestamp(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_current_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    NEW.created_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_current_timestamp() OWNER TO postgres;

--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_updated_at() OWNER TO postgres;

--
-- Name: set_zahtev_scheduled_at(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_zahtev_scheduled_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
    if new.status is distinct from 'obrada' then
        return new;
    end if;

    if new.scheduled_at is not null then
        return new;
    end if;

    new.scheduled_at := coalesce(new.created_at, now()) + interval '10 minutes';
    return new;
end;
$$;


ALTER FUNCTION public.set_zahtev_scheduled_at() OWNER TO postgres;

--
-- Name: transfer_to_operativna_nedelja(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.transfer_to_operativna_nedelja() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
    target_time time;
BEGIN
    target_time := COALESCE(NEW.polazak_at, NEW.trazeni_polazak_at);

    IF NEW.status = 'obrada' THEN
        UPDATE public.v3_operativna_nedelja o
        SET otkazano_at = now(),
            otkazano_by = COALESCE(NEW.updated_by, NEW.created_by),
            updated_at = now(),
            updated_by = COALESCE(NEW.updated_by, NEW.created_by)
        WHERE o.created_by IS NOT DISTINCT FROM NEW.created_by
          AND o.datum = NEW.datum
          AND o.grad = NEW.grad
          AND o.otkazano_at IS NULL;

    ELSIF NEW.status = 'odobreno' THEN
        UPDATE public.v3_operativna_nedelja o
        SET polazak_at = target_time,
            koristi_sekundarnu = COALESCE(NEW.koristi_sekundarnu, false),
            adresa_override_id = NEW.adresa_override_id,
            otkazano_at = NULL,
            otkazano_by = NULL,
            updated_at = now(),
            updated_by = NEW.updated_by
        WHERE o.created_by IS NOT DISTINCT FROM NEW.created_by
          AND o.datum = NEW.datum
          AND o.grad = NEW.grad
          AND o.otkazano_at IS NULL;

        IF NOT FOUND THEN
            INSERT INTO public.v3_operativna_nedelja (
                datum,
                grad,
                polazak_at,
                koristi_sekundarnu,
                adresa_override_id,
                created_at,
                created_by,
                updated_at,
                updated_by
            ) VALUES (
                NEW.datum,
                NEW.grad,
                target_time,
                COALESCE(NEW.koristi_sekundarnu, false),
                NEW.adresa_override_id,
                now(),
                NEW.created_by,
                now(),
                NEW.updated_by
            );
        END IF;

    ELSIF NEW.status IN ('alternativa','odbijeno','otkazano')
          AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        UPDATE public.v3_operativna_nedelja o
        SET otkazano_at = now(),
            otkazano_by = NEW.updated_by,
            updated_at = now(),
            updated_by = NEW.updated_by
        WHERE o.created_by IS NOT DISTINCT FROM NEW.created_by
          AND o.datum = NEW.datum
          AND o.grad = NEW.grad;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.transfer_to_operativna_nedelja() OWNER TO postgres;

--
-- Name: v3_auth_find_id_by_phone(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_auth_find_id_by_phone(p_telefon text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_input text;
  v_input_digits text;
  v_id uuid;
begin
  v_input := btrim(coalesce(p_telefon, ''));
  if v_input = '' then
    return null;
  end if;

  v_input_digits := regexp_replace(v_input, '[^0-9]', '', 'g');

  select a.id
    into v_id
  from public.v3_auth a
  where
    a.telefon = v_input
    or a.telefon_2 = v_input
    or public.v3_normalize_phone(a.telefon) = public.v3_normalize_phone(v_input)
    or public.v3_normalize_phone(a.telefon_2) = public.v3_normalize_phone(v_input)
    or regexp_replace(coalesce(a.telefon, ''), '[^0-9]', '', 'g') = v_input_digits
    or regexp_replace(coalesce(a.telefon_2, ''), '[^0-9]', '', 'g') = v_input_digits
  limit 1;

  return v_id;
end;
$$;


ALTER FUNCTION public.v3_auth_find_id_by_phone(p_telefon text) OWNER TO postgres;

--
-- Name: v3_auth_phone_exists(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_auth_phone_exists(p_telefon text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  return exists (
    select 1
    from public.v3_auth a
    where (
      public.v3_normalize_phone(a.telefon) = public.v3_normalize_phone(p_telefon)
      or public.v3_normalize_phone(a.telefon_2) = public.v3_normalize_phone(p_telefon)
    )
  );
end;
$$;


ALTER FUNCTION public.v3_auth_phone_exists(p_telefon text) OWNER TO postgres;

--
-- Name: v3_check_otkazane_voznje_consistency(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) RETURNS TABLE(putnik_v3_auth_id uuid, operativna_count bigint, finansije_count bigint, inconsistent boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  WITH operativna_counts AS (
    SELECT
      o.created_by AS putnik_id,
      count(*) AS cnt
    FROM public.v3_operativna_nedelja o
    WHERE o.otkazano_at IS NOT NULL
      AND EXTRACT(YEAR FROM o.datum)::int = p_godina
      AND EXTRACT(MONTH FROM o.datum)::int = p_mesec
    GROUP BY o.created_by
  ),
  finansije_counts AS (
    SELECT
      f.putnik_v3_auth_id AS putnik_id,
      COALESCE(sum(jsonb_array_length(COALESCE(f.otkazane_voznje_json, '[]'::jsonb))), 0) AS cnt
    FROM public.v3_finansije f
    WHERE f.tip = 'prihod'
      AND f.kategorija = 'operativna_naplata'
      AND f.godina = p_godina
      AND f.mesec = p_mesec
    GROUP BY f.putnik_v3_auth_id
  )
  SELECT
    COALESCE(o.putnik_id, f.putnik_id) AS putnik_v3_auth_id,
    COALESCE(o.cnt, 0) AS operativna_count,
    COALESCE(f.cnt, 0) AS finansije_count,
    COALESCE(o.cnt, 0) != COALESCE(f.cnt, 0) AS inconsistent
  FROM operativna_counts o
  FULL OUTER JOIN finansije_counts f ON o.putnik_id = f.putnik_id
  WHERE COALESCE(o.cnt, 0) != COALESCE(f.cnt, 0);
$$;


ALTER FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) OWNER TO postgres;

--
-- Name: FUNCTION v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) IS 'Vraća putnike kod kojih se broj otkazivanja u operativnoj tabeli i finansijama ne poklapa.';


--
-- Name: v3_find_termins_for_auto_prepare(date, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) RETURNS TABLE(id uuid, datum date, grad text, polazak_at time without time zone, created_by uuid, vozac_id uuid, koristi_sekundarnu boolean, adresa_override_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER
    AS $$
  SELECT
    o.id,
    o.datum,
    o.grad,
    o.polazak_at,
    o.created_by,
    td.vozac_v3_auth_id AS vozac_id,
    o.koristi_sekundarnu,
    o.adresa_override_id
  FROM public.v3_operativna_nedelja o
  JOIN public.v3_trenutna_dodela td ON td.termin_id = o.id
  WHERE o.datum = p_datum
    AND o.pokupljen_at IS NULL
    AND o.otkazano_at IS NULL
    AND o.polazak_at >= p_start_time::time
    AND o.polazak_at < p_end_time::time
  ORDER BY o.polazak_at, o.grad, td.vozac_v3_auth_id;
$$;


ALTER FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) OWNER TO postgres;

--
-- Name: FUNCTION v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) IS 'Pronalazi termine koji pocinju u zadatom vremenskom prozoru i imaju dodeljenog vozaca';


--
-- Name: v3_gorivo_dnevni_prosek(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_gorivo_dnevni_prosek() RETURNS TABLE(prosek_litri numeric, radnih_dana integer, ukupno_litri numeric)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  with granice as (
    select (min(created_at) at time zone 'Europe/Belgrade')::date as prvi_dan
    from public.v3_gorivo_istorija
    where vrsta in ('potrosnja', 'dopuna')
      and coalesce(source, '') <> 'inicijalni_import'
  ),
  dani as (
    select generate_series(
      (select prvi_dan from granice),
      (now() at time zone 'Europe/Belgrade')::date,
      interval '1 day'
    )::date as dan
  ),
  ukupno as (
    select coalesce(sum(litri), 0) as litri
    from public.v3_gorivo_istorija
    where vrsta = 'potrosnja'
      and coalesce(source, '') <> 'inicijalni_import'
  )
  select case when count(d.dan) = 0 then 0
              else round((select litri from ukupno) / count(d.dan), 1)
         end,
         count(d.dan)::integer,
         (select litri from ukupno)
  from dani d
  where extract(isodow from d.dan) between 1 and 5;
$$;


ALTER FUNCTION public.v3_gorivo_dnevni_prosek() OWNER TO postgres;

--
-- Name: v3_gorivo_dnevni_prosek_uplata(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_gorivo_dnevni_prosek_uplata() RETURNS TABLE(prosek_rsd numeric, radnih_dana integer, ukupno_rsd numeric)
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  with granice as (
    select (min(created_at) at time zone 'Europe/Belgrade')::date as prvi_dan
    from public.v3_gorivo_istorija
    where vrsta in ('potrosnja', 'dopuna')
      and coalesce(source, '') <> 'inicijalni_import'
  ),
  dani as (
    select generate_series(
      (select prvi_dan from granice),
      (now() at time zone 'Europe/Belgrade')::date,
      interval '1 day'
    )::date as dan
  ),
  ukupno as (
    select coalesce(sum(dug_promena), 0) as rsd
    from public.v3_gorivo_istorija
    where vrsta = 'uplata'
  )
  select case when count(d.dan) = 0 then 0
              else round((select rsd from ukupno) / count(d.dan), 2)
         end,
         count(d.dan)::integer,
         (select rsd from ukupno)
  from dani d
  where extract(isodow from d.dan) between 1 and 5;
$$;


ALTER FUNCTION public.v3_gorivo_dnevni_prosek_uplata() OWNER TO postgres;

--
-- Name: v3_gorivo_log_delta_history(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_gorivo_log_delta_history() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  potrosnja_delta numeric(12,3) := 0;
  dopuna_delta numeric(12,3) := 0;
  dug_delta numeric(12,2) := 0;
  brojac_porastao boolean;
begin
  brojac_porastao :=
    coalesce(new.brojac_pistolj_litri, 0) > coalesce(old.brojac_pistolj_litri, 0);
  dug_delta :=
    coalesce(new.dug_iznos, 0) - coalesce(old.dug_iznos, 0);

  if brojac_porastao then
    potrosnja_delta := greatest(
      coalesce(old.trenutno_stanje_litri, 0) - coalesce(new.trenutno_stanje_litri, 0),
      0
    );
  elsif new.brojac_pistolj_litri is not distinct from old.brojac_pistolj_litri then
    dopuna_delta := greatest(
      coalesce(new.trenutno_stanje_litri, 0) - coalesce(old.trenutno_stanje_litri, 0),
      0
    );
  end if;

  if potrosnja_delta > 0 then
    insert into public.v3_gorivo_istorija (gorivo_id, vrsta, litri, source)
    values (new.id::text, 'potrosnja', potrosnja_delta, 'brojac_delta');
  end if;

  if dopuna_delta > 0 then
    insert into public.v3_gorivo_istorija
      (gorivo_id, vrsta, litri, cena_po_litru, dug_promena, source)
    values (
      new.id::text,
      'dopuna',
      dopuna_delta,
      nullif(new.cena_po_litru, 0),
      nullif(greatest(dug_delta, 0), 0),
      'rezervoar_plus'
    );
  end if;

  if dug_delta < 0 then
    insert into public.v3_gorivo_istorija
      (gorivo_id, vrsta, litri, dug_promena, source)
    values (new.id::text, 'uplata', 0, -dug_delta, 'dug_delta');
  elsif dug_delta > 0 and dopuna_delta <= 0 then
    insert into public.v3_gorivo_istorija
      (gorivo_id, vrsta, litri, dug_promena, source)
    values (new.id::text, 'korekcija', 0, dug_delta, 'dug_delta');
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.v3_gorivo_log_delta_history() OWNER TO postgres;

--
-- Name: FUNCTION v3_gorivo_log_delta_history(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_gorivo_log_delta_history() IS 'Log potrošnje (pad rezervoara pri porastu brojača), dopune (rast rezervoara + dug koji je dodat), uplata (pad duga) i korekcija duga (rast duga bez dopune).';


--
-- Name: v3_gorivo_set_trenutno_from_brojac(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_gorivo_set_trenutno_from_brojac() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if TG_OP = 'INSERT' then
    return new;
  end if;

  if new.brojac_pistolj_litri is distinct from old.brojac_pistolj_litri then
    new.trenutno_stanje_litri := greatest(
      least(
        coalesce(old.trenutno_stanje_litri, 0)
          - (coalesce(new.brojac_pistolj_litri, 0) - coalesce(old.brojac_pistolj_litri, 0)),
        coalesce(new.kapacitet_litri, old.kapacitet_litri, 0)
      ),
      0
    );
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.v3_gorivo_set_trenutno_from_brojac() OWNER TO postgres;

--
-- Name: FUNCTION v3_gorivo_set_trenutno_from_brojac(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_gorivo_set_trenutno_from_brojac() IS 'Delta-bazirano umanjenje trenutno_stanje_litri kada se promeni kumulativni brojac_pistolj_litri (potrošnja). Kapacitet_litri je fiksna gornja granica (max litara u cisterni), ne koristi se kao apsolutna referenca.';


--
-- Name: v3_gorivo_sum_potrosnja(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone) RETURNS numeric
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(sum(litri), 0)
  from public.v3_gorivo_istorija
  where vrsta = 'potrosnja'
    and created_at >= p_start
    and created_at < p_end
    and coalesce(source, '') <> 'inicijalni_import';
$$;


ALTER FUNCTION public.v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone) OWNER TO postgres;

--
-- Name: v3_maybe_cleanup_old_operativna_data(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_maybe_cleanup_old_operativna_data() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_local_ts timestamp := (now() at time zone 'Europe/Belgrade');
  v_today date := v_local_ts::date;
  v_last_run date;
BEGIN
  -- Ciljni prozor: subota (dow=6), 00:00-03:04:59 lokalno.
  IF extract(dow from v_local_ts) <> 6
     OR v_local_ts::time < time '00:00'
     OR v_local_ts::time >= time '03:05' THEN
    RETURN;
  END IF;

  SELECT last_run_date INTO v_last_run
  FROM public.v3_cron_state WHERE job_name = 'cleanup_old_operativna_data';

  IF v_last_run IS NOT DISTINCT FROM v_today THEN
    RETURN; -- vec odradjeno danas
  END IF;

  -- Brise podatke iz prethodne radne nedelje (ponedeljak-petak)
  -- v_today je subota, prethodna radna nedelja: v_today-5 (ponedeljak) do v_today-1 (petak)

  -- 1. v3_zahtevi - brisi zahteve iz prethodne radne nedelje
  DELETE FROM public.v3_zahtevi
  WHERE datum::date >= (v_today - INTERVAL '5 days')
    AND datum::date <= (v_today - INTERVAL '1 day');

  -- 2. v3_trenutna_dodela - brisi dodele iz prethodne radne nedelje
  DELETE FROM public.v3_trenutna_dodela td
  USING public.v3_operativna_nedelja o
  WHERE td.termin_id = o.id
    AND o.datum::date >= (v_today - INTERVAL '5 days')
    AND o.datum::date <= (v_today - INTERVAL '1 day');

  -- 3. v3_trenutna_dodela_slot - brisi slotove iz prethodne radne nedelje
  DELETE FROM public.v3_trenutna_dodela_slot
  WHERE datum::date >= (v_today - INTERVAL '5 days')
    AND datum::date <= (v_today - INTERVAL '1 day');

  -- 4. v3_operativna_nedelja - brisi operativne stavke iz prethodne radne nedelje
  DELETE FROM public.v3_operativna_nedelja
  WHERE datum::date >= (v_today - INTERVAL '5 days')
    AND datum::date <= (v_today - INTERVAL '1 day');

  INSERT INTO public.v3_cron_state (job_name, last_run_date)
  VALUES ('cleanup_old_operativna_data', v_today)
  ON CONFLICT (job_name) DO UPDATE SET last_run_date = excluded.last_run_date;
END;
$$;


ALTER FUNCTION public.v3_maybe_cleanup_old_operativna_data() OWNER TO postgres;

--
-- Name: FUNCTION v3_maybe_cleanup_old_operativna_data(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_maybe_cleanup_old_operativna_data() IS 'DST-otporna funkcija za ciscenje starih operativnih podataka - pokrece se svakih 5 min, ali izvrsava logiku samo jednom, subotom u 00:00-03:04 po Europe/Belgrade lokalnom vremenu (noc petak-subota). Brise v3_zahtevi, v3_trenutna_dodela, v3_trenutna_dodela_slot, v3_operativna_nedelja iz prethodne radne nedelje (ponedeljak-petak, v_today-5 do v_today-1).';


--
-- Name: v3_maybe_seed_kapacitet_slots(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_maybe_seed_kapacitet_slots() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_local_ts timestamp := (now() at time zone 'Europe/Belgrade');
  v_today date := v_local_ts::date;
  v_last_run date;
BEGIN
  IF extract(dow from v_local_ts) <> 6
     OR v_local_ts::time < time '03:05'
     OR v_local_ts::time >= time '03:10' THEN
    RETURN;
  END IF;

  SELECT last_run_date INTO v_last_run
  FROM public.v3_cron_state WHERE job_name = 'seed_kapacitet_slots_active_week';

  IF v_last_run IS NOT DISTINCT FROM v_today THEN
    RETURN;
  END IF;

  PERFORM public.seed_kapacitet_slots_for_active_week();

  INSERT INTO public.v3_cron_state (job_name, last_run_date)
  VALUES ('seed_kapacitet_slots_active_week', v_today)
  ON CONFLICT (job_name) DO UPDATE SET last_run_date = excluded.last_run_date;
END;
$$;


ALTER FUNCTION public.v3_maybe_seed_kapacitet_slots() OWNER TO postgres;

--
-- Name: FUNCTION v3_maybe_seed_kapacitet_slots(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_maybe_seed_kapacitet_slots() IS 'DST-otporna zamena za direktan cron poziv seed_kapacitet_slots_for_active_week - pokrece se svakih 5 min, ali izvrsava logiku samo jednom, subotom u 03:05 po Europe/Belgrade lokalnom vremenu (posle update_active_week).';


--
-- Name: v3_maybe_update_active_week(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_maybe_update_active_week() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_local_ts timestamp := (now() at time zone 'Europe/Belgrade');
  v_today date := v_local_ts::date;
  v_last_run date;
BEGIN
  IF extract(dow from v_local_ts) <> 6
     OR v_local_ts::time < time '03:00'
     OR v_local_ts::time >= time '03:05' THEN
    RETURN;
  END IF;

  SELECT last_run_date INTO v_last_run
  FROM public.v3_cron_state WHERE job_name = 'update_active_week';

  IF v_last_run IS NOT DISTINCT FROM v_today THEN
    RETURN;
  END IF;

  UPDATE public.v3_app_settings
  SET active_week_start = v_today + INTERVAL '2 days',
      active_week_end = v_today + INTERVAL '8 days'
  WHERE id = 'global';

  INSERT INTO public.v3_cron_state (job_name, last_run_date)
  VALUES ('update_active_week', v_today)
  ON CONFLICT (job_name) DO UPDATE SET last_run_date = excluded.last_run_date;
END;
$$;


ALTER FUNCTION public.v3_maybe_update_active_week() OWNER TO postgres;

--
-- Name: FUNCTION v3_maybe_update_active_week(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_maybe_update_active_week() IS 'DST-otporna zamena za direktan cron UPDATE - pokrece se svakih 5 min, ali izvrsava logiku samo jednom, subotom u 03:00 po Europe/Belgrade lokalnom vremenu.';


--
-- Name: v3_norm_hhmm(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_norm_hhmm(p_value text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE
    WHEN p_value IS NULL OR btrim(p_value) = '' THEN ''
    WHEN btrim(p_value) ~ '^[0-9]{1,2}:[0-9]{2}' THEN
      lpad(split_part(btrim(p_value), ':', 1), 2, '0')
      || ':'
      || lpad(substr(split_part(btrim(p_value), ':', 2), 1, 2), 2, '0')
    ELSE btrim(p_value)
  END
$$;


ALTER FUNCTION public.v3_norm_hhmm(p_value text) OWNER TO postgres;

--
-- Name: v3_normalize_phone(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_normalize_phone(p_telefon text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $$
declare
  raw text;
begin
  raw := regexp_replace(coalesce(p_telefon, ''), '[^0-9+]', '', 'g');

  if raw = '' then
    return '';
  end if;

  if left(raw, 1) = '+' then
    raw := '+' || replace(substring(raw from 2), '+', '');
  else
    raw := replace(raw, '+', '');
  end if;

  if raw like '+381%' then
    return raw;
  elsif raw like '00381%' then
    return '+381' || substring(raw from 6);
  elsif raw like '381%' then
    return '+' || raw;
  elsif raw like '0%' then
    return '+381' || substring(raw from 2);
  end if;

  return raw;
end;
$$;


ALTER FUNCTION public.v3_normalize_phone(p_telefon text) OWNER TO postgres;

--
-- Name: v3_notify_passengers_driver_started(uuid, date, text, time without time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

DECLARE
  v_grad text := upper(trim(coalesce(p_grad, '')));
  v_tokens jsonb;
  v_notified integer := 0;
  v_event_id text;
  v_termin_ids uuid[];
BEGIN
  IF p_vozac_id IS NULL OR p_datum IS NULL OR v_grad = '' OR p_vreme IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_args');
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


ALTER FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) OWNER TO postgres;

--
-- Name: FUNCTION v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) IS 'Push putnicima da je vozač krenuo — race-safe: najpre atomically claim preko UPDATE ... RETURNING, pa notify. Ukljucuje HMS tokene.';


--
-- Name: v3_notify_vozaci_weather_alert(text, text, text, text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

declare
  v_grad text := upper(trim(coalesce(p_grad, '')));
  v_condition text := lower(trim(coalesce(p_condition_code, '')));
  v_today date := (now() at time zone 'Europe/Belgrade')::date;
  v_claimed boolean := false;
  v_tokens jsonb;
  v_notified integer := 0;
  v_event_id text;
begin
  insert into public.v3_weather_alerts_sent (grad, condition_code, alert_date, severity)
  values (v_grad, v_condition, v_today, p_severity)
  on conflict (grad, condition_code, alert_date) do nothing;

  get diagnostics v_claimed = row_count;

  if not v_claimed then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_sent_today');
  end if;

  with token_rows as (
    select jsonb_build_object('token', a.push_token, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token is not null and btrim(a.push_token) <> ''

    union

    select jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_2 is not null and btrim(a.push_token_2) <> ''

    union

    select jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_3 is not null and btrim(a.push_token_3) <> ''
  )
  select coalesce(jsonb_agg(tkn), '[]'::jsonb), count(*)
  into v_tokens, v_notified
  from token_rows;

  if v_notified = 0 then
    return jsonb_build_object('ok', true, 'notified', 0);
  end if;

  v_event_id := format('weather_alert:%s:%s:%s', v_grad, v_condition, v_today::text);

  perform public.notify_push(
    v_tokens,
    p_title_sr,
    p_body_sr,
    jsonb_build_object(
      'type', 'weather_alert',
      'event_id', v_event_id,
      'grad', v_grad,
      'condition_code', v_condition,
      'severity', p_severity,
      'screen', 'v3_vozac',
      'title_sr', p_title_sr,
      'title_en', p_title_en,
      'title_ru', p_title_ru,
      'title_de', p_title_de,
      'body_sr', p_body_sr,
      'body_en', p_body_en,
      'body_ru', p_body_ru,
      'body_de', p_body_de
    )
  );

  return jsonb_build_object('ok', true, 'notified', v_notified, 'event_id', v_event_id);
end;
$$;


ALTER FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text) OWNER TO postgres;

--
-- Name: v3_notify_vozaci_weather_alert(text, text, text, text, text, text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text DEFAULT NULL::text, p_body_zh text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$

declare
  v_grad text := upper(trim(coalesce(p_grad, '')));
  v_condition text := lower(trim(coalesce(p_condition_code, '')));
  v_today date := (now() at time zone 'Europe/Belgrade')::date;
  v_claimed boolean := false;
  v_tokens jsonb;
  v_notified integer := 0;
  v_event_id text;
begin
  insert into public.v3_weather_alerts_sent (grad, condition_code, alert_date, severity)
  values (v_grad, v_condition, v_today, p_severity)
  on conflict (grad, condition_code, alert_date) do nothing;

  get diagnostics v_claimed = row_count;

  if not v_claimed then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_sent_today');
  end if;

  with token_rows as (
    select jsonb_build_object('token', a.push_token, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token is not null and btrim(a.push_token) <> ''

    union

    select jsonb_build_object('token', a.push_token_2, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_2 is not null and btrim(a.push_token_2) <> ''

    union

    select jsonb_build_object('token', a.push_token_3, 'provider', 'fcm') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_3 is not null and btrim(a.push_token_3) <> ''

    union

    select jsonb_build_object('token', a.push_token_hms, 'provider', 'hms') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_hms is not null and btrim(a.push_token_hms) <> ''

    union

    select jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_hms_2 is not null and btrim(a.push_token_hms_2) <> ''

    union

    select jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms') as tkn
    from public.v3_auth a
    where a.tip = 'vozac' and a.push_token_hms_3 is not null and btrim(a.push_token_hms_3) <> ''
  )
  select coalesce(jsonb_agg(tkn), '[]'::jsonb), count(*)
  into v_tokens, v_notified
  from token_rows;

  if v_notified = 0 then
    return jsonb_build_object('ok', true, 'notified', 0);
  end if;

  v_event_id := format('weather_alert:%s:%s:%s', v_grad, v_condition, v_today::text);

  perform public.notify_push(
    v_tokens,
    p_title_sr,
    p_body_sr,
    jsonb_build_object(
      'type', 'weather_alert',
      'event_id', v_event_id,
      'grad', v_grad,
      'condition_code', v_condition,
      'severity', p_severity,
      'screen', 'v3_vozac',
      'title_sr', p_title_sr,
      'title_en', p_title_en,
      'title_ru', p_title_ru,
      'title_de', p_title_de,
      'title_zh', p_title_zh,
      'body_sr', p_body_sr,
      'body_en', p_body_en,
      'body_ru', p_body_ru,
      'body_de', p_body_de,
      'body_zh', p_body_zh
    )
  );

  return jsonb_build_object('ok', true, 'notified', v_notified, 'event_id', v_event_id);
end;
$$;


ALTER FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text, p_body_zh text) OWNER TO postgres;

--
-- Name: v3_sync_otkazane_voznje_to_finansije(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_sync_otkazane_voznje_to_finansije() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_putnik_id uuid;
  v_datum date;
  v_mesec int;
  v_godina int;
  v_operativna_id uuid;
  v_otkazano_at timestamptz;
  v_otkazano_by uuid;
  v_grad text;
  v_vreme text;
  v_existing_id uuid;
  v_trenutne jsonb;
  v_nova_stavka jsonb;
  v_filtrirane jsonb;
  v_vec_postoji boolean;
  v_i int;
  v_item jsonb;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.otkazano_at IS NOT DISTINCT FROM OLD.otkazano_at THEN
    RETURN NEW;
  END IF;

  v_putnik_id := NEW.created_by;
  v_datum := NEW.datum;
  v_mesec := EXTRACT(MONTH FROM v_datum)::int;
  v_godina := EXTRACT(YEAR FROM v_datum)::int;
  v_operativna_id := NEW.id;
  v_otkazano_at := NEW.otkazano_at;
  v_otkazano_by := NEW.otkazano_by;
  v_grad := NEW.grad;
  v_vreme := NEW.polazak_at;

  IF v_putnik_id IS NULL OR v_datum IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT id, COALESCE(otkazane_voznje_json, '[]'::jsonb)
  INTO v_existing_id, v_trenutne
  FROM public.v3_finansije
  WHERE tip = 'prihod'
    AND kategorija = 'operativna_naplata'
    AND putnik_v3_auth_id = v_putnik_id
    AND mesec = v_mesec
    AND godina = v_godina
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_otkazano_at IS NULL THEN
    IF v_existing_id IS NOT NULL THEN
      v_filtrirane := '[]'::jsonb;
      FOR v_i IN 0 .. jsonb_array_length(v_trenutne) - 1 LOOP
        v_item := v_trenutne -> v_i;
        IF (v_item ->> 'operativna_id') IS DISTINCT FROM v_operativna_id::text THEN
          v_filtrirane := v_filtrirane || jsonb_build_array(v_item);
        END IF;
      END LOOP;

      IF v_filtrirane IS DISTINCT FROM v_trenutne THEN
        UPDATE public.v3_finansije
        SET otkazane_voznje_json = v_filtrirane,
            updated_at = now()
        WHERE id = v_existing_id;
      END IF;
    END IF;
  ELSE
    v_nova_stavka := jsonb_build_object(
      'operativna_id', v_operativna_id::text,
      'datum', v_datum::text,
      'otkazao_by', v_otkazano_by::text,
      'otkazano_at', to_char(v_otkazano_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'tip_otkazivanja', CASE WHEN v_otkazano_by = v_putnik_id THEN 'putnik' ELSE 'vozac' END,
      'grad', v_grad,
      'vreme', v_vreme
    );

    IF v_existing_id IS NULL THEN
      BEGIN
        INSERT INTO public.v3_finansije (
          naziv,
          kategorija,
          tip,
          iznos,
          putnik_v3_auth_id,
          broj_voznji,
          otkazane_voznje_json,
          mesec,
          godina
        ) VALUES (
          'Evidencija otkazivanja ' || v_mesec || '/' || v_godina,
          'operativna_naplata',
          'prihod',
          0,
          v_putnik_id,
          0,
          jsonb_build_array(v_nova_stavka),
          v_mesec,
          v_godina
        );
      EXCEPTION WHEN unique_violation THEN
        -- Aplikacija je uleteca prva i napravila master red — dopuni ga.
        SELECT id, COALESCE(otkazane_voznje_json, '[]'::jsonb)
          INTO v_existing_id, v_trenutne
        FROM public.v3_finansije
        WHERE tip = 'prihod'
          AND kategorija = 'operativna_naplata'
          AND putnik_v3_auth_id = v_putnik_id
          AND mesec = v_mesec
          AND godina = v_godina
        ORDER BY created_at DESC
        LIMIT 1;
      END;
    END IF;

    IF v_existing_id IS NOT NULL THEN
      v_vec_postoji := false;
      FOR v_i IN 0 .. jsonb_array_length(v_trenutne) - 1 LOOP
        IF (v_trenutne -> v_i ->> 'operativna_id') = v_operativna_id::text THEN
          v_vec_postoji := true;
          EXIT;
        END IF;
      END LOOP;

      IF NOT v_vec_postoji THEN
        UPDATE public.v3_finansije
        SET otkazane_voznje_json = v_trenutne || jsonb_build_array(v_nova_stavka),
            updated_at = now()
        WHERE id = v_existing_id;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.v3_sync_otkazane_voznje_to_finansije() OWNER TO postgres;

--
-- Name: FUNCTION v3_sync_otkazane_voznje_to_finansije(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_sync_otkazane_voznje_to_finansije() IS 'Održava v3_finansije.otkazane_voznje_json u sinhronizaciji sa v3_operativna_nedelja.otkazano_at (UTC ISO timestamp u JSON).';


--
-- Name: v3_sync_realizovane_voznje_to_finansije(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_sync_realizovane_voznje_to_finansije() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_putnik_id uuid;
  v_datum date;
  v_mesec int;
  v_godina int;
  v_operativna_id uuid;
  v_pokupljen_at timestamptz;
  v_pokupljen_by uuid;
  v_dodao_by uuid;
  v_azurirao_by uuid;
  v_grad text;
  v_vreme text;
  v_existing_id uuid;
  v_trenutne jsonb;
  v_nova_stavka jsonb;
  v_filtrirane jsonb;
  v_vec_postoji boolean;
  v_i int;
  v_item jsonb;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.pokupljen_at IS NOT DISTINCT FROM OLD.pokupljen_at THEN
    RETURN NEW;
  END IF;

  v_putnik_id := NEW.created_by;
  v_datum := NEW.datum;
  v_mesec := EXTRACT(MONTH FROM v_datum)::int;
  v_godina := EXTRACT(YEAR FROM v_datum)::int;
  v_operativna_id := NEW.id;
  v_pokupljen_at := NEW.pokupljen_at;
  v_pokupljen_by := NEW.pokupljen_by;
  v_dodao_by := NEW.created_by;
  v_azurirao_by := NEW.updated_by;
  v_grad := NEW.grad;
  v_vreme := NEW.polazak_at::text;

  IF v_putnik_id IS NULL OR v_datum IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT id, COALESCE(realizovane_voznje_json, '[]'::jsonb)
  INTO v_existing_id, v_trenutne
  FROM public.v3_finansije
  WHERE tip = 'prihod'
    AND kategorija = 'operativna_naplata'
    AND putnik_v3_auth_id = v_putnik_id
    AND mesec = v_mesec
    AND godina = v_godina
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_pokupljen_at IS NULL THEN
    IF v_existing_id IS NOT NULL THEN
      v_filtrirane := '[]'::jsonb;
      FOR v_i IN 0 .. jsonb_array_length(v_trenutne) - 1 LOOP
        v_item := v_trenutne -> v_i;
        IF (v_item ->> 'operativna_id') IS DISTINCT FROM v_operativna_id::text THEN
          v_filtrirane := v_filtrirane || jsonb_build_array(v_item);
        END IF;
      END LOOP;

      IF v_filtrirane IS DISTINCT FROM v_trenutne THEN
        UPDATE public.v3_finansije
        SET realizovane_voznje_json = v_filtrirane,
            updated_at = now()
        WHERE id = v_existing_id;
      END IF;
    END IF;
  ELSE
    v_nova_stavka := jsonb_build_object(
      'operativna_id', v_operativna_id::text,
      'datum', v_datum::text,
      'pokupljen_by', v_pokupljen_by::text,
      'pokupljen_at', to_char(v_pokupljen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
      'dodao_by', v_dodao_by::text,
      'azurirao_by', v_azurirao_by::text,
      'grad', v_grad,
      'vreme', v_vreme
    );

    IF v_existing_id IS NULL THEN
      BEGIN
        INSERT INTO public.v3_finansije (
          naziv,
          kategorija,
          tip,
          iznos,
          putnik_v3_auth_id,
          broj_voznji,
          realizovane_voznje_json,
          mesec,
          godina
        ) VALUES (
          'Evidencija realizacije ' || v_mesec || '/' || v_godina,
          'operativna_naplata',
          'prihod',
          0,
          v_putnik_id,
          0,
          jsonb_build_array(v_nova_stavka),
          v_mesec,
          v_godina
        );
      EXCEPTION WHEN unique_violation THEN
        -- Aplikacija je uleteca prva i napravila master red — dopuni ga.
        SELECT id, COALESCE(realizovane_voznje_json, '[]'::jsonb)
          INTO v_existing_id, v_trenutne
        FROM public.v3_finansije
        WHERE tip = 'prihod'
          AND kategorija = 'operativna_naplata'
          AND putnik_v3_auth_id = v_putnik_id
          AND mesec = v_mesec
          AND godina = v_godina
        ORDER BY created_at DESC
        LIMIT 1;
      END;
    END IF;

    IF v_existing_id IS NOT NULL THEN
      v_vec_postoji := false;
      FOR v_i IN 0 .. jsonb_array_length(v_trenutne) - 1 LOOP
        IF (v_trenutne -> v_i ->> 'operativna_id') = v_operativna_id::text THEN
          v_vec_postoji := true;
          EXIT;
        END IF;
      END LOOP;

      IF v_vec_postoji THEN
        UPDATE public.v3_finansije
        SET realizovane_voznje_json = (
            SELECT jsonb_agg(
              CASE
                WHEN (value ->> 'operativna_id') = v_operativna_id::text THEN v_nova_stavka
                ELSE value
              END
            )
            FROM jsonb_array_elements(v_trenutne)
          ),
          updated_at = now()
        WHERE id = v_existing_id;
      ELSE
        UPDATE public.v3_finansije
        SET realizovane_voznje_json = v_trenutne || jsonb_build_array(v_nova_stavka),
            updated_at = now()
        WHERE id = v_existing_id;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.v3_sync_realizovane_voznje_to_finansije() OWNER TO postgres;

--
-- Name: FUNCTION v3_sync_realizovane_voznje_to_finansije(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_sync_realizovane_voznje_to_finansije() IS 'Održava v3_finansije.realizovane_voznje_json u sinhronizaciji sa v3_operativna_nedelja.pokupljen_at (UTC ISO timestamp u JSON).';


--
-- Name: v3_trigger_auto_prepare(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_trigger_auto_prepare() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
    body := '{}'::jsonb
  );
END;
$$;


ALTER FUNCTION public.v3_trigger_auto_prepare() OWNER TO postgres;

--
-- Name: FUNCTION v3_trigger_auto_prepare(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_trigger_auto_prepare() IS 'Poziva v3-auto-prepare-termins edge funkciju svakog minuta';


--
-- Name: v3_trigger_weather_alert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.v3_trigger_weather_alert() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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
    body := '{}'::jsonb
  );
END;
$$;


ALTER FUNCTION public.v3_trigger_weather_alert() OWNER TO postgres;

--
-- Name: FUNCTION v3_trigger_weather_alert(); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.v3_trigger_weather_alert() IS 'Poziva v3-weather-alert edge funkciju svakih 30 minuta radi provere opasnih vremenskih uslova (sneg, poledica, magla, oluja, ekstremna vrucina)';


--
-- Name: v2_racuni_arhiva_broj_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.v2_racuni_arhiva_broj_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.v2_racuni_arhiva_broj_seq OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: v3_adrese; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_adrese (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    naziv text NOT NULL,
    grad text,
    gps_lat numeric,
    gps_lng numeric,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT ck_v3_adrese_grad_bc_vs CHECK ((grad = ANY (ARRAY['BC'::text, 'VS'::text]))),
    CONSTRAINT v2_adrese_grad_check CHECK ((grad = ANY (ARRAY['BC'::text, 'VS'::text])))
);

ALTER TABLE ONLY public.v3_adrese REPLICA IDENTITY FULL;


ALTER TABLE public.v3_adrese OWNER TO postgres;

--
-- Name: COLUMN v3_adrese.created_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_adrese.created_at IS 'Timestamp kada je adresa kreirana';


--
-- Name: CONSTRAINT v2_adrese_grad_check ON v3_adrese; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT v2_adrese_grad_check ON public.v3_adrese IS 'Dozvoljeni gradovi: BC (Bela Crkva), VS (Vrsac)';


--
-- Name: v3_app_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_app_settings (
    id text NOT NULL,
    store_url_android text,
    store_url_ios text,
    latest_version_android text,
    min_supported_version_android text,
    force_update_android boolean DEFAULT false NOT NULL,
    latest_version_ios text,
    min_supported_version_ios text,
    force_update_ios boolean DEFAULT false NOT NULL,
    bc_custom_by_day jsonb,
    vs_custom_by_day jsonb,
    neradni_dani jsonb DEFAULT '[]'::jsonb NOT NULL,
    maintenance_mode_android boolean DEFAULT false NOT NULL,
    maintenance_title_android text,
    maintenance_message_android text,
    maintenance_mode_ios boolean DEFAULT false NOT NULL,
    maintenance_title_ios text,
    maintenance_message_ios text,
    active_week_start date,
    active_week_end date,
    updated_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    nav_bar_type text DEFAULT 'custom'::text,
    info_banner jsonb,
    here_wego_install_url_android text,
    here_wego_install_url_ios text,
    maps_web_url_template text,
    maps_app_url_template_android text,
    maps_app_url_template_ios text,
    pazar_policy_start_date date
);

ALTER TABLE ONLY public.v3_app_settings REPLICA IDENTITY FULL;


ALTER TABLE public.v3_app_settings OWNER TO postgres;

--
-- Name: COLUMN v3_app_settings.info_banner; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.info_banner IS 'Jedna admin-kontrolisana info poruka: {enabled: bool, title: text, message: text, color: text}';


--
-- Name: COLUMN v3_app_settings.here_wego_install_url_android; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.here_wego_install_url_android IS 'Optional store listing URL for installing HERE WeGo on Android (served at runtime).';


--
-- Name: COLUMN v3_app_settings.here_wego_install_url_ios; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.here_wego_install_url_ios IS 'Optional store listing URL for installing HERE WeGo on iOS (served at runtime).';


--
-- Name: COLUMN v3_app_settings.maps_web_url_template; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.maps_web_url_template IS 'Deprecated — client no longer uses web maps fallback. Kept nullable for backward compatibility.';


--
-- Name: COLUMN v3_app_settings.maps_app_url_template_android; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.maps_app_url_template_android IS 'Passenger only: deep link to open Google Maps app on Android ({lat},{lng}). No web fallback in client.';


--
-- Name: COLUMN v3_app_settings.maps_app_url_template_ios; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.maps_app_url_template_ios IS 'Passenger only: deep link to open Google Maps app on iOS ({lat},{lng}). No web fallback in client.';


--
-- Name: COLUMN v3_app_settings.pazar_policy_start_date; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_app_settings.pazar_policy_start_date IS 'Activation date for mandatory daily pazar input policy (calendar date, Belgrade business logic).';


--
-- Name: v3_auth; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_auth (
    id uuid NOT NULL,
    telefon text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    push_token text,
    push_token_2 text,
    boja text,
    ime text,
    telefon_2 text,
    updated_at timestamp with time zone,
    cena_po_danu numeric,
    cena_po_pokupljenju numeric,
    adresa_primary_bc_id uuid,
    adresa_primary_vs_id uuid,
    adresa_secondary_bc_id uuid,
    adresa_secondary_vs_id uuid,
    tip text,
    installation_id text,
    installation_id_2 text,
    platform text,
    platform_2 text,
    app_version text,
    app_version_2 text,
    last_seen_at timestamp with time zone,
    last_seen_at_2 timestamp with time zone,
    hardware_id text,
    hardware_id_2 text,
    pin_hash text,
    pin_attempts integer DEFAULT 0 NOT NULL,
    pin_locked_until timestamp with time zone,
    locale_code text,
    uloga text DEFAULT 'vozac'::text NOT NULL,
    push_token_hms text,
    push_token_hms_2 text,
    push_token_provider text DEFAULT 'fcm'::text,
    installation_id_3 text,
    push_token_3 text,
    push_token_hms_3 text,
    hardware_id_3 text,
    platform_3 text,
    app_version_3 text,
    last_seen_at_3 timestamp with time zone,
    CONSTRAINT v3_auth_uloga_check CHECK ((uloga = ANY (ARRAY['vozac'::text, 'admin'::text, 'dispecer'::text, 'putnik'::text])))
);


ALTER TABLE public.v3_auth OWNER TO postgres;

--
-- Name: COLUMN v3_auth.pin_hash; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.pin_hash IS 'Hash bezbednosnog PIN koda korisnika (null = PIN nije podesen, isto ponasanje kao kod nedostajuce adrese).';


--
-- Name: COLUMN v3_auth.locale_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.locale_code IS 'Preferred app locale for localized push notifications (sr, en, ru, de).';


--
-- Name: COLUMN v3_auth.uloga; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.uloga IS 'Rola naloga: za vozac-tip naloge je vozac (podrazumevano)/admin/dispecer; za putnik-tip naloge je uvek putnik. Ne utice na login/rutiranje, koje i dalje zavisi od kolone tip.';


--
-- Name: COLUMN v3_auth.push_token_hms; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.push_token_hms IS 'HMS (Huawei Mobile Services) push token za Huawei uređaje bez GMS';


--
-- Name: COLUMN v3_auth.push_token_hms_2; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.push_token_hms_2 IS 'Sekundarni HMS push token (drugi uređaj istog korisnika)';


--
-- Name: COLUMN v3_auth.push_token_provider; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_auth.push_token_provider IS 'Aktivni push provider: fcm ili hms';


--
-- Name: v3_cron_state; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_cron_state (
    job_name text NOT NULL,
    last_run_date date
);


ALTER TABLE public.v3_cron_state OWNER TO postgres;

--
-- Name: TABLE v3_cron_state; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_cron_state IS 'Cuva datum poslednjeg izvrsavanja DST-osetljivih cron poslova (Europe/Belgrade lokalno vreme), da bi se sprecilo duplo izvrsavanje u okviru 5-minutnog prozora provere.';


--
-- Name: v3_device_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_device_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    v3_auth_id uuid NOT NULL,
    event_type text NOT NULL,
    replaced_slot integer,
    replaced_installation_id text,
    replaced_push_token text,
    new_installation_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.v3_device_events OWNER TO postgres;

--
-- Name: v3_eta_results; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_eta_results (
    termin_id uuid NOT NULL,
    putnik_id uuid NOT NULL,
    vozac_id uuid NOT NULL,
    eta_seconds integer NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL,
    slot_id uuid,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    optimized_order uuid[] DEFAULT '{}'::uuid[]
);

ALTER TABLE ONLY public.v3_eta_results REPLICA IDENTITY FULL;


ALTER TABLE public.v3_eta_results OWNER TO postgres;

--
-- Name: COLUMN v3_eta_results.slot_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_eta_results.slot_id IS 'Reference to the slot this ETA result belongs to. Ensures proper isolation between multiple slots.';


--
-- Name: COLUMN v3_eta_results.id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_eta_results.id IS 'Surogatni primary key — neophodan da Supabase Realtime ispravno emituje sadržaj reda kroz postgres_changes.';


--
-- Name: COLUMN v3_eta_results.optimized_order; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_eta_results.optimized_order IS 'Po-vozacki OSRM redosled putnik_id (v3_auth.id) u trenutku racunanja ETA';


--
-- Name: v3_finansije; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_finansije (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    naziv text NOT NULL,
    kategorija text,
    iznos numeric DEFAULT 0,
    isplata_iz text DEFAULT 'pazar'::text,
    mesec integer DEFAULT EXTRACT(month FROM CURRENT_DATE),
    godina integer DEFAULT EXTRACT(year FROM CURRENT_DATE),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    tip text DEFAULT 'rashod'::text NOT NULL,
    putnik_v3_auth_id uuid,
    naplaceno_by uuid,
    broj_voznji integer DEFAULT 0 NOT NULL,
    ime text,
    naplatio_ime text,
    poslednja_dopuna numeric(10,2) DEFAULT 0,
    nenaplacene_voznje_json jsonb DEFAULT '[]'::jsonb NOT NULL,
    realizovane_voznje_json jsonb DEFAULT '[]'::jsonb NOT NULL,
    otkazane_voznje_json jsonb DEFAULT '[]'::jsonb,
    uplate_json jsonb DEFAULT '[]'::jsonb,
    visak_iznos numeric DEFAULT 0 NOT NULL,
    preneti_visak_ulaz numeric DEFAULT 0 NOT NULL,
    preneti_visak_izlaz numeric DEFAULT 0 NOT NULL,
    CONSTRAINT v3_finansije_tip_check CHECK ((tip = ANY (ARRAY['prihod'::text, 'rashod'::text]))),
    CONSTRAINT v3_finansije_tip_kategorija_check CHECK ((((tip = 'prihod'::text) AND (kategorija = ANY (ARRAY['operativna_naplata'::text, 'operativna_realizacija'::text, 'dnevna_predaja'::text, 'operativna_otkazivanje'::text]))) OR ((tip = 'rashod'::text) AND (kategorija = ANY (ARRAY['plate'::text, 'kredit'::text, 'gorivo'::text, 'registracija'::text, 'yu_auto'::text, 'majstori'::text, 'porez'::text, 'alimentacija'::text, 'racuni'::text, 'ostalo'::text])))))
);

ALTER TABLE ONLY public.v3_finansije REPLICA IDENTITY FULL;


ALTER TABLE public.v3_finansije OWNER TO postgres;

--
-- Name: COLUMN v3_finansije.realizovane_voznje_json; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.realizovane_voznje_json IS 'Arhiva svih vožnji putnika u mesecu sa podacima ko je pokupio, ko je dodao/ažurirao, datum, grad i vreme. Trajno se čuva jer se v3_operativna_nedelja briše.';


--
-- Name: COLUMN v3_finansije.otkazane_voznje_json; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.otkazane_voznje_json IS 'Arhiva svih otkazivanja putnika u mesecu sa podacima ko je otkazao, kada, datum, grad i vreme. Trajno se čuva jer se v3_operativna_nedelja briše.';


--
-- Name: COLUMN v3_finansije.uplate_json; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.uplate_json IS 'Arhiva svih uplata za mesec sa podacima datum, iznos, ko je naplatio i vreme. Trajno se čuva za istoriju naplate i refundacije.';


--
-- Name: COLUMN v3_finansije.visak_iznos; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.visak_iznos IS 'Preplaćen iznos (kredit) za ovaj mesečni red, koji se prvo troši na naredne vožnje pre generisanja duga.';


--
-- Name: COLUMN v3_finansije.preneti_visak_ulaz; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.preneti_visak_ulaz IS 'Ukupan višak prenet U ovaj mesečni red iz ranijeg meseca (kumulativno).';


--
-- Name: COLUMN v3_finansije.preneti_visak_izlaz; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_finansije.preneti_visak_izlaz IS 'Ukupan višak prenet IZ ovog mesečnog reda u kasniji mesec (kumulativno).';


--
-- Name: v3_gorivo; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_gorivo (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kapacitet_litri numeric(12,2) DEFAULT 0 NOT NULL,
    trenutno_stanje_litri numeric(12,2) DEFAULT 0 NOT NULL,
    alarm_nivo_litri numeric(12,2) DEFAULT 0 NOT NULL,
    brojac_pistolj_litri numeric(12,2) DEFAULT 0 NOT NULL,
    cena_po_litru numeric(12,4) DEFAULT 0 NOT NULL,
    dug_iznos numeric(12,2) DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT v3_gorivo_alarm_nivo_litri_check CHECK ((alarm_nivo_litri >= (0)::numeric)),
    CONSTRAINT v3_gorivo_brojac_pistolj_litri_check CHECK ((brojac_pistolj_litri >= (0)::numeric)),
    CONSTRAINT v3_gorivo_cena_po_litru_check CHECK ((cena_po_litru >= (0)::numeric)),
    CONSTRAINT v3_gorivo_kapacitet_litri_check CHECK ((kapacitet_litri >= (0)::numeric)),
    CONSTRAINT v3_gorivo_trenutno_stanje_litri_check CHECK ((trenutno_stanje_litri >= (0)::numeric))
);

ALTER TABLE ONLY public.v3_gorivo REPLICA IDENTITY FULL;


ALTER TABLE public.v3_gorivo OWNER TO postgres;

--
-- Name: v3_gorivo_istorija; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_gorivo_istorija (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gorivo_id text,
    vrsta text NOT NULL,
    litri numeric(12,3) NOT NULL,
    cena_po_litru numeric(12,2),
    dug_promena numeric(12,2),
    napomena text,
    source text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT v3_gorivo_istorija_litri_check CHECK ((litri >= (0)::numeric)),
    CONSTRAINT v3_gorivo_istorija_vrsta_check CHECK ((vrsta = ANY (ARRAY['potrosnja'::text, 'dopuna'::text, 'korekcija'::text, 'uplata'::text])))
);


ALTER TABLE public.v3_gorivo_istorija OWNER TO postgres;

--
-- Name: TABLE v3_gorivo_istorija; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_gorivo_istorija IS 'Istorija promena goriva za periodične izveštaje potrošnje i dopuna.';


--
-- Name: COLUMN v3_gorivo_istorija.vrsta; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_gorivo_istorija.vrsta IS 'potrosnja | dopuna | korekcija | uplata';


--
-- Name: COLUMN v3_gorivo_istorija.litri; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_gorivo_istorija.litri IS 'Pozitivna količina litara za dati događaj.';


--
-- Name: COLUMN v3_gorivo_istorija.dug_promena; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_gorivo_istorija.dug_promena IS 'Iznos promene duga (RSD): rast duga za dopunu/korekciju, iznos uplate za uplatu.';


--
-- Name: v3_kapacitet_slots; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_kapacitet_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    grad text NOT NULL,
    vreme time without time zone NOT NULL,
    datum date NOT NULL,
    max_mesta integer DEFAULT 8 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_v3_kapacitet_slots_grad_bc_vs CHECK ((grad = ANY (ARRAY['BC'::text, 'VS'::text])))
);

ALTER TABLE ONLY public.v3_kapacitet_slots REPLICA IDENTITY FULL;


ALTER TABLE public.v3_kapacitet_slots OWNER TO postgres;

--
-- Name: v3_krediti; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_krediti (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    naziv text NOT NULL,
    ukupan_iznos numeric(12,2) DEFAULT 0 NOT NULL,
    uplaceno numeric(12,2) DEFAULT 0 NOT NULL,
    napomena text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    uplate_json jsonb DEFAULT '[]'::jsonb,
    kraj_kredita date
);


ALTER TABLE public.v3_krediti OWNER TO postgres;

--
-- Name: TABLE v3_krediti; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_krediti IS 'Licna dugovanja firme/vlasnika prema bankama, porodici, dobavljacima i sl. Razlicita od potrazivanja od putnika.';


--
-- Name: COLUMN v3_krediti.uplate_json; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_krediti.uplate_json IS 'Istorija svih uplata na kredit sa datumom, iznosom i opcionom napomenom.';


--
-- Name: COLUMN v3_krediti.kraj_kredita; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_krediti.kraj_kredita IS 'Opcioni datum kraja kredita ili zadnje rate.';


--
-- Name: v3_operativna_nedelja; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_operativna_nedelja (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datum date NOT NULL,
    grad text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    pokupljen_at timestamp with time zone,
    polazak_at time without time zone,
    pokupljen_by uuid,
    created_by uuid,
    updated_by uuid,
    koristi_sekundarnu boolean DEFAULT false,
    adresa_override_id uuid,
    otkazano_by uuid,
    otkazano_at timestamp with time zone,
    CONSTRAINT ck_v3_operativna_nedelja_grad_bc_vs CHECK ((grad = ANY (ARRAY['BC'::text, 'VS'::text])))
);

ALTER TABLE ONLY public.v3_operativna_nedelja REPLICA IDENTITY FULL;


ALTER TABLE public.v3_operativna_nedelja OWNER TO postgres;

--
-- Name: COLUMN v3_operativna_nedelja.adresa_override_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_operativna_nedelja.adresa_override_id IS 'Override adresa za ovaj unos. Ako je setovano, koristi se ova adresa umesto putnikove primarne/sekundarne.';


--
-- Name: v3_racuni; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_racuni (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    firma_naziv text,
    firma_pib text,
    firma_mb text,
    firma_ziro text,
    firma_adresa text,
    redni_broj integer,
    godina integer DEFAULT (EXTRACT(year FROM now()))::integer,
    status text DEFAULT 'kreirano'::text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.v3_racuni OWNER TO postgres;

--
-- Name: v3_servis_istorija; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_servis_istorija (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vozilo_id uuid NOT NULL,
    tip text NOT NULL,
    datum date NOT NULL,
    km integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.v3_servis_istorija OWNER TO postgres;

--
-- Name: TABLE v3_servis_istorija; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_servis_istorija IS 'Istorija servisa i zamena po vozilu za računanje prosečnih intervala (dani/km).';


--
-- Name: COLUMN v3_servis_istorija.tip; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_servis_istorija.tip IS 'mali_servis | veliki_servis | alternator | akumulator | plocice_prednje | plocice_zadnje | trap | gume_prednje | gume_zadnje';


--
-- Name: v3_trenutna_dodela; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_trenutna_dodela (
    putnik_v3_auth_id uuid NOT NULL,
    vozac_v3_auth_id uuid NOT NULL,
    termin_id uuid NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    slot_id uuid,
    adresa_gps_lat double precision,
    adresa_gps_lng double precision,
    driver_started_notified_at timestamp with time zone
);

ALTER TABLE ONLY public.v3_trenutna_dodela REPLICA IDENTITY FULL;


ALTER TABLE public.v3_trenutna_dodela OWNER TO postgres;

--
-- Name: COLUMN v3_trenutna_dodela.driver_started_notified_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela.driver_started_notified_at IS 'Kada je ovom putniku poslat push da je NJEGOV vozač krenuo. Idempotencija po individualnoj dodeli (multi-driver safe).';


--
-- Name: v3_trenutna_dodela_slot; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_trenutna_dodela_slot (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datum date NOT NULL,
    grad text NOT NULL,
    vreme time without time zone NOT NULL,
    vozac_v3_auth_id uuid NOT NULL,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    auto_prepared_at timestamp with time zone,
    auto_notified_at timestamp with time zone,
    optimized_order uuid[] DEFAULT '{}'::uuid[],
    tracking_started_at timestamp with time zone,
    vozilo_id uuid
);

ALTER TABLE ONLY public.v3_trenutna_dodela_slot REPLICA IDENTITY FULL;


ALTER TABLE public.v3_trenutna_dodela_slot OWNER TO postgres;

--
-- Name: COLUMN v3_trenutna_dodela_slot.auto_prepared_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela_slot.auto_prepared_at IS 'Kada su waypoints automatski kreirani 10 min pre polaska';


--
-- Name: COLUMN v3_trenutna_dodela_slot.auto_notified_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela_slot.auto_notified_at IS 'Kada je automatska push notifikacija poslata putnicima';


--
-- Name: COLUMN v3_trenutna_dodela_slot.optimized_order; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela_slot.optimized_order IS 'OSRM redosled putnik_id (v3_auth.id) za slot - pre-navigacija; live ETA koristi v3_eta_results.optimized_order';


--
-- Name: COLUMN v3_trenutna_dodela_slot.tracking_started_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela_slot.tracking_started_at IS 'Kada je vozac STVARNO pokrenuo tracking (foreground, rucno ili auto-start). Upisuje ga iskljucivo activateSlotWithRetry iz V3VozacLocationTrackingService.start(). Koristi se kao okidac za obavestavanje putnika, umesto slepog T-10min crona.';


--
-- Name: COLUMN v3_trenutna_dodela_slot.vozilo_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_trenutna_dodela_slot.vozilo_id IS 'Kombi dodeljen ovom konkretnom slotu (datum+grad+vreme). Ako je NULL, koristi se trajna dodela vozača (v3_vozila.vozac_id).';


--
-- Name: v3_uplata_pazara; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_uplata_pazara (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    vozac_id uuid NOT NULL,
    mesec integer NOT NULL,
    godina integer NOT NULL,
    dnevne_uplate_json jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.v3_uplata_pazara OWNER TO postgres;

--
-- Name: TABLE v3_uplata_pazara; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_uplata_pazara IS 'Mesecna evidencija uplata pazara po vozacu. Dnevne uplate se cuvaju u JSONB nizu.';


--
-- Name: COLUMN v3_uplata_pazara.dnevne_uplate_json; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_uplata_pazara.dnevne_uplate_json IS 'Niz dnevnih uplata pazara: [{dan, predao, ukupno, razlika}]';


--
-- Name: v3_vozac_location; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_vozac_location (
    vozac_id uuid NOT NULL,
    lat double precision NOT NULL,
    lng double precision NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    speed_kmh double precision
);


ALTER TABLE public.v3_vozac_location OWNER TO postgres;

--
-- Name: TABLE v3_vozac_location; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.v3_vozac_location IS 'Jedna trenutna GPS lokacija po vozaču. Ažurira je Flutter app svakih 20s. JEDINI izvor istine za lokaciju vozača.';


--
-- Name: COLUMN v3_vozac_location.vozac_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozac_location.vozac_id IS 'ID vozača (v3_auth). Jedan red po vozaču.';


--
-- Name: COLUMN v3_vozac_location.lat; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozac_location.lat IS 'Geografska širina.';


--
-- Name: COLUMN v3_vozac_location.lng; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozac_location.lng IS 'Geografska dužina.';


--
-- Name: COLUMN v3_vozac_location.updated_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozac_location.updated_at IS 'Vreme poslednjeg ažuriranja lokacije.';


--
-- Name: COLUMN v3_vozac_location.speed_kmh; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozac_location.speed_kmh IS 'Trenutna brzina u km/h iz GPS fix-a. Null ako nije dostupna.';


--
-- Name: v3_vozila; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_vozila (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    registracija text NOT NULL,
    marka text,
    model text,
    trenutna_km numeric(15,2) DEFAULT 0,
    updated_at timestamp with time zone DEFAULT now(),
    broj_sasije text,
    godina_proizvodnje integer,
    napomena text,
    registracija_vazi_do date,
    mali_servis_datum date,
    mali_servis_km integer,
    veliki_servis_datum date,
    veliki_servis_km integer,
    alternator_datum date,
    alternator_km integer,
    akumulator_datum date,
    akumulator_km integer,
    plocice_prednje_datum date,
    plocice_prednje_km integer,
    plocice_zadnje_datum date,
    plocice_zadnje_km integer,
    trap_datum date,
    trap_km integer,
    gume_prednje_datum date,
    gume_prednje_opis text,
    gume_prednje_km integer,
    gume_zadnje_datum date,
    gume_zadnje_opis text,
    gume_zadnje_km integer,
    radio text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    vozac_id uuid,
    boja text
);

ALTER TABLE ONLY public.v3_vozila REPLICA IDENTITY FULL;


ALTER TABLE public.v3_vozila OWNER TO postgres;

--
-- Name: COLUMN v3_vozila.vozac_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozila.vozac_id IS 'Vozač kome je kombi trenutno dodeljen. Jedan vozač = jedan kombi.';


--
-- Name: COLUMN v3_vozila.boja; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_vozila.boja IS 'Hex boja kombija (npr. #E53935) za vizuelnu identifikaciju u UI-u, nezavisno od boje vozača.';


--
-- Name: v3_weather_alerts_sent; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_weather_alerts_sent (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    grad text NOT NULL,
    condition_code text NOT NULL,
    alert_date date NOT NULL,
    severity text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.v3_weather_alerts_sent OWNER TO postgres;

--
-- Name: v3_zahtevi; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.v3_zahtevi (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    datum date DEFAULT CURRENT_DATE NOT NULL,
    grad text NOT NULL,
    trazeni_polazak_at time without time zone,
    status text DEFAULT 'obrada'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    polazak_at time without time zone,
    alternativa_pre_at time without time zone,
    alternativa_posle_at time without time zone,
    created_by uuid,
    updated_by uuid,
    koristi_sekundarnu boolean DEFAULT false,
    adresa_override_id uuid,
    scheduled_at timestamp with time zone,
    mesto_ponuda boolean DEFAULT false NOT NULL,
    mesto_ponuda_odbijena boolean DEFAULT false NOT NULL,
    mesto_ponuda_at timestamp with time zone,
    alternativa_offered_at timestamp with time zone,
    CONSTRAINT ck_v3_zahtevi_grad_bc_vs CHECK ((grad = ANY (ARRAY['BC'::text, 'VS'::text]))),
    CONSTRAINT valid_status_check CHECK ((status = ANY (ARRAY['obrada'::text, 'odobreno'::text, 'alternativa'::text, 'otkazano'::text, 'odbijeno'::text])))
);

ALTER TABLE ONLY public.v3_zahtevi REPLICA IDENTITY FULL;


ALTER TABLE public.v3_zahtevi OWNER TO postgres;

--
-- Name: COLUMN v3_zahtevi.mesto_ponuda; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_zahtevi.mesto_ponuda IS 'True dok je putniku poslat push da se oslobodilo mesto (status ostaje odbijeno).';


--
-- Name: COLUMN v3_zahtevi.mesto_ponuda_odbijena; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_zahtevi.mesto_ponuda_odbijena IS 'True ako je putnik odbio ponudu oslobođenog mesta — ne nudi se ponovo.';


--
-- Name: COLUMN v3_zahtevi.mesto_ponuda_at; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.v3_zahtevi.mesto_ponuda_at IS 'Kad je ponuda oslobođenog mesta poslata. Posle 10 minuta ide sledećem.';


--
-- Name: v3_racuni unique_invoice_number_per_year; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_racuni
    ADD CONSTRAINT unique_invoice_number_per_year UNIQUE (godina, redni_broj);


--
-- Name: v3_eta_results unique_slot_putnik; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT unique_slot_putnik UNIQUE (slot_id, putnik_id);


--
-- Name: v3_adrese v2_adrese_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_adrese
    ADD CONSTRAINT v2_adrese_pkey PRIMARY KEY (id);


--
-- Name: v3_app_settings v3_app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_app_settings
    ADD CONSTRAINT v3_app_settings_pkey PRIMARY KEY (id);


--
-- Name: v3_auth v3_auth_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_auth
    ADD CONSTRAINT v3_auth_pkey PRIMARY KEY (id);


--
-- Name: v3_cron_state v3_cron_state_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_cron_state
    ADD CONSTRAINT v3_cron_state_pkey PRIMARY KEY (job_name);


--
-- Name: v3_device_events v3_device_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_device_events
    ADD CONSTRAINT v3_device_events_pkey PRIMARY KEY (id);


--
-- Name: v3_eta_results v3_eta_results_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT v3_eta_results_pkey PRIMARY KEY (id);


--
-- Name: v3_finansije v3_finansije_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_finansije
    ADD CONSTRAINT v3_finansije_pkey PRIMARY KEY (id);


--
-- Name: v3_gorivo_istorija v3_gorivo_istorija_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_gorivo_istorija
    ADD CONSTRAINT v3_gorivo_istorija_pkey PRIMARY KEY (id);


--
-- Name: v3_gorivo v3_gorivo_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_gorivo
    ADD CONSTRAINT v3_gorivo_pkey PRIMARY KEY (id);


--
-- Name: v3_kapacitet_slots v3_kapacitet_slots_grad_vreme_datum_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_kapacitet_slots
    ADD CONSTRAINT v3_kapacitet_slots_grad_vreme_datum_key UNIQUE (grad, vreme, datum);


--
-- Name: v3_kapacitet_slots v3_kapacitet_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_kapacitet_slots
    ADD CONSTRAINT v3_kapacitet_slots_pkey PRIMARY KEY (id);


--
-- Name: v3_krediti v3_krediti_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_krediti
    ADD CONSTRAINT v3_krediti_pkey PRIMARY KEY (id);


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_pkey PRIMARY KEY (id);


--
-- Name: v3_racuni v3_racuni_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_racuni
    ADD CONSTRAINT v3_racuni_pkey PRIMARY KEY (id);


--
-- Name: v3_servis_istorija v3_servis_istorija_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_servis_istorija
    ADD CONSTRAINT v3_servis_istorija_pkey PRIMARY KEY (id);


--
-- Name: v3_trenutna_dodela v3_trenutna_dodela_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT v3_trenutna_dodela_pkey PRIMARY KEY (termin_id);


--
-- Name: v3_trenutna_dodela_slot v3_trenutna_dodela_slot_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela_slot
    ADD CONSTRAINT v3_trenutna_dodela_slot_pkey PRIMARY KEY (id);


--
-- Name: v3_trenutna_dodela_slot v3_trenutna_dodela_slot_unique_slot; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela_slot
    ADD CONSTRAINT v3_trenutna_dodela_slot_unique_slot UNIQUE (datum, grad, vreme);


--
-- Name: v3_uplata_pazara v3_uplata_pazara_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_uplata_pazara
    ADD CONSTRAINT v3_uplata_pazara_pkey PRIMARY KEY (id);


--
-- Name: v3_uplata_pazara v3_uplata_pazara_vozac_id_mesec_godina_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_uplata_pazara
    ADD CONSTRAINT v3_uplata_pazara_vozac_id_mesec_godina_key UNIQUE (vozac_id, mesec, godina);


--
-- Name: v3_vozac_location v3_vozac_location_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_vozac_location
    ADD CONSTRAINT v3_vozac_location_pkey PRIMARY KEY (vozac_id);


--
-- Name: v3_vozila v3_vozila_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_vozila
    ADD CONSTRAINT v3_vozila_pkey PRIMARY KEY (id);


--
-- Name: v3_vozila v3_vozila_registracija_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_vozila
    ADD CONSTRAINT v3_vozila_registracija_key UNIQUE (registracija);


--
-- Name: v3_weather_alerts_sent v3_weather_alerts_sent_grad_condition_code_alert_date_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_weather_alerts_sent
    ADD CONSTRAINT v3_weather_alerts_sent_grad_condition_code_alert_date_key UNIQUE (grad, condition_code, alert_date);


--
-- Name: v3_weather_alerts_sent v3_weather_alerts_sent_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_weather_alerts_sent
    ADD CONSTRAINT v3_weather_alerts_sent_pkey PRIMARY KEY (id);


--
-- Name: v3_zahtevi v3_zahtevi_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_zahtevi
    ADD CONSTRAINT v3_zahtevi_pkey PRIMARY KEY (id);


--
-- Name: idx_v3_adrese_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_adrese_updated_at ON public.v3_adrese USING btree (updated_at);


--
-- Name: idx_v3_app_settings_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_app_settings_updated_at ON public.v3_app_settings USING btree (updated_at);


--
-- Name: idx_v3_auth_adresa_primary_bc_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_adresa_primary_bc_id ON public.v3_auth USING btree (adresa_primary_bc_id);


--
-- Name: idx_v3_auth_adresa_primary_vs_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_adresa_primary_vs_id ON public.v3_auth USING btree (adresa_primary_vs_id);


--
-- Name: idx_v3_auth_adresa_secondary_bc_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_adresa_secondary_bc_id ON public.v3_auth USING btree (adresa_secondary_bc_id);


--
-- Name: idx_v3_auth_adresa_secondary_vs_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_adresa_secondary_vs_id ON public.v3_auth USING btree (adresa_secondary_vs_id);


--
-- Name: idx_v3_auth_push_token_hms; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_push_token_hms ON public.v3_auth USING btree (push_token_hms) WHERE (push_token_hms IS NOT NULL);


--
-- Name: idx_v3_auth_push_token_hms_2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_push_token_hms_2 ON public.v3_auth USING btree (push_token_hms_2) WHERE (push_token_hms_2 IS NOT NULL);


--
-- Name: idx_v3_auth_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_auth_updated_at ON public.v3_auth USING btree (updated_at);


--
-- Name: idx_v3_device_events_auth_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_device_events_auth_id ON public.v3_device_events USING btree (v3_auth_id);


--
-- Name: idx_v3_eta_results_computed_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_eta_results_computed_at ON public.v3_eta_results USING btree (computed_at);


--
-- Name: idx_v3_eta_results_slot_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_eta_results_slot_id ON public.v3_eta_results USING btree (slot_id);


--
-- Name: idx_v3_eta_results_vozac; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_eta_results_vozac ON public.v3_eta_results USING btree (vozac_id);


--
-- Name: idx_v3_finansije_putnik_period; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_finansije_putnik_period ON public.v3_finansije USING btree (putnik_v3_auth_id, godina, mesec);


--
-- Name: idx_v3_finansije_tip_kategorija; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_finansije_tip_kategorija ON public.v3_finansije USING btree (tip, kategorija);


--
-- Name: idx_v3_finansije_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_finansije_updated_at ON public.v3_finansije USING btree (updated_at);


--
-- Name: idx_v3_gorivo_istorija_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_gorivo_istorija_created_at ON public.v3_gorivo_istorija USING btree (created_at DESC);


--
-- Name: idx_v3_gorivo_istorija_vrsta_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_gorivo_istorija_vrsta_created_at ON public.v3_gorivo_istorija USING btree (vrsta, created_at DESC);


--
-- Name: idx_v3_gorivo_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_gorivo_updated_at ON public.v3_gorivo USING btree (updated_at);


--
-- Name: idx_v3_kapacitet_slots_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_kapacitet_slots_updated_at ON public.v3_kapacitet_slots USING btree (updated_at);


--
-- Name: idx_v3_operativna_nedelja_adresa_override_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_adresa_override_id ON public.v3_operativna_nedelja USING btree (adresa_override_id);


--
-- Name: idx_v3_operativna_nedelja_created_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_created_by ON public.v3_operativna_nedelja USING btree (created_by);


--
-- Name: idx_v3_operativna_nedelja_otkazano_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_otkazano_by ON public.v3_operativna_nedelja USING btree (otkazano_by);


--
-- Name: idx_v3_operativna_nedelja_pokupljen_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_pokupljen_by ON public.v3_operativna_nedelja USING btree (pokupljen_by);


--
-- Name: idx_v3_operativna_nedelja_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_updated_at ON public.v3_operativna_nedelja USING btree (updated_at);


--
-- Name: idx_v3_operativna_nedelja_updated_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_operativna_nedelja_updated_by ON public.v3_operativna_nedelja USING btree (updated_by);


--
-- Name: idx_v3_servis_istorija_vozilo_tip_datum; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_servis_istorija_vozilo_tip_datum ON public.v3_servis_istorija USING btree (vozilo_id, tip, datum);


--
-- Name: idx_v3_trenutna_dodela_slot_datum_grad_vreme; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_trenutna_dodela_slot_datum_grad_vreme ON public.v3_trenutna_dodela_slot USING btree (datum, grad, vreme);


--
-- Name: idx_v3_trenutna_dodela_slot_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_trenutna_dodela_slot_id ON public.v3_trenutna_dodela USING btree (slot_id);


--
-- Name: idx_v3_trenutna_dodela_slot_updated_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_trenutna_dodela_slot_updated_by ON public.v3_trenutna_dodela_slot USING btree (updated_by);


--
-- Name: idx_v3_trenutna_dodela_slot_vozac; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_trenutna_dodela_slot_vozac ON public.v3_trenutna_dodela_slot USING btree (vozac_v3_auth_id);


--
-- Name: idx_v3_trenutna_dodela_updated_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_trenutna_dodela_updated_by ON public.v3_trenutna_dodela USING btree (updated_by);


--
-- Name: idx_v3_vozac_location_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_vozac_location_updated_at ON public.v3_vozac_location USING btree (updated_at DESC);


--
-- Name: idx_v3_zahtevi_adresa_override_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_zahtevi_adresa_override_id ON public.v3_zahtevi USING btree (adresa_override_id);


--
-- Name: idx_v3_zahtevi_created_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_zahtevi_created_by ON public.v3_zahtevi USING btree (created_by);


--
-- Name: idx_v3_zahtevi_due_queue; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_zahtevi_due_queue ON public.v3_zahtevi USING btree (scheduled_at, created_at, id) WHERE ((status = 'obrada'::text) AND (scheduled_at IS NOT NULL));


--
-- Name: idx_v3_zahtevi_updated_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_zahtevi_updated_at ON public.v3_zahtevi USING btree (updated_at);


--
-- Name: idx_v3_zahtevi_updated_by; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_v3_zahtevi_updated_by ON public.v3_zahtevi USING btree (updated_by);


--
-- Name: ix_v3_finansije_naplatio_vozac_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ix_v3_finansije_naplatio_vozac_id ON public.v3_finansije USING btree (naplaceno_by);


--
-- Name: ix_v3_finansije_tip; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ix_v3_finansije_tip ON public.v3_finansije USING btree (tip);


--
-- Name: ix_v3_finansije_tip_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ix_v3_finansije_tip_created_at ON public.v3_finansije USING btree (tip, created_at DESC);


--
-- Name: ux_v3_finansije_naplata_master; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ux_v3_finansije_naplata_master ON public.v3_finansije USING btree (putnik_v3_auth_id, godina, mesec) WHERE ((tip = 'prihod'::text) AND (kategorija = 'operativna_naplata'::text));


--
-- Name: v3_auth_push_token_2_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX v3_auth_push_token_2_idx ON public.v3_auth USING btree (push_token_2) WHERE (push_token_2 IS NOT NULL);


--
-- Name: v3_auth_push_token_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX v3_auth_push_token_idx ON public.v3_auth USING btree (push_token) WHERE (push_token IS NOT NULL);


--
-- Name: v3_auth_telefon_normalized_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX v3_auth_telefon_normalized_unique ON public.v3_auth USING btree (public.v3_normalize_phone(telefon));


--
-- Name: v3_auth_telefon_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX v3_auth_telefon_unique ON public.v3_auth USING btree (telefon);


--
-- Name: v3_operativna_unique_active_putnik_slot_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX v3_operativna_unique_active_putnik_slot_idx ON public.v3_operativna_nedelja USING btree (created_by, datum, upper(COALESCE(grad, ''::text)), SUBSTRING(TRIM(BOTH FROM COALESCE((polazak_at)::text, ''::text)) FROM 1 FOR 5)) WHERE ((created_by IS NOT NULL) AND (TRIM(BOTH FROM COALESCE((polazak_at)::text, ''::text)) <> ''::text) AND (otkazano_at IS NULL));


--
-- Name: v3_trenutna_dodela_slot_vozilo_id_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX v3_trenutna_dodela_slot_vozilo_id_idx ON public.v3_trenutna_dodela_slot USING btree (vozilo_id) WHERE (vozilo_id IS NOT NULL);


--
-- Name: v3_vozila_vozac_id_uidx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX v3_vozila_vozac_id_uidx ON public.v3_vozila USING btree (vozac_id) WHERE (vozac_id IS NOT NULL);


--
-- Name: v3_adrese tr_v3_adrese_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_adrese_updated_at BEFORE UPDATE ON public.v3_adrese FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_app_settings tr_v3_app_settings_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_app_settings_updated_at BEFORE UPDATE ON public.v3_app_settings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_auth tr_v3_auth_last_seen_touch_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_auth_last_seen_touch_updated_at BEFORE UPDATE OF last_seen_at, last_seen_at_2 ON public.v3_auth FOR EACH ROW WHEN (((old.last_seen_at IS DISTINCT FROM new.last_seen_at) OR (old.last_seen_at_2 IS DISTINCT FROM new.last_seen_at_2))) EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_zahtevi tr_v3_ensure_polazak_at_on_odobreno; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_ensure_polazak_at_on_odobreno BEFORE INSERT OR UPDATE ON public.v3_zahtevi FOR EACH ROW EXECUTE FUNCTION public.ensure_polazak_at_on_odobreno();


--
-- Name: v3_finansije tr_v3_finansije_popuni_imena; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_finansije_popuni_imena BEFORE INSERT OR UPDATE OF putnik_v3_auth_id, naplaceno_by, ime, naplatio_ime ON public.v3_finansije FOR EACH ROW EXECUTE FUNCTION public.fn_v3_finansije_popuni_imena();


--
-- Name: v3_finansije tr_v3_finansije_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_finansije_updated_at BEFORE UPDATE ON public.v3_finansije FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_kapacitet_slots tr_v3_kapacitet_slots_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_kapacitet_slots_updated_at BEFORE UPDATE ON public.v3_kapacitet_slots FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_zahtevi tr_v3_notify_putnik_on_zahtev_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_notify_putnik_on_zahtev_update AFTER UPDATE ON public.v3_zahtevi FOR EACH ROW EXECUTE FUNCTION public.fn_v3_notify_putnik_on_zahtev_update();


--
-- Name: v3_operativna_nedelja tr_v3_operativna_lifecycle_timestamps; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_operativna_lifecycle_timestamps BEFORE INSERT OR UPDATE ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps();


--
-- Name: v3_operativna_nedelja tr_v3_operativna_nedelja_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_operativna_nedelja_updated_at BEFORE UPDATE ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_trenutna_dodela tr_v3_trenutna_dodela_normalize; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_trenutna_dodela_normalize BEFORE INSERT OR UPDATE ON public.v3_trenutna_dodela FOR EACH ROW EXECUTE FUNCTION public.fn_v3_trenutna_dodela_normalize();


--
-- Name: v3_trenutna_dodela_slot tr_v3_trenutna_dodela_slot_normalize; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_trenutna_dodela_slot_normalize BEFORE INSERT OR UPDATE ON public.v3_trenutna_dodela_slot FOR EACH ROW EXECUTE FUNCTION public.fn_v3_trenutna_dodela_slot_normalize();


--
-- Name: v3_trenutna_dodela_slot tr_v3_trenutna_dodela_slot_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_trenutna_dodela_slot_updated_at BEFORE UPDATE ON public.v3_trenutna_dodela_slot FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_trenutna_dodela tr_v3_trenutna_dodela_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_trenutna_dodela_updated_at BEFORE UPDATE ON public.v3_trenutna_dodela FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_vozila tr_v3_vozila_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_vozila_updated_at BEFORE UPDATE ON public.v3_vozila FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_zahtevi tr_v3_zahtevi_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_v3_zahtevi_updated_at BEFORE UPDATE ON public.v3_zahtevi FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_gorivo trg_gorivo_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_gorivo_updated_at BEFORE UPDATE ON public.v3_gorivo FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_racuni trg_racuni_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_racuni_updated_at BEFORE UPDATE ON public.v3_racuni FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_operativna_nedelja trg_sync_otkazane_voznje_to_finansije; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_otkazane_voznje_to_finansije AFTER INSERT OR UPDATE OF otkazano_at ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.v3_sync_otkazane_voznje_to_finansije();


--
-- Name: v3_operativna_nedelja trg_sync_realizovane_voznje_to_finansije; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_realizovane_voznje_to_finansije AFTER INSERT OR UPDATE OF pokupljen_at ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.v3_sync_realizovane_voznje_to_finansije();


--
-- Name: v3_gorivo trg_v3_gorivo_log_delta_history; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_v3_gorivo_log_delta_history AFTER UPDATE OF trenutno_stanje_litri, brojac_pistolj_litri, dug_iznos ON public.v3_gorivo FOR EACH ROW EXECUTE FUNCTION public.v3_gorivo_log_delta_history();


--
-- Name: v3_gorivo trg_v3_gorivo_set_trenutno_from_brojac; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_v3_gorivo_set_trenutno_from_brojac BEFORE INSERT OR UPDATE OF kapacitet_litri, brojac_pistolj_litri ON public.v3_gorivo FOR EACH ROW EXECUTE FUNCTION public.v3_gorivo_set_trenutno_from_brojac();


--
-- Name: v3_kapacitet_slots trg_v3_offer_freed_seats_on_kapacitet; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_v3_offer_freed_seats_on_kapacitet AFTER INSERT OR UPDATE OF max_mesta ON public.v3_kapacitet_slots FOR EACH ROW EXECUTE FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats();


--
-- Name: v3_operativna_nedelja trg_v3_offer_freed_seats_on_otkazano; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_v3_offer_freed_seats_on_otkazano AFTER UPDATE OF otkazano_at ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats();


--
-- Name: v3_operativna_nedelja trg_v3_operativna_sync_dodela; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_v3_operativna_sync_dodela AFTER INSERT OR UPDATE ON public.v3_operativna_nedelja FOR EACH ROW EXECUTE FUNCTION public.fn_v3_operativna_sync_dodela();


--
-- Name: v3_auth v3_auth_set_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER v3_auth_set_updated_at BEFORE UPDATE ON public.v3_auth FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: v3_zahtevi zahtev_scheduled_at_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER zahtev_scheduled_at_trigger BEFORE INSERT OR UPDATE ON public.v3_zahtevi FOR EACH ROW EXECUTE FUNCTION public.set_zahtev_scheduled_at();


--
-- Name: v3_zahtevi zahtev_to_operativna_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER zahtev_to_operativna_trigger AFTER INSERT OR UPDATE ON public.v3_zahtevi FOR EACH ROW EXECUTE FUNCTION public.transfer_to_operativna_nedelja();


--
-- Name: v3_trenutna_dodela trenutna_dodela_putnik_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT trenutna_dodela_putnik_auth_id_fkey FOREIGN KEY (putnik_v3_auth_id) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: v3_trenutna_dodela trenutna_dodela_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT trenutna_dodela_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_trenutna_dodela trenutna_dodela_vozac_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT trenutna_dodela_vozac_auth_id_fkey FOREIGN KEY (vozac_v3_auth_id) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: v3_auth v3_auth_adresa_bc_id_2_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_auth
    ADD CONSTRAINT v3_auth_adresa_bc_id_2_fkey FOREIGN KEY (adresa_secondary_bc_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_auth v3_auth_adresa_bc_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_auth
    ADD CONSTRAINT v3_auth_adresa_bc_id_fkey FOREIGN KEY (adresa_primary_bc_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_auth v3_auth_adresa_vs_id_2_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_auth
    ADD CONSTRAINT v3_auth_adresa_vs_id_2_fkey FOREIGN KEY (adresa_secondary_vs_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_auth v3_auth_adresa_vs_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_auth
    ADD CONSTRAINT v3_auth_adresa_vs_id_fkey FOREIGN KEY (adresa_primary_vs_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_device_events v3_device_events_v3_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_device_events
    ADD CONSTRAINT v3_device_events_v3_auth_id_fkey FOREIGN KEY (v3_auth_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_eta_results v3_eta_results_putnik_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT v3_eta_results_putnik_id_fkey FOREIGN KEY (putnik_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_eta_results v3_eta_results_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT v3_eta_results_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.v3_trenutna_dodela_slot(id) ON DELETE CASCADE;


--
-- Name: v3_eta_results v3_eta_results_termin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT v3_eta_results_termin_id_fkey FOREIGN KEY (termin_id) REFERENCES public.v3_operativna_nedelja(id) ON DELETE CASCADE;


--
-- Name: v3_eta_results v3_eta_results_vozac_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_eta_results
    ADD CONSTRAINT v3_eta_results_vozac_id_fkey FOREIGN KEY (vozac_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_finansije v3_finansije_naplatio_vozac_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_finansije
    ADD CONSTRAINT v3_finansije_naplatio_vozac_id_fkey FOREIGN KEY (naplaceno_by) REFERENCES public.v3_auth(id) ON DELETE SET NULL;


--
-- Name: v3_finansije v3_finansije_putnik_auth_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_finansije
    ADD CONSTRAINT v3_finansije_putnik_auth_id_fkey FOREIGN KEY (putnik_v3_auth_id) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_adresa_id_override_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_adresa_id_override_fkey FOREIGN KEY (adresa_override_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_otkazano_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_otkazano_by_fkey FOREIGN KEY (otkazano_by) REFERENCES public.v3_auth(id) ON DELETE SET NULL;


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_pokupljen_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_pokupljen_by_fkey FOREIGN KEY (pokupljen_by) REFERENCES public.v3_auth(id);


--
-- Name: v3_operativna_nedelja v3_operativna_nedelja_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_operativna_nedelja
    ADD CONSTRAINT v3_operativna_nedelja_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_servis_istorija v3_servis_istorija_vozilo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_servis_istorija
    ADD CONSTRAINT v3_servis_istorija_vozilo_id_fkey FOREIGN KEY (vozilo_id) REFERENCES public.v3_vozila(id) ON DELETE CASCADE;


--
-- Name: v3_trenutna_dodela v3_trenutna_dodela_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT v3_trenutna_dodela_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.v3_trenutna_dodela_slot(id) ON DELETE SET NULL;


--
-- Name: v3_trenutna_dodela_slot v3_trenutna_dodela_slot_updated_by_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela_slot
    ADD CONSTRAINT v3_trenutna_dodela_slot_updated_by_fk FOREIGN KEY (updated_by) REFERENCES public.v3_auth(id) ON DELETE SET NULL;


--
-- Name: v3_trenutna_dodela_slot v3_trenutna_dodela_slot_vozac_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela_slot
    ADD CONSTRAINT v3_trenutna_dodela_slot_vozac_fk FOREIGN KEY (vozac_v3_auth_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_trenutna_dodela_slot v3_trenutna_dodela_slot_vozilo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela_slot
    ADD CONSTRAINT v3_trenutna_dodela_slot_vozilo_id_fkey FOREIGN KEY (vozilo_id) REFERENCES public.v3_vozila(id) ON DELETE SET NULL;


--
-- Name: v3_trenutna_dodela v3_trenutna_dodela_termin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_trenutna_dodela
    ADD CONSTRAINT v3_trenutna_dodela_termin_id_fkey FOREIGN KEY (termin_id) REFERENCES public.v3_operativna_nedelja(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: v3_uplata_pazara v3_uplata_pazara_vozac_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_uplata_pazara
    ADD CONSTRAINT v3_uplata_pazara_vozac_id_fkey FOREIGN KEY (vozac_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_vozac_location v3_vozac_location_vozac_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_vozac_location
    ADD CONSTRAINT v3_vozac_location_vozac_id_fkey FOREIGN KEY (vozac_id) REFERENCES public.v3_auth(id) ON DELETE CASCADE;


--
-- Name: v3_vozila v3_vozila_vozac_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_vozila
    ADD CONSTRAINT v3_vozila_vozac_id_fkey FOREIGN KEY (vozac_id) REFERENCES public.v3_auth(id) ON DELETE SET NULL;


--
-- Name: v3_zahtevi v3_zahtevi_adresa_id_override_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_zahtevi
    ADD CONSTRAINT v3_zahtevi_adresa_id_override_fkey FOREIGN KEY (adresa_override_id) REFERENCES public.v3_adrese(id) ON DELETE SET NULL;


--
-- Name: v3_zahtevi v3_zahtevi_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_zahtevi
    ADD CONSTRAINT v3_zahtevi_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_zahtevi v3_zahtevi_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.v3_zahtevi
    ADD CONSTRAINT v3_zahtevi_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.v3_auth(id) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: v3_device_events Allow all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Allow all" ON public.v3_device_events TO authenticated, anon USING (true) WITH CHECK (true);


--
-- Name: v3_uplata_pazara Allow all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Allow all" ON public.v3_uplata_pazara TO authenticated, anon USING (true) WITH CHECK (true);


--
-- Name: v3_weather_alerts_sent Allow all; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Allow all" ON public.v3_weather_alerts_sent TO authenticated, anon, service_role USING (true) WITH CHECK (true);


--
-- Name: v3_vozac_location Allow all on v3_vozac_location; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Allow all on v3_vozac_location" ON public.v3_vozac_location TO authenticated, anon USING (true) WITH CHECK (true);


--
-- Name: v3_krediti Anonimni korisnici imaju pun pristup v3_krediti; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Anonimni korisnici imaju pun pristup v3_krediti" ON public.v3_krediti TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_gorivo_istorija Autentikovani korisnici imaju pun pristup v3_gorivo_istorija; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Autentikovani korisnici imaju pun pristup v3_gorivo_istorija" ON public.v3_gorivo_istorija TO authenticated USING (true) WITH CHECK (true);


--
-- Name: v3_adrese anon_all_v3_adrese; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_adrese ON public.v3_adrese TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_app_settings anon_all_v3_app_settings; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_app_settings ON public.v3_app_settings TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_auth anon_all_v3_auth; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_auth ON public.v3_auth TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_eta_results anon_all_v3_eta_results; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_eta_results ON public.v3_eta_results TO authenticated, anon USING (true) WITH CHECK (true);


--
-- Name: v3_finansije anon_all_v3_finansije; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_finansije ON public.v3_finansije TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_gorivo anon_all_v3_gorivo; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_gorivo ON public.v3_gorivo TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_gorivo_istorija anon_all_v3_gorivo_istorija; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_gorivo_istorija ON public.v3_gorivo_istorija TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_kapacitet_slots anon_all_v3_kapacitet_slots; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_kapacitet_slots ON public.v3_kapacitet_slots TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_operativna_nedelja anon_all_v3_operativna_nedelja; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_operativna_nedelja ON public.v3_operativna_nedelja TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_racuni anon_all_v3_racuni; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_racuni ON public.v3_racuni TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_servis_istorija anon_all_v3_servis_istorija; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_servis_istorija ON public.v3_servis_istorija TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_trenutna_dodela anon_all_v3_trenutna_dodela; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_trenutna_dodela ON public.v3_trenutna_dodela TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_trenutna_dodela_slot anon_all_v3_trenutna_dodela_slot; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_trenutna_dodela_slot ON public.v3_trenutna_dodela_slot TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_vozila anon_all_v3_vozila; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_vozila ON public.v3_vozila TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_zahtevi anon_all_v3_zahtevi; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY anon_all_v3_zahtevi ON public.v3_zahtevi TO anon USING (true) WITH CHECK (true);


--
-- Name: v3_servis_istorija authenticated_all_v3_servis_istorija; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY authenticated_all_v3_servis_istorija ON public.v3_servis_istorija TO authenticated USING (true) WITH CHECK (true);


--
-- Name: v3_adrese; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_adrese ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_app_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_app_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_auth; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_auth ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_device_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_device_events ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_eta_results; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_eta_results ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_finansije; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_finansije ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_gorivo; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_gorivo ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_gorivo_istorija; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_gorivo_istorija ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_kapacitet_slots; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_kapacitet_slots ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_krediti; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_krediti ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_operativna_nedelja; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_operativna_nedelja ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_racuni; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_racuni ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_servis_istorija; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_servis_istorija ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_trenutna_dodela; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_trenutna_dodela ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_trenutna_dodela_slot; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_trenutna_dodela_slot ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_uplata_pazara; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_uplata_pazara ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_vozac_location; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_vozac_location ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_vozila; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_vozila ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_weather_alerts_sent; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_weather_alerts_sent ENABLE ROW LEVEL SECURITY;

--
-- Name: v3_zahtevi; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.v3_zahtevi ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION analyze_schema(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.analyze_schema() TO anon;
GRANT ALL ON FUNCTION public.analyze_schema() TO authenticated;
GRANT ALL ON FUNCTION public.analyze_schema() TO service_role;


--
-- Name: FUNCTION ensure_polazak_at_on_odobreno(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.ensure_polazak_at_on_odobreno() TO anon;
GRANT ALL ON FUNCTION public.ensure_polazak_at_on_odobreno() TO authenticated;
GRANT ALL ON FUNCTION public.ensure_polazak_at_on_odobreno() TO service_role;


--
-- Name: FUNCTION expire_unanswered_alternativa_10m(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.expire_unanswered_alternativa_10m() TO anon;
GRANT ALL ON FUNCTION public.expire_unanswered_alternativa_10m() TO authenticated;
GRANT ALL ON FUNCTION public.expire_unanswered_alternativa_10m() TO service_role;


--
-- Name: FUNCTION fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text) TO anon;
GRANT ALL ON FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text) TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_alternativa_action(p_zahtev_id uuid, p_action text, p_device_token text, p_hardware_id text, p_installation_id text) TO service_role;


--
-- Name: FUNCTION fn_v3_expire_mesto_ponuda(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_expire_mesto_ponuda() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_expire_mesto_ponuda() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_expire_mesto_ponuda() TO service_role;


--
-- Name: FUNCTION fn_v3_finansije_popuni_imena(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_finansije_popuni_imena() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_finansije_popuni_imena() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_finansije_popuni_imena() TO service_role;


--
-- Name: FUNCTION fn_v3_notify_putnik_on_operativna_update(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_operativna_update() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_operativna_update() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_operativna_update() TO service_role;


--
-- Name: FUNCTION fn_v3_notify_putnik_on_zahtev_update(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_notify_putnik_on_zahtev_update() TO service_role;


--
-- Name: FUNCTION fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) TO anon;
GRANT ALL ON FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_offer_freed_seats(p_datum date, p_grad text, p_vreme text) TO service_role;


--
-- Name: FUNCTION fn_v3_on_kapacitet_increased_offer_seats(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_on_kapacitet_increased_offer_seats() TO service_role;


--
-- Name: FUNCTION fn_v3_on_operativna_otkazano_offer_seats(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_on_operativna_otkazano_offer_seats() TO service_role;


--
-- Name: FUNCTION fn_v3_operativna_set_lifecycle_timestamps(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_operativna_set_lifecycle_timestamps() TO service_role;


--
-- Name: FUNCTION fn_v3_operativna_sync_dodela(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_operativna_sync_dodela() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_operativna_sync_dodela() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_operativna_sync_dodela() TO service_role;


--
-- Name: FUNCTION fn_v3_trenutna_dodela_normalize(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_normalize() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_normalize() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_normalize() TO service_role;


--
-- Name: FUNCTION fn_v3_trenutna_dodela_slot_normalize(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_slot_normalize() TO anon;
GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_slot_normalize() TO authenticated;
GRANT ALL ON FUNCTION public.fn_v3_trenutna_dodela_slot_normalize() TO service_role;


--
-- Name: FUNCTION get_pending_zahtevi_status(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_pending_zahtevi_status() TO anon;
GRANT ALL ON FUNCTION public.get_pending_zahtevi_status() TO authenticated;
GRANT ALL ON FUNCTION public.get_pending_zahtevi_status() TO service_role;


--
-- Name: FUNCTION manual_process_zahtevi(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.manual_process_zahtevi() TO anon;
GRANT ALL ON FUNCTION public.manual_process_zahtevi() TO authenticated;
GRANT ALL ON FUNCTION public.manual_process_zahtevi() TO service_role;


--
-- Name: FUNCTION notify_push(tokens jsonb, title text, body text, data jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) TO service_role;
GRANT ALL ON FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.notify_push(tokens jsonb, title text, body text, data jsonb) TO anon;


--
-- Name: FUNCTION process_pending_zahtevi(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.process_pending_zahtevi() TO anon;
GRANT ALL ON FUNCTION public.process_pending_zahtevi() TO authenticated;
GRANT ALL ON FUNCTION public.process_pending_zahtevi() TO service_role;


--
-- Name: FUNCTION process_pending_zahtevi_slots(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.process_pending_zahtevi_slots() TO anon;
GRANT ALL ON FUNCTION public.process_pending_zahtevi_slots() TO authenticated;
GRANT ALL ON FUNCTION public.process_pending_zahtevi_slots() TO service_role;


--
-- Name: FUNCTION seed_kapacitet_slots_for_active_week(p_week_start date); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date) TO anon;
GRANT ALL ON FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date) TO authenticated;
GRANT ALL ON FUNCTION public.seed_kapacitet_slots_for_active_week(p_week_start date) TO service_role;


--
-- Name: FUNCTION set_current_timestamp(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_current_timestamp() TO anon;
GRANT ALL ON FUNCTION public.set_current_timestamp() TO authenticated;
GRANT ALL ON FUNCTION public.set_current_timestamp() TO service_role;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION set_zahtev_scheduled_at(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_zahtev_scheduled_at() TO anon;
GRANT ALL ON FUNCTION public.set_zahtev_scheduled_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_zahtev_scheduled_at() TO service_role;


--
-- Name: FUNCTION transfer_to_operativna_nedelja(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.transfer_to_operativna_nedelja() TO anon;
GRANT ALL ON FUNCTION public.transfer_to_operativna_nedelja() TO authenticated;
GRANT ALL ON FUNCTION public.transfer_to_operativna_nedelja() TO service_role;


--
-- Name: FUNCTION v3_auth_find_id_by_phone(p_telefon text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_auth_find_id_by_phone(p_telefon text) TO anon;
GRANT ALL ON FUNCTION public.v3_auth_find_id_by_phone(p_telefon text) TO authenticated;
GRANT ALL ON FUNCTION public.v3_auth_find_id_by_phone(p_telefon text) TO service_role;


--
-- Name: FUNCTION v3_auth_phone_exists(p_telefon text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.v3_auth_phone_exists(p_telefon text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v3_auth_phone_exists(p_telefon text) TO anon;


--
-- Name: FUNCTION v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) TO anon;
GRANT ALL ON FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) TO authenticated;
GRANT ALL ON FUNCTION public.v3_check_otkazane_voznje_consistency(p_godina integer, p_mesec integer) TO service_role;


--
-- Name: FUNCTION v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) TO anon;
GRANT ALL ON FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) TO authenticated;
GRANT ALL ON FUNCTION public.v3_find_termins_for_auto_prepare(p_datum date, p_start_time text, p_end_time text) TO service_role;


--
-- Name: FUNCTION v3_gorivo_dnevni_prosek(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek() TO anon;
GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek() TO authenticated;
GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek() TO service_role;


--
-- Name: FUNCTION v3_gorivo_dnevni_prosek_uplata(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek_uplata() TO anon;
GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek_uplata() TO authenticated;
GRANT ALL ON FUNCTION public.v3_gorivo_dnevni_prosek_uplata() TO service_role;


--
-- Name: FUNCTION v3_gorivo_log_delta_history(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_gorivo_log_delta_history() TO anon;
GRANT ALL ON FUNCTION public.v3_gorivo_log_delta_history() TO authenticated;
GRANT ALL ON FUNCTION public.v3_gorivo_log_delta_history() TO service_role;


--
-- Name: FUNCTION v3_gorivo_set_trenutno_from_brojac(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_gorivo_set_trenutno_from_brojac() TO anon;
GRANT ALL ON FUNCTION public.v3_gorivo_set_trenutno_from_brojac() TO authenticated;
GRANT ALL ON FUNCTION public.v3_gorivo_set_trenutno_from_brojac() TO service_role;


--
-- Name: FUNCTION v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone) TO anon;
GRANT ALL ON FUNCTION public.v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.v3_gorivo_sum_potrosnja(p_start timestamp with time zone, p_end timestamp with time zone) TO service_role;


--
-- Name: FUNCTION v3_maybe_cleanup_old_operativna_data(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_maybe_cleanup_old_operativna_data() TO anon;
GRANT ALL ON FUNCTION public.v3_maybe_cleanup_old_operativna_data() TO authenticated;
GRANT ALL ON FUNCTION public.v3_maybe_cleanup_old_operativna_data() TO service_role;


--
-- Name: FUNCTION v3_maybe_seed_kapacitet_slots(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_maybe_seed_kapacitet_slots() TO anon;
GRANT ALL ON FUNCTION public.v3_maybe_seed_kapacitet_slots() TO authenticated;
GRANT ALL ON FUNCTION public.v3_maybe_seed_kapacitet_slots() TO service_role;


--
-- Name: FUNCTION v3_maybe_update_active_week(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_maybe_update_active_week() TO anon;
GRANT ALL ON FUNCTION public.v3_maybe_update_active_week() TO authenticated;
GRANT ALL ON FUNCTION public.v3_maybe_update_active_week() TO service_role;


--
-- Name: FUNCTION v3_norm_hhmm(p_value text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_norm_hhmm(p_value text) TO anon;
GRANT ALL ON FUNCTION public.v3_norm_hhmm(p_value text) TO authenticated;
GRANT ALL ON FUNCTION public.v3_norm_hhmm(p_value text) TO service_role;


--
-- Name: FUNCTION v3_normalize_phone(p_telefon text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.v3_normalize_phone(p_telefon text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.v3_normalize_phone(p_telefon text) TO service_role;
GRANT ALL ON FUNCTION public.v3_normalize_phone(p_telefon text) TO anon;


--
-- Name: FUNCTION v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) TO anon;
GRANT ALL ON FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) TO authenticated;
GRANT ALL ON FUNCTION public.v3_notify_passengers_driver_started(p_vozac_id uuid, p_datum date, p_grad text, p_vreme time without time zone) TO service_role;


--
-- Name: FUNCTION v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text) TO anon;
GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text) TO authenticated;
GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text) TO service_role;


--
-- Name: FUNCTION v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text, p_body_zh text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text, p_body_zh text) TO anon;
GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text, p_body_zh text) TO authenticated;
GRANT ALL ON FUNCTION public.v3_notify_vozaci_weather_alert(p_grad text, p_condition_code text, p_severity text, p_title_sr text, p_body_sr text, p_title_en text, p_body_en text, p_title_ru text, p_body_ru text, p_title_de text, p_body_de text, p_title_zh text, p_body_zh text) TO service_role;


--
-- Name: FUNCTION v3_sync_otkazane_voznje_to_finansije(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_sync_otkazane_voznje_to_finansije() TO anon;
GRANT ALL ON FUNCTION public.v3_sync_otkazane_voznje_to_finansije() TO authenticated;
GRANT ALL ON FUNCTION public.v3_sync_otkazane_voznje_to_finansije() TO service_role;


--
-- Name: FUNCTION v3_sync_realizovane_voznje_to_finansije(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_sync_realizovane_voznje_to_finansije() TO anon;
GRANT ALL ON FUNCTION public.v3_sync_realizovane_voznje_to_finansije() TO authenticated;
GRANT ALL ON FUNCTION public.v3_sync_realizovane_voznje_to_finansije() TO service_role;


--
-- Name: FUNCTION v3_trigger_auto_prepare(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_trigger_auto_prepare() TO anon;
GRANT ALL ON FUNCTION public.v3_trigger_auto_prepare() TO authenticated;
GRANT ALL ON FUNCTION public.v3_trigger_auto_prepare() TO service_role;


--
-- Name: FUNCTION v3_trigger_weather_alert(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.v3_trigger_weather_alert() TO anon;
GRANT ALL ON FUNCTION public.v3_trigger_weather_alert() TO authenticated;
GRANT ALL ON FUNCTION public.v3_trigger_weather_alert() TO service_role;


--
-- Name: SEQUENCE v2_racuni_arhiva_broj_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.v2_racuni_arhiva_broj_seq TO anon;
GRANT ALL ON SEQUENCE public.v2_racuni_arhiva_broj_seq TO authenticated;
GRANT ALL ON SEQUENCE public.v2_racuni_arhiva_broj_seq TO service_role;


--
-- Name: TABLE v3_adrese; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_adrese TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_adrese TO authenticated;
GRANT ALL ON TABLE public.v3_adrese TO service_role;


--
-- Name: TABLE v3_app_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_app_settings TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_app_settings TO authenticated;
GRANT ALL ON TABLE public.v3_app_settings TO service_role;


--
-- Name: TABLE v3_auth; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_auth TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_auth TO authenticated;
GRANT ALL ON TABLE public.v3_auth TO service_role;


--
-- Name: TABLE v3_cron_state; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_cron_state TO anon;
GRANT ALL ON TABLE public.v3_cron_state TO authenticated;
GRANT ALL ON TABLE public.v3_cron_state TO service_role;


--
-- Name: TABLE v3_device_events; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_device_events TO anon;
GRANT ALL ON TABLE public.v3_device_events TO authenticated;
GRANT ALL ON TABLE public.v3_device_events TO service_role;


--
-- Name: TABLE v3_eta_results; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_eta_results TO anon;
GRANT ALL ON TABLE public.v3_eta_results TO authenticated;
GRANT ALL ON TABLE public.v3_eta_results TO service_role;


--
-- Name: TABLE v3_finansije; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_finansije TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_finansije TO authenticated;
GRANT ALL ON TABLE public.v3_finansije TO service_role;


--
-- Name: TABLE v3_gorivo; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_gorivo TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_gorivo TO authenticated;
GRANT ALL ON TABLE public.v3_gorivo TO service_role;


--
-- Name: TABLE v3_gorivo_istorija; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_gorivo_istorija TO anon;
GRANT ALL ON TABLE public.v3_gorivo_istorija TO authenticated;
GRANT ALL ON TABLE public.v3_gorivo_istorija TO service_role;


--
-- Name: TABLE v3_kapacitet_slots; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_kapacitet_slots TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_kapacitet_slots TO authenticated;
GRANT ALL ON TABLE public.v3_kapacitet_slots TO service_role;


--
-- Name: TABLE v3_krediti; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_krediti TO anon;
GRANT ALL ON TABLE public.v3_krediti TO authenticated;
GRANT ALL ON TABLE public.v3_krediti TO service_role;


--
-- Name: TABLE v3_operativna_nedelja; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_operativna_nedelja TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_operativna_nedelja TO authenticated;
GRANT ALL ON TABLE public.v3_operativna_nedelja TO service_role;


--
-- Name: TABLE v3_racuni; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_racuni TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_racuni TO authenticated;
GRANT ALL ON TABLE public.v3_racuni TO service_role;


--
-- Name: TABLE v3_servis_istorija; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_servis_istorija TO anon;
GRANT ALL ON TABLE public.v3_servis_istorija TO authenticated;
GRANT ALL ON TABLE public.v3_servis_istorija TO service_role;


--
-- Name: TABLE v3_trenutna_dodela; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_trenutna_dodela TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_trenutna_dodela TO authenticated;
GRANT ALL ON TABLE public.v3_trenutna_dodela TO service_role;


--
-- Name: TABLE v3_trenutna_dodela_slot; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_trenutna_dodela_slot TO anon;
GRANT ALL ON TABLE public.v3_trenutna_dodela_slot TO authenticated;
GRANT ALL ON TABLE public.v3_trenutna_dodela_slot TO service_role;


--
-- Name: TABLE v3_uplata_pazara; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_uplata_pazara TO anon;
GRANT ALL ON TABLE public.v3_uplata_pazara TO authenticated;
GRANT ALL ON TABLE public.v3_uplata_pazara TO service_role;


--
-- Name: TABLE v3_vozac_location; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_vozac_location TO anon;
GRANT ALL ON TABLE public.v3_vozac_location TO authenticated;
GRANT ALL ON TABLE public.v3_vozac_location TO service_role;


--
-- Name: TABLE v3_vozila; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_vozila TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_vozila TO authenticated;
GRANT ALL ON TABLE public.v3_vozila TO service_role;


--
-- Name: TABLE v3_weather_alerts_sent; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_weather_alerts_sent TO anon;
GRANT ALL ON TABLE public.v3_weather_alerts_sent TO authenticated;
GRANT ALL ON TABLE public.v3_weather_alerts_sent TO service_role;


--
-- Name: TABLE v3_zahtevi; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v3_zahtevi TO anon;
GRANT REFERENCES,TRIGGER,TRUNCATE ON TABLE public.v3_zahtevi TO authenticated;
GRANT ALL ON TABLE public.v3_zahtevi TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- PostgreSQL database dump complete
--


-- ============================================================================
-- REALTIME PUBLIKACIJA — sve v3_* tabele moraju biti u supabase_realtime
-- (inace postgres_changes tiho ne salje evente za njih)
-- ============================================================================
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;

  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname like 'v3\_%' escape '\'
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ============================================================================
-- PG_CRON JOBOVI — pg_dump ne hvata cron.job podatke, rekonstruisano ručno.
-- Idempotentno: preskače jobove koji vec postoje.
-- ============================================================================
do $$
begin
  if to_regnamespace('cron') is null then
    raise warning 'pg_cron nije dostupan u ovoj bazi — preskacem cron jobove.';
    return;
  end if;

  if not exists (select 1 from cron.job where jobname = 'cleanup_old_operativna_data') then
    perform cron.schedule('cleanup_old_operativna_data', '*/5 * * * *', $c$SELECT public.v3_maybe_cleanup_old_operativna_data();$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'seed_kapacitet_slots_active_week') then
    perform cron.schedule('seed_kapacitet_slots_active_week', '*/5 * * * *', $c$SELECT public.v3_maybe_seed_kapacitet_slots();$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'update_active_week') then
    perform cron.schedule('update_active_week', '*/5 * * * *', $c$SELECT public.v3_maybe_update_active_week();$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'v3-auto-prepare-termins') then
    perform cron.schedule('v3-auto-prepare-termins', '* * * * *', $c$SELECT public.v3_trigger_auto_prepare();$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'v3-expire-mesto-ponuda') then
    perform cron.schedule('v3-expire-mesto-ponuda', '* * * * *', $c$SELECT public.fn_v3_expire_mesto_ponuda();$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'v3-weather-alert') then
    perform cron.schedule('v3-weather-alert', '*/30 * * * *', $c$SELECT public.v3_trigger_weather_alert();$c$);
  end if;
  if not exists (select 1 from cron.job where command = 'select public.process_pending_zahtevi();') then
    perform cron.schedule('* * * * *', $c$select public.process_pending_zahtevi();$c$);
  end if;
  if not exists (select 1 from cron.job where command = 'select public.expire_unanswered_alternativa_10m();') then
    perform cron.schedule('* * * * *', $c$select public.expire_unanswered_alternativa_10m();$c$);
  end if;
end $$;
