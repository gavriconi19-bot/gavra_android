-- ============================================================
-- updated_at triggeri za v3_* tabele koje ih nemaju, a realtime
-- delta resync / watermark logika zavisi od updated_at:
--   v3_krediti, v3_uplata_pazara, v3_vozac_location
-- (v3_eta_results namerno preskocen — delta ide po computed_at)
-- Bez triggera: izmena reda bez rucno setovanog updated_at ostaje
-- nevidljiva za delta resync dok se app ne restartuje.
-- ============================================================

drop trigger if exists tr_v3_krediti_updated_at on public.v3_krediti;
create trigger tr_v3_krediti_updated_at
  before update on public.v3_krediti
  for each row execute function public.set_updated_at();

drop trigger if exists tr_v3_uplata_pazara_updated_at on public.v3_uplata_pazara;
create trigger tr_v3_uplata_pazara_updated_at
  before update on public.v3_uplata_pazara
  for each row execute function public.set_updated_at();

drop trigger if exists tr_v3_vozac_location_updated_at on public.v3_vozac_location;
create trigger tr_v3_vozac_location_updated_at
  before update on public.v3_vozac_location
  for each row execute function public.set_updated_at();
