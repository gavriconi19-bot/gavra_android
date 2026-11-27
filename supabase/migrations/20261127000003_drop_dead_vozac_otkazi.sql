-- Uklanja mrtav RPC fn_v3_vozac_otkazi (kreiran u 20261122000002_mutation_rpcs).
--
-- Funkcija nigde nije pozvana — ni u app-u (lib/) ni u edge funkcijama.
-- Tok "vozac otkazuje putnika" ide kroz fn_v3_putnik_otkazi koji radi
-- ceo kontekst (zahtev -> 'otkazano' + operativni redovi + dodele).
-- Zadrzavanje mrtvog SECURITY DEFINER RPC-ja sa anon EXECUTE je cista
-- povrsina za zloupotrebu bez koristi.

DROP FUNCTION IF EXISTS public.fn_v3_vozac_otkazi(uuid, uuid);
