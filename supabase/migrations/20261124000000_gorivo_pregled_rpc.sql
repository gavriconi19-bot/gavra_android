-- 2026-11-24 — fn_v3_gorivo_pregled: svi agregati "potrosnja po periodima"
-- u JEDNOM round-trip-u.
--
-- Gorivo ekran (kartica "Potrošnja goriva po periodima") je za svaki refresh
-- zvao 6 RPC-ova kroz Tailscale Funnel: 4× v3_gorivo_sum_potrosnja
-- (danas/nedelja/mesec/godina) + v3_gorivo_dnevni_prosek +
-- v3_gorivo_dnevni_prosek_uplata — isti problem kao pre mutacionog RPC sloja
-- (Funnel RTT ~250-500ms, TLS handshake po konekciji). Baza je tu trivijalna
-- (v3_gorivo_istorija je mala tabela sa idx na (vrsta, created_at)) pa je
-- ceo trošak bio mreža.
--
-- Granice perioda dolaze kao parametri iz app-a (V3BelgradeTime/V3DanHelper
-- vec racunaju DST-safe Belgrade ponoci i operativnu nedelju pon-pet) da
-- SQL ne duplira tu logiku. Proseci se povlace iz postojecih funkcija
-- v3_gorivo_dnevni_prosek / v3_gorivo_dnevni_prosek_uplata — ista semantika.

CREATE OR REPLACE FUNCTION public.fn_v3_gorivo_pregled(
  p_danas_start timestamptz, p_danas_end timestamptz,
  p_nedelja_start timestamptz, p_nedelja_end timestamptz,
  p_mesec_start timestamptz, p_mesec_end timestamptz,
  p_godina_start timestamptz, p_godina_end timestamptz
)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $func$
  WITH pot AS (
    SELECT created_at, litri
    FROM public.v3_gorivo_istorija
    WHERE vrsta = 'potrosnja'
      AND created_at >= least(p_danas_start, p_nedelja_start, p_mesec_start, p_godina_start)
      AND created_at < greatest(p_danas_end, p_nedelja_end, p_mesec_end, p_godina_end)
      AND coalesce(source, '') <> 'inicijalni_import'
  ),
  sums AS (
    SELECT
      coalesce(sum(litri) FILTER (WHERE created_at >= p_danas_start   AND created_at < p_danas_end),   0) AS danas_litri,
      coalesce(sum(litri) FILTER (WHERE created_at >= p_nedelja_start AND created_at < p_nedelja_end), 0) AS nedelja_litri,
      coalesce(sum(litri) FILTER (WHERE created_at >= p_mesec_start   AND created_at < p_mesec_end),   0) AS mesec_litri,
      coalesce(sum(litri) FILTER (WHERE created_at >= p_godina_start  AND created_at < p_godina_end),  0) AS godina_litri
    FROM pot
  ),
  prosek AS (
    SELECT prosek_litri, radnih_dana FROM public.v3_gorivo_dnevni_prosek()
  ),
  prosek_u AS (
    SELECT prosek_rsd FROM public.v3_gorivo_dnevni_prosek_uplata()
  )
  SELECT jsonb_build_object(
    'danas_litri',   s.danas_litri,
    'nedelja_litri', s.nedelja_litri,
    'mesec_litri',   s.mesec_litri,
    'godina_litri',  s.godina_litri,
    'prosek_litri',  p.prosek_litri,
    'prosek_rsd',    u.prosek_rsd,
    'radnih_dana',   p.radnih_dana
  )
  FROM sums s, prosek p, prosek_u u;
$func$;

GRANT EXECUTE ON FUNCTION public.fn_v3_gorivo_pregled(
  timestamptz, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, timestamptz, timestamptz
) TO anon, authenticated;

-- PostgREST schema reload da se RPC odmah vidi.
NOTIFY pgrst, 'reload schema';
