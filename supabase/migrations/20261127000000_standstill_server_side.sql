-- Standstill (ETA penalty) se presao na server-side: v3-compute-eta ga
-- akumulira u ovim kolonama na v3_vozac_location umesto da klijent
-- transportuje brojac kroz FG<->BG isolate handoff (SharedPreferences
-- session payload). Kolone:
--   standstill_seconds  — akumulirana kazna (cap 20min, edge ga clamp-uje)
--   standstill_tick_at  — vreme poslednjeg standstill tick-a (elapsed delta)
--   standstill_prev_lat/lng — poslednja pozicija (distance fallback kad
--                         speed nije validan, isti prag 15m kao ranije)
ALTER TABLE public.v3_vozac_location
  ADD COLUMN IF NOT EXISTS standstill_seconds integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS standstill_tick_at timestamptz,
  ADD COLUMN IF NOT EXISTS standstill_prev_lat double precision,
  ADD COLUMN IF NOT EXISTS standstill_prev_lng double precision;
