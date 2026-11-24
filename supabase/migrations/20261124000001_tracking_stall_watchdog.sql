-- Tracking stall watchdog.
--
-- Problem (2026-11-24): kada vozač zaključa telefon, tickovi (GPS + ETA) na
-- nekim uređajima u potpunosti staju — FGS se ne podiže ili je ugašen od
-- strane OS/OEM battery managera. Posledica: vozac_location zastari, putnici
-- ne vide ETA, "vozač je krenuo" push kasni do otključavanja. Server ne može
-- da pokrene tracking, ali MOŽE da detektuje zamrzavanje i gurne high-
-- priority push vozaču — FCM budi app (auto-restart FGS) i/ili vozač tapne
-- notifikaciju pa se sesija obnovi kroz tryRestoreFromSession.
--
-- Uslovi za push (sve mora da važi):
--   - slot ima tracking_started_at u poslednja 4h (sesija je zaista bila
--     aktivna — ne diramo slotove gde tracking nikad nije ni startovan)
--   - termin još ima bar jednog aktivnog putnika (ne vraćamo "kraj vožnje")
--   - vozac_location za vlasnika slota je stariji od 3 min (ili nikad nije
--     stigla) — lokacija je po VOZAČU, pa sveži tick sa BILO KOG slota
--     ućutkuje watchdog za sve njegove slotove (vozač track-uje jedan termin)
--   - tracking_started_at je stariji od 3 min (prvi tick mora da stigne)
--
-- Throttle: tracking_stall_notified_at — najviše 1 push na 10 min po slotu;
-- kolona se resetuje na NULL kad lokacija osveži, pa sledeći zamrzak opet
-- javlja (po slotu, ne globalno po vozaču).

ALTER TABLE public.v3_trenutna_dodela_slot
  ADD COLUMN IF NOT EXISTS tracking_stall_notified_at timestamptz;

CREATE OR REPLACE FUNCTION public.fn_v3_tracking_stall_watchdog()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_stale_after constant interval := interval '3 minutes';
  v_throttle constant interval := interval '10 minutes';
  v_session_max_age constant interval := interval '4 hours';
  r record;
  v_tokens jsonb;
BEGIN
  -- Reset throttle-a čim lokacija osveži — sledeći stall ponovo javlja.
  UPDATE public.v3_trenutna_dodela_slot s
  SET tracking_stall_notified_at = NULL
  WHERE s.tracking_stall_notified_at IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.v3_vozac_location l
      WHERE l.vozac_id = s.vozac_v3_auth_id
        AND l.updated_at > now() - v_stale_after
    );

  FOR r IN
    SELECT s.id AS slot_id, s.vozac_v3_auth_id, s.grad, s.vreme, s.datum
    FROM public.v3_trenutna_dodela_slot s
    WHERE s.tracking_started_at IS NOT NULL
      AND s.tracking_started_at > now() - v_session_max_age
      AND s.tracking_started_at < now() - v_stale_after
      AND s.vozac_v3_auth_id IS NOT NULL
      AND (s.tracking_stall_notified_at IS NULL
           OR s.tracking_stall_notified_at < now() - v_throttle)
      -- Termin još ima aktivnih putnika (ništa ako je vožnja stvarno gotova).
      AND EXISTS (
        SELECT 1
        FROM public.v3_operativna_nedelja o
        WHERE o.datum = s.datum
          AND upper(trim(coalesce(o.grad, ''))) = upper(trim(s.grad))
          AND date_trunc('minute', o.polazak_at) = date_trunc('minute', s.vreme)
          AND o.created_by IS NOT NULL
          AND o.otkazano_at IS NULL
          AND o.pokupljen_at IS NULL
      )
      -- Lokacija vozača zastarela (ili nikad nije stigla).
      AND NOT EXISTS (
        SELECT 1
        FROM public.v3_vozac_location l
        WHERE l.vozac_id = s.vozac_v3_auth_id
          AND l.updated_at > now() - v_stale_after
      )
  LOOP
    SELECT coalesce(jsonb_agg(tkn), '[]'::jsonb) INTO v_tokens
    FROM (
      SELECT jsonb_build_object('token', a.push_token, 'provider', 'fcm') AS tkn
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token IS NOT NULL AND btrim(a.push_token) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_2, 'provider', 'fcm')
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token_2 IS NOT NULL AND btrim(a.push_token_2) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_3, 'provider', 'fcm')
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token_3 IS NOT NULL AND btrim(a.push_token_3) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms, 'provider', 'hms')
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token_hms IS NOT NULL AND btrim(a.push_token_hms) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms_2, 'provider', 'hms')
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token_hms_2 IS NOT NULL AND btrim(a.push_token_hms_2) <> ''
      UNION
      SELECT jsonb_build_object('token', a.push_token_hms_3, 'provider', 'hms')
      FROM public.v3_auth a
      WHERE a.id = r.vozac_v3_auth_id AND a.push_token_hms_3 IS NOT NULL AND btrim(a.push_token_hms_3) <> ''
    ) t;

    -- Push ide i bez tokena? Ne — notify_push sa praznim nizom ne šalje ništa,
    -- ali markiramo slot da ne spamuje upit svaka 2 min.
    IF jsonb_array_length(v_tokens) > 0 THEN
      PERFORM public.notify_push(
        v_tokens,
        'Praćenje lokacije je stalo',
        'Putnici ne vide vašu lokaciju. Dodirnite da nastavite praćenje.',
        jsonb_build_object(
          'type', 'tracking_stalled',
          'event_id', format('tracking_stalled:%s:%s', r.slot_id::text, floor(extract(epoch from now()) / 600)::text),
          'vozac_id', r.vozac_v3_auth_id,
          'datum', r.datum,
          'grad', r.grad,
          'vreme', to_char(r.vreme, 'HH24:MI'),
          'screen', 'v3_vozac',
          'title_sr', 'Praćenje lokacije je stalo',
          'title_en', 'Location tracking stopped',
          'title_ru', 'Отслеживание местоположения остановлено',
          'title_de', 'Standortverfolgung gestoppt',
          'title_zh', '位置跟踪已停止',
          'body_sr', 'Putnici ne vide vašu lokaciju. Dodirnite da nastavite praćenje.',
          'body_en', 'Passengers cannot see your location. Tap to resume tracking.',
          'body_ru', 'Пассажиры не видят ваше местоположение. Нажмите, чтобы продолжить отслеживание.',
          'body_de', 'Fahrgäste können Ihren Standort nicht sehen. Tippen, um die Verfolgung fortzusetzen.',
          'body_zh', '乘客无法看到您的位置。点击以继续跟踪。'
        )
      );
    END IF;

    UPDATE public.v3_trenutna_dodela_slot
    SET tracking_stall_notified_at = now()
    WHERE id = r.slot_id;
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_v3_tracking_stall_watchdog()
  FROM PUBLIC, anon, authenticated;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'tracking_stall_watchdog') then
    perform cron.schedule(
      'tracking_stall_watchdog',
      '*/2 * * * *',
      $c$SELECT public.fn_v3_tracking_stall_watchdog();$c$
    );
  end if;
end $$;
