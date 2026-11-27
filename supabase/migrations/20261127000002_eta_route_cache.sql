-- ETA route cache: OSRM /trip vise ne ide na svaki 5s tick.
--
-- `travel_seconds` = kumulativni OSRM travel do putnika BEZ standstill
-- kazne, zamrznut u trenutku `route_at` (poslednji uspesni OSRM compute).
-- `eta_seconds` ostaje izvedena vrednost = preostali travel + standstill,
-- upisuje se na SVAKI tick (computed_at = now) — putnicki countdown
-- (eta_seconds - (now - computed_at)) radi identicno kao ranije.
--
-- Edge (v3-compute-eta) preskace OSRM kad: set putnika isti + route_at
-- mlaci od 30s + sve redove imaju travel_seconds/route_at. Inače full
-- OSRM path (isti kao do sada) i upisuje obe kolone.
-- Stari redovi (NULL travel_seconds) automatski dobiju OSRM na sledecem
-- tick-u; stari edge buildovi ih ne diraju (kolone nullable, ne diraju
-- postojece upsert-ove).

ALTER TABLE public.v3_eta_results
  ADD COLUMN IF NOT EXISTS travel_seconds integer,
  ADD COLUMN IF NOT EXISTS route_at timestamp with time zone;

COMMENT ON COLUMN public.v3_eta_results.travel_seconds IS
  'Kumulativni OSRM travel do putnika (s) bez standstill kazne, u trenutku route_at';
COMMENT ON COLUMN public.v3_eta_results.route_at IS
  'Vreme poslednjeg uspesnog OSRM /trip compute-a za ovaj red';
