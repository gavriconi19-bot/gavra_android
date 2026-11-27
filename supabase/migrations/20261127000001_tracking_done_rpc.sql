-- fn_v3_tracking_done: "svi putnici gotovi?" provera kao JEDAN RPC umesto
-- 3 sekvencijalna REST upita sa klijenta (slot -> dodela -> operativna).
-- Ista semantika kao v3AllPassengersCompleted / _v3TerminHasActivePassengers:
--  - nema fizickog slota na (datum,grad,vreme)        -> false (ne dokazuje kraj)
--  - dodela mi je prazna:
--      slot nije moj                                  -> true  (tuđi slot)
--      slot moj + termin nema aktivnih putnika        -> true
--      slot moj + ima aktivnih (auto-prepare kasni)   -> false
--  - dodeljeni termin-i: SVI moraju biti pokupljeni ili otkazani;
--    prazna operativna tabela -> false.
-- Sve greske -> false (fail-safe: ne sme "dokazati" kraj).
-- GRANT anon+authenticated — app zove RPC na resume / iOS BG fetch.
CREATE OR REPLACE FUNCTION public.fn_v3_tracking_done(
  p_datum date,
  p_grad text,
  p_vreme text,
  p_vozac_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vreme text;
  v_grad text;
  v_slot_ids uuid[];
  v_slot_mine boolean;
  v_termin_ids uuid[];
  v_termin_count integer;
BEGIN
  v_grad := upper(btrim(coalesce(p_grad, '')));
  v_vreme := to_char(p_vreme::time, 'HH24:MI');

  SELECT array_agg(s.id), bool_or(s.vozac_v3_auth_id = p_vozac_id)
    INTO v_slot_ids, v_slot_mine
    FROM v3_trenutna_dodela_slot s
   WHERE s.datum = p_datum
     AND s.grad = v_grad
     AND to_char(s.vreme, 'HH24:MI') = v_vreme;

  IF v_slot_ids IS NULL THEN
    RETURN false;
  END IF;

  SELECT array_agg(DISTINCT d.termin_id) INTO v_termin_ids
    FROM v3_trenutna_dodela d
   WHERE d.slot_id = ANY(v_slot_ids)
     AND d.vozac_v3_auth_id = p_vozac_id;

  IF v_termin_ids IS NULL THEN
    IF NOT coalesce(v_slot_mine, false) THEN
      RETURN true;
    END IF;
    RETURN NOT EXISTS (
      SELECT 1
        FROM v3_operativna_nedelja o
       WHERE o.grad = v_grad
         AND o.datum = p_datum
         AND to_char(o.polazak_at, 'HH24:MI') = v_vreme
         AND o.pokupljen_at IS NULL
         AND o.otkazano_at IS NULL
    );
  END IF;

  SELECT count(*) INTO v_termin_count
    FROM v3_operativna_nedelja o
   WHERE o.id = ANY(v_termin_ids);
  IF v_termin_count = 0 THEN
    RETURN false;
  END IF;

  RETURN NOT EXISTS (
    SELECT 1
      FROM v3_operativna_nedelja o
     WHERE o.id = ANY(v_termin_ids)
       AND o.pokupljen_at IS NULL
       AND o.otkazano_at IS NULL
  );
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_v3_tracking_done(date, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_v3_tracking_done(date, text, text, uuid) TO anon, authenticated;
