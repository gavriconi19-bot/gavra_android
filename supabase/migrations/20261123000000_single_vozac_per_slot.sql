-- ════════════════════════════════════════════════════════════════════
-- 20261123000000_single_vozac_per_slot.sql
--
-- Uklanja multi-driver ("deljeni slot") logiku: jedan fizicki slot
-- (datum,grad,vreme) ima tacno jednog vozaca za SVE putnike. Ranije je
-- admin mogao individualno dodeliti putnika drugom vozacu na istom slotu
-- (v3_trenutna_dodela sa vozac != slot.vozac) — split slot.
--
-- 1) fn_v3_trenutna_dodela_normalize (BEFORE INSERT/UPDATE trigger, vec
--    zakacen na tabelu) sada enforce-uje invariant: svaka dodela koja se
--    veze za slot dobija vozac_v3_auth_id = vlasnik slota. slot_id se
--    resolve-uje i kad je NULL (preko operativna termina -> fizicki
--    kljuc slota), pa ni STARE app verzije koje pisu override bez
--    slot_id ne mogu da naprave split — trigger im tiho prepise vozac.
--    Ovo je BC putanja dok svi uredjaji ne predju na novu verziju.
-- 2) fn_v3_operativna_sync_dodela ON CONFLICT vise ne cuva override
--    vozac — sync uvek upisuje vlasnika slota.
-- 3) Jednokratni data fix: sve postojece dodele se svode na vlasnika
--    slota (+ backfill slot_id tamo gde nedostaje).
-- ════════════════════════════════════════════════════════════════════

-- 1) Normalize trigger: enforce slot-owner vozac + backfill slot_id.
CREATE OR REPLACE FUNCTION public.fn_v3_trenutna_dodela_normalize() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_slot_id uuid;
  v_slot_vozac uuid;
begin
  -- Resolve fizicki slot: direktno po slot_id, ili preko operativna
  -- termina kad slot_id nije upisan (stare verzije / rucni upisi).
  if new.slot_id is not null then
    select s.id, s.vozac_v3_auth_id
      into v_slot_id, v_slot_vozac
      from public.v3_trenutna_dodela_slot s
     where s.id = new.slot_id;
  else
    select s.id, s.vozac_v3_auth_id
      into v_slot_id, v_slot_vozac
      from public.v3_operativna_nedelja o
      join public.v3_trenutna_dodela_slot s
        on s.datum = o.datum
       and s.grad = o.grad
       and s.vreme = o.polazak_at
     where o.id = new.termin_id;
  end if;

  -- Slot uvek ima vlasnika (vozac_v3_auth_id NOT NULL); ako slot ne
  -- postoji, vozac polje ostaje kako je upisano (nema cega da se drzi).
  if v_slot_vozac is not null then
    new.slot_id := v_slot_id;
    new.vozac_v3_auth_id := v_slot_vozac;
  end if;

  return new;
end;
$$;

-- 2) Operativna sync trigger: ON CONFLICT ne cuva vise override vozac.
CREATE OR REPLACE FUNCTION public.fn_v3_operativna_sync_dodela() RETURNS trigger
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
        vozac_v3_auth_id = excluded.vozac_v3_auth_id,
        updated_by = excluded.updated_by;

  return new;
end;
$$;

-- 3) Jednokratni data fix: sve dodele se svode na vlasnika svog fizickog
--    slota (resolve-ovano preko termina — pokriva i slot_id IS NULL).
UPDATE public.v3_trenutna_dodela d
   SET slot_id = s.id,
       vozac_v3_auth_id = s.vozac_v3_auth_id
  FROM public.v3_operativna_nedelja o
  JOIN public.v3_trenutna_dodela_slot s
    ON s.datum = o.datum
   AND s.grad = o.grad
   AND s.vreme = o.polazak_at
 WHERE o.id = d.termin_id
   AND (d.slot_id IS DISTINCT FROM s.id
        OR d.vozac_v3_auth_id IS DISTINCT FROM s.vozac_v3_auth_id);

COMMENT ON COLUMN public.v3_trenutna_dodela.driver_started_notified_at IS 'Kada je ovom putniku poslat push da je vozac krenuo. Idempotencija po dodeli (jedan vozac po slotu).';

NOTIFY pgrst, 'reload schema';
