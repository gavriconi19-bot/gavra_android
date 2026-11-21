-- =============================================================================
-- 20261121000000_fix_alternativa_logic.sql
--
-- Ispravke logike za "alternativa" / "mesto_oslobodjeno" tok:
--
--  1) neradni_dani: scope ("all"|"bc"|"vs") se sada postuje u serverskim
--     funkcijama; prethodno je VS neradni dan blokirao i BC zahteve.
--     Takodje popravljen mrtav check u process_pending_zahtevi() i
--     get_pending_zahtevi_status() koji je citao elemente kao stringove
--     (neradni_dani su objekti {"date","scope","reason"}).
--  2) process_pending_zahtevi_slots vise ne nudi/odobrava termine koji su u
--     proslosti (po Europe/Belgrade), niti alternative u proslosti.
--  3) process_pending_zahtevi_slots zakljucava kapacitet slot (FOR UPDATE) pre
--     brojanja zauzetosti — isti lock kao fn_v3_alternativa_action, sto
--     sprecava approve/accept overbook race na poslednjem mestu.
--  4) Zahtev ciji trazeni slot ne postoji u rasporedu (off-grid), a datum je
--     vec zasejan, dobija alternative/odbijeno umesto da stoji u 'obrada'
--     zauvek. Za datum koji jos nije zasejan (buduca nedelja) i dalje ceka.
--  5) fn_v3_alternativa_action sada inline proverava 10-min expiry i za
--     obicnu 'alternativa' ponudu (ranije samo za mesto ponude; expiry je
--     zavisio iskljucivo od cron-a) i odbija accept za termin u proslosti.
--  6) manual_process_zahtevi sada stvarno forsirа obradu (zaobilazi
--     scheduled_at +10min gate) preko novog parametra p_ignore_schedule.
--  7) transfer_to_operativna_nedelja: odobreno grana vise ne pomera SVE
--     aktivne operativne redove na ciljni termin (pri >1 aktivnom redu je
--     udarala parcijalni unique indeks (created_by, datum, grad, polazak5)
--     i obarala ceo accept). Sada pomera jedan kanonski red, a eventualne
--     duplikate na drugim terminima ponistava.
--  8) Restriktivniji grant-ovi: interne funkcije vise nisu dostupne
--     anon/authenticated (pozivaju ih iskljucivo pg_cron i edge/service_role).
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1) process_pending_zahtevi_slots — potpis sa p_ignore_schedule
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.process_pending_zahtevi_slots();
DROP FUNCTION IF EXISTS public.process_pending_zahtevi_slots(boolean);

CREATE FUNCTION public.process_pending_zahtevi_slots(p_ignore_schedule boolean DEFAULT false)
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
                -- Alternative samo iz slotova koji jos nisu prosli (istog dana);
                -- za buduce datume svi slotovi vaze.
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
                  and (used_mesta + 1) <= max_mesta
                  and (zahtev_record.datum::date > v_today_bg
                       or public.v3_norm_hhmm(vreme::text) > v_now_hhmm);

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
-- 2) process_pending_zahtevi — ispravan neradni_dani check (objekti + scope)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_pending_zahtevi()
RETURNS TABLE(processed_count integer, approved_count integer, alternative_count integer, log_message text)
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
          cross join lateral jsonb_array_elements(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_obj)
          where d.day_obj->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
            and (d.day_obj->>'date')::date = z.datum::date
            and (
              lower(btrim(coalesce(d.day_obj->>'scope', 'all'))) = 'all'
              or upper(btrim(coalesce(d.day_obj->>'scope', ''))) = upper(btrim(z.grad))
            )
      );

    if pending_obrada = 0 then
        return query select 0, 0, 0, 'Nema pending obrada zahteva (ili su na neradni dan).';
        return;
    end if;

    return query select * from public.process_pending_zahtevi_slots();
end;
$_$;

ALTER FUNCTION public.process_pending_zahtevi() OWNER TO postgres;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3) get_pending_zahtevi_status — ispravan neradni_dani check (objekti + scope)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_pending_zahtevi_status()
RETURNS TABLE(zahtev_id uuid, putnik_ime text, tip_putnika text, datum date, grad text, zeljeno_vreme time without time zone, created_at timestamp with time zone, scheduled_at timestamp with time zone, remaining_minutes integer)
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
        cross join lateral jsonb_array_elements(coalesce(s.neradni_dani::jsonb, '[]'::jsonb)) d(day_obj)
        where d.day_obj->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
          and (d.day_obj->>'date')::date = z.datum::date
          and (
            lower(btrim(coalesce(d.day_obj->>'scope', 'all'))) = 'all'
            or upper(btrim(coalesce(d.day_obj->>'scope', ''))) = upper(btrim(z.grad))
          )
    )
  order by z.scheduled_at asc;
end;
$_$;

ALTER FUNCTION public.get_pending_zahtevi_status() OWNER TO postgres;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4) manual_process_zahtevi — forsirа obradu bez scheduled_at +10min gate-a
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.manual_process_zahtevi()
RETURNS TABLE(processed_count integer, approved_count integer, alternative_count integer, log_message text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    RETURN QUERY SELECT * FROM public.process_pending_zahtevi_slots(true);
END;
$$;

ALTER FUNCTION public.manual_process_zahtevi() OWNER TO postgres;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5) fn_v3_alternativa_action — inline 10-min expiry za 'alternativa' +
--    zabrana accept-a za termin u proslosti
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
      SET mesto_ponuda = false, mesto_ponuda_at = null, updated_at = now()
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 6) transfer_to_operativna_nedelja — odobreno grana otporan na vise
--    aktivnih operativnih redova (ranije unique-violation pri >1 redu)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.transfer_to_operativna_nedelja() RETURNS trigger
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
        -- Kanonski red: preferiraj onaj koji je vec na ciljnom terminu,
        -- inace najskorije azurirani. Pomera se tacno jedan red — ranije je
        -- UPDATE dirao SVE aktivne redove i pri >1 redu (anomalija) udarao
        -- parcijalni unique indeks (created_by, datum, grad, polazak5).
        UPDATE public.v3_operativna_nedelja o
        SET polazak_at = target_time,
            koristi_sekundarnu = COALESCE(NEW.koristi_sekundarnu, false),
            adresa_override_id = NEW.adresa_override_id,
            otkazano_at = NULL,
            otkazano_by = NULL,
            updated_at = now(),
            updated_by = NEW.updated_by
        WHERE o.id = (
            SELECT o2.id
            FROM public.v3_operativna_nedelja o2
            WHERE o2.created_by IS NOT DISTINCT FROM NEW.created_by
              AND o2.datum = NEW.datum
              AND o2.grad = NEW.grad
              AND o2.otkazano_at IS NULL
            ORDER BY (o2.polazak_at IS NOT DISTINCT FROM target_time) DESC,
                     o2.updated_at DESC NULLS LAST,
                     o2.id
            LIMIT 1
        );

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

        -- Eventualni preostali aktivni duplikati na drugim terminima istog
        -- dana se ponistavaju (oslobodjeno mesto kaskadira ponudu dalje).
        UPDATE public.v3_operativna_nedelja o
        SET otkazano_at = now(),
            otkazano_by = COALESCE(NEW.updated_by, NEW.created_by),
            updated_at = now(),
            updated_by = COALESCE(NEW.updated_by, NEW.created_by)
        WHERE o.created_by IS NOT DISTINCT FROM NEW.created_by
          AND o.datum = NEW.datum
          AND o.grad = NEW.grad
          AND o.otkazano_at IS NULL
          AND o.polazak_at IS DISTINCT FROM target_time;

    ELSIF NEW.status IN ('alternativa','odbijeno','otkazano')
          AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        UPDATE public.v3_operativna_nedelja o
        SET otkazano_at = now(),
            otkazano_by = NEW.updated_by,
            updated_at = now(),
            updated_by = NEW.updated_by
        WHERE o.created_by IS NOT DISTINCT FROM NEW.created_by
          AND o.datum = NEW.datum
          AND o.grad = NEW.grad
          AND o.otkazano_at IS NULL;
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.transfer_to_operativna_nedelja() OWNER TO postgres;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7) Restriktivniji grant-ovi — interne funkcije nisu za klijentske pozive
-- ─────────────────────────────────────────────────────────────────────────────

REVOKE ALL ON FUNCTION public.expire_unanswered_alternativa_10m() FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_expire_mesto_ponuda() FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_offer_freed_seats(date, text, text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_v3_alternativa_action(uuid, text, text, text, text) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.process_pending_zahtevi() FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.manual_process_zahtevi() FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.get_pending_zahtevi_status() FROM anon, authenticated;
