-- Uklanja ograničenje od 16h za dnevne putnike.
--
-- Do sada je važilo: zahtev podnet pre 16:00 smeo je biti samo za tekući dan,
-- posle 16:00 samo za sledeći dan. Pravilo se sprovodilo na dva mesta:
--   1) set_zahtev_scheduled_at (BEFORE INSERT/UPDATE trigger) — bacao exception
--      pa je sam upis zahteva padao.
--   2) process_pending_zahtevi_slots (cron) — zahteve koji su ipak prošli
--      automatski prebacivao u 'odbijeno'.
--
-- Dnevni putnici sada zakazuju kao i ostali tipovi (jedina ograničenja koja
-- ostaju: neradni dani, kapacitet slotova i 10-min čekanje pre obrade).

CREATE OR REPLACE FUNCTION public.set_zahtev_scheduled_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.process_pending_zahtevi_slots()
 RETURNS TABLE(processed integer, approved integer, alternative integer, message text)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
                -- Posiljke ne zauzimaju mesto (kao u offer_freed_seats/edge).
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

            -- Bez ijedne dostupne alternative ne nudimo prazan izbor —
            -- zahtev ide direktno u 'odbijeno' (stize iskren "Termin popunjen"
            -- push) i ostaje u redu za mesto_oslobodjeno ponude.
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
$function$;
