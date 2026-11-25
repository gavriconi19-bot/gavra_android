import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../globals.dart';
import '../../utils/v3_belgrade_time.dart';
import 'v3_tracking_config.dart';

/// Android FGS isolate — isti [v3RunTrackingTick] kao main.
/// Ne aktivira slot (to radi samo main `start()`).
///
/// Sesija se čita iz SharedPreferences na startu isolate-a jer
/// `invoke('startTracking')` može stići pre listenera.
@pragma('vm:entry-point')
Future<void> onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  V3BelgradeTime.location;

  String? vozacId;
  String? datumIso;
  String? grad;
  String? vreme;
  DateTime? startedAt;
  DateTime? polazakAt;
  int noSlotStrikes = 0;
  int lastPersistedStandstill = -1;
  bool tickInFlight = false;
  int prefsCheckCounter = 0;

  /// Upisuje akumuliranu standstill kaznu u session prefs — main isolate je
  /// usvaja na BG→FG prelazu (vidi _pauseBgTicks), bez staleness-a.
  Future<void> persistStandstillSeconds() async {
    try {
      final saved = await v3LoadBgTrackingSession();
      if (saved == null) return;
      saved['standstill_seconds'] = v3GetStandstillSeconds();
      await v3SaveBgTrackingSession(saved);
    } catch (_) {}
  }
  V3SelfReschedulingTicker? ticker;
  Timer? expiryWatchdog;
  SupabaseClient? client;

  Future<void> ensureSupabase() async {
    if (client != null) return;
    try {
      if (Supabase.instance.client.auth.currentSession != null) {
        client = Supabase.instance.client;
        return;
      }
    } catch (_) {}
    try {
      await configService.initializeBasic();
      final url = configService.getSupabaseUrl().trim();
      final anonKey = configService.getSupabaseAnonKey().trim();
      if (url.isEmpty || anonKey.isEmpty) {
        debugPrint('[BG_TRACKING] Nedostaju Supabase kredencijali');
        return;
      }
      await Supabase.initialize(url: url, anonKey: anonKey);
      client = Supabase.instance.client;
    } catch (e) {
      debugPrint('[BG_TRACKING] Supabase init greška: $e');
    }
  }

  void stopTracking() {
    debugPrint('[BG_TRACKING] stop');
    ticker?.cancel();
    ticker = null;
    v3StopPositionKeepAlive(logTag: '[BG_TRACKING]');
    expiryWatchdog?.cancel();
    expiryWatchdog = null;
    vozacId = null;
    datumIso = null;
    grad = null;
    vreme = null;
    startedAt = null;
    polazakAt = null;
    noSlotStrikes = 0;
    prefsCheckCounter = 0;
    // Ako je prethodni tick zaglavio (half-open TCP), flag bi preživeo
    // stop/start i onemogućio svaki sledeći doTick zauvek.
    tickInFlight = false;
    v3SetStandstillSeconds(0);
  }

  void pauseTicks() {
    ticker?.cancel();
    ticker = null;
    // Pauza = main preuzeo tickove — stream u BG isolate-u tada samo
    // prazn drži GNSS budnim.
    v3StopPositionKeepAlive(logTag: '[BG_TRACKING]');
    unawaited(persistStandstillSeconds());
    debugPrint('[BG_TRACKING] pauseTicks');
  }

  void finishAndStop(String reason) {
    debugPrint('[BG_TRACKING] stop reason=$reason');
    stopTracking();
    unawaited(v3ClearBgTrackingSession());
    try {
      service.invoke('trackingEnded', <String, dynamic>{'reason': reason});
    } catch (e) {
      debugPrint('[BG_TRACKING] trackingEnded invoke greška: $e');
    }
    service.stopSelf();
  }

  Future<void> doTick() async {
    if (vozacId == null || datumIso == null || grad == null || vreme == null) return;
    // Ticker zakazuje sledeci tick i kad prethodni timeout-uje (ne otkazuje ga)
    // — bez ovog guard-a bi 90s+ zaglavljen tick pravio paralelne upise.
    if (tickInFlight) return;
    tickInFlight = true;

    try {
      // Pause flag zivi u prefs; servicePipe ('pauseTicks') moze dropovati
      // event pa BG i FG ticker rade paralelno — self-heal re-check ~svakih
      // 30s (6 tickova) dokazuje flag i gasi ticker.
      if (++prefsCheckCounter >= 6) {
        prefsCheckCounter = 0;
        final saved = await v3LoadBgTrackingSession();
        if (saved == null) {
          // Session obrisan (stop() u main-u) dok je 'stopService' invoke
          // dropovao — bez ovoga FGS + notifikacija stoje do hard-stopa.
          debugPrint('[BG_TRACKING] sesija obrisana — stopSelf (heal za dropovan stop)');
          stopTracking();
          service.stopSelf();
          return;
        }
        if (saved['ticks_paused'] == true) {
          debugPrint('[BG_TRACKING] ticks_paused u prefs — pauseTicks (self-heal)');
          pauseTicks();
          return;
        }
      }

      if (v3TrackingTimedOut(startedAt: startedAt, polazakAt: polazakAt)) {
        finishAndStop('timeout polazak=$polazakAt');
        return;
      }

      await ensureSupabase();
      if (client == null) return;

      try {
        // allDone pre tick-a (kao FG): jeftinije, bez suvišnog compute-eta.
        final allDone = await v3AllPassengersCompleted(
        client: client!,
        vozacId: vozacId!,
        datumIso: datumIso!,
        grad: grad!,
        vreme: vreme!,
      );
      if (allDone) {
        finishAndStop('all_passengers_completed');
        return;
      }

      // Kao FG: compute-eta (OSRM reoptimizacija) na svaki tick.
      final result = await v3RunTrackingTick(
        client: client!,
        vozacId: vozacId!,
        grad: grad!,
        vreme: vreme!,
        datumIso: datumIso!,
        logTag: '[BG_TRACKING]',
      );

      // Isti guard kao FG: slot obrisan u hodu → no_active_slot zauvek.
      // Strikes se broje tek od polazka (pre toga auto-prepare može kasniti);
      // 12 strikes ≈ ~60s konzistentnog odgovora (compute-eta na svaki tick).
      final postDeparture = polazakAt == null || !V3BelgradeTime.now().isBefore(polazakAt!);
      if (result.reason == 'no_active_slot' && postDeparture) {
        noSlotStrikes++;
        if (noSlotStrikes >= 12) {
          finishAndStop('no_active_slot');
          return;
        }
      } else {
        noSlotStrikes = 0;
      }
      } catch (e) {
        debugPrint('[BG_TRACKING] tick greška: $e');
      }

      // Persist samo kad se kazna promenila (stajanje → svaki tick ~5s,
      // mala prefs vrednost; u pokretu → jedan write na reset u 0).
      final ss = v3GetStandstillSeconds();
      if (ss != lastPersistedStandstill) {
        lastPersistedStandstill = ss;
        unawaited(persistStandstillSeconds());
      }
    } finally {
      tickInFlight = false;
    }
  }

  /// Self-heal suprotno od doTick pause-check-a: ako je ticker mrtav a prefs
  /// kažu da tickovi treba da rade — restartuje ticker. Zove ga watchdog
  /// (svakih 60s), pa najviše ~1min izgubljenih tickova.
  Future<void> maybeResumeTicks() async {
    if (ticker != null || vozacId == null) return;
    try {
      final saved = await v3LoadBgTrackingSession();
      if (saved == null) {
        // Isto kao doTick check: main je obrisao sesiju (stop) a 'stopService'
        // invoke nije stigao — FGS + notifikacija ne smeju stajati.
        debugPrint('[BG_TRACKING] sesija obrisana — stopSelf (heal za dropovan stop)');
        stopTracking();
        service.stopSelf();
        return;
      }
      if (saved['ticks_paused'] == true) {
        // FG pauza važi samo dok main živi — _fgTick stampa fg_alive_at
        // (~30s). Zastareo heartbeat = app ugašena u pauzi (watchdog respawn
        // posle kill-a, OEM kill bez detached event-a): nastavi tickove —
        // vozač je i dalje u vožnji, a lažna "aktivno" notifikacija uz
        // mrtav tracking je najgori ishod.
        final fgAliveAt = V3BelgradeTime.parseTs(saved['fg_alive_at']?.toString());
        final fgDead = fgAliveAt == null ||
            DateTime.now().difference(fgAliveAt) > const Duration(seconds: 150);
        if (!fgDead) return;
        debugPrint('[BG_TRACKING] fg heartbeat zastareo — main mrtav, nastavljam tickove');
        saved['ticks_paused'] = false;
        await v3SaveBgTrackingSession(saved);
      }
      debugPrint('[BG_TRACKING] self-heal: ticker mrtav a sesija aktivna — restartujem');
      v3StartPositionKeepAlive(logTag: '[BG_TRACKING]');
      ticker = V3SelfReschedulingTicker(interval: v3TrackingTickInterval, onTick: doTick)..start();
    } catch (e) {
      debugPrint('[BG_TRACKING] self-heal greška: $e');
    }
  }

  void startTracking(Map<String, dynamic>? args) {
    final m = args ?? <String, dynamic>{};
    final id = (m['vozac_id']?.toString() ?? '').trim();
    final datum = V3BelgradeTime.parseIsoDatePart(m['datum_iso']?.toString() ?? '');
    final g = (m['grad']?.toString() ?? '').trim().toUpperCase();
    final v = V3BelgradeTime.normalizeToHHmm(m['vreme']?.toString() ?? '');

    if (id.isEmpty || datum.isEmpty || g.isEmpty || v.isEmpty) {
      debugPrint('[BG_TRACKING] start preskočen: nedostaju podaci');
      return;
    }

    vozacId = id;
    datumIso = datum;
    grad = g;
    vreme = v;
    noSlotStrikes = 0;
    prefsCheckCounter = 0;
    // Novi ticker ne sme naslediti flag zaglavljenog tick-a.
    tickInFlight = false;
    // Standstill kazna iz FG sesije — BG nastavlja akumulaciju, ne resetuje.
    v3SetStandstillSeconds((m['standstill_seconds'] as num?)?.toInt() ?? 0);
    startedAt = V3BelgradeTime.parseTs(m['started_at']?.toString()) ?? V3BelgradeTime.now();
    polazakAt = V3BelgradeTime.parseTs(m['polazak_at']?.toString()) ?? v3PolazakDateTime(datumIso: datum, vreme: v);
    debugPrint('[BG_TRACKING] start $g $v polazak=$polazakAt');

    // Hard-stop provera i dok su tickovi pauzirani (app u FG ili ugašen) —
    // inače bi FGS + notifikacija stajali bez aktivnog trackinga.
    expiryWatchdog ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (v3TrackingTimedOut(startedAt: startedAt, polazakAt: polazakAt)) {
        finishAndStop('timeout_watchdog');
        return;
      }
      // Self-heal: 'startTracking' invoke je servicePipe (best-effort) i može
      // dropovati — ticker tada ostaje null dok prefs kažu da treba da radi
      // (ticks_paused=false). Bez ovoga tracking ćutke zamre do sledećeg
      // invoke-a ili resume-a. Radi i dok je ticker pauziran (watchdog živi).
      if (ticker == null && vozacId != null) {
        unawaited(maybeResumeTicks());
      }
    });

    ticker?.cancel();
    // Keep-alive GNSS stream — bez njega se sa zaključanim ekranom tickovi
    // izvrše, ali getCurrentPosition završava u timeout-u (OS nema aktivni
    // kontinuiran zahtev) i lokacija/ETA stoje po 14-22min.
    v3StartPositionKeepAlive(logTag: '[BG_TRACKING]');
    ticker = V3SelfReschedulingTicker(interval: v3TrackingTickInterval, onTick: doTick)..start();
  }

  service.on('startTracking').listen((event) {
    startTracking(event is Map<String, dynamic> ? event : null);
  });
  service.on('pauseTicks').listen((_) {
    pauseTicks();
  });
  service.on('stopService').listen((_) {
    stopTracking();
    service.stopSelf();
  });

  try {
    final saved = await v3LoadBgTrackingSession();
    if (saved == null) {
      // Respawn bez sesije (watchdog / stop race) — FGS + notifikacija ne
      // smeju stajati dok tracking ne radi.
      debugPrint('[BG_TRACKING] nema sesije — stopSelf');
      service.stopSelf();
      return;
    }

    // Sesija je mogla isteći dok je ticker bio pauziran (app ugašen u FG).
    if (v3TrackingTimedOut(
      startedAt: V3BelgradeTime.parseTs(saved['started_at']?.toString()),
      polazakAt: V3BelgradeTime.parseTs(saved['polazak_at']?.toString()) ??
          v3PolazakDateTime(
            datumIso: V3BelgradeTime.parseIsoDatePart(saved['datum_iso']?.toString() ?? ''),
            vreme: V3BelgradeTime.normalizeToHHmm(saved['vreme']?.toString() ?? ''),
          ),
    )) {
      debugPrint('[BG_TRACKING] sesija istekla — stopSelf');
      unawaited(v3ClearBgTrackingSession());
      service.stopSelf();
      return;
    }

    if (saved['ticks_paused'] == true) {
      // startTracking puni session polja (potrebna expiry watchdog-u), pa pauza.
      startTracking(saved);
      pauseTicks();
    } else {
      debugPrint('[BG_TRACKING] resume iz prefs');
      startTracking(saved);
    }
  } catch (e) {
    debugPrint('[BG_TRACKING] prefs resume greška: $e');
  }
}

/// iOS BG fetch mreža — jedan tick iz sesije.
/// Primarni put je main ticker + location keep-alive.
@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  V3BelgradeTime.location;

  try {
    final saved = await v3LoadBgTrackingSession();
    if (saved == null) return true;

    final id = (saved['vozac_id']?.toString() ?? '').trim();
    final datum = V3BelgradeTime.parseIsoDatePart(saved['datum_iso']?.toString() ?? '');
    final g = (saved['grad']?.toString() ?? '').trim().toUpperCase();
    final v = V3BelgradeTime.normalizeToHHmm(saved['vreme']?.toString() ?? '');
    if (id.isEmpty || datum.isEmpty || g.isEmpty || v.isEmpty) return true;

    final startedAt = V3BelgradeTime.parseTs(saved['started_at']?.toString());
    final polazakAt =
        V3BelgradeTime.parseTs(saved['polazak_at']?.toString()) ?? v3PolazakDateTime(datumIso: datum, vreme: v);

    Future<void> end(String reason) async {
      debugPrint('[BG_TRACKING_IOS] stop reason=$reason');
      await v3ClearBgTrackingSession();
      try {
        service.invoke('trackingEnded', <String, dynamic>{'reason': reason});
      } catch (e) {
        debugPrint('[BG_TRACKING_IOS] trackingEnded invoke greška: $e');
      }
    }

    if (v3TrackingTimedOut(startedAt: startedAt, polazakAt: polazakAt)) {
      await end('timeout');
      return true;
    }

    SupabaseClient? client;
    try {
      client = Supabase.instance.client;
    } catch (_) {
      client = null;
    }
    if (client == null) {
      await configService.initializeBasic();
      final url = configService.getSupabaseUrl().trim();
      final anonKey = configService.getSupabaseAnonKey().trim();
      if (url.isEmpty || anonKey.isEmpty) return true;
      await Supabase.initialize(url: url, anonKey: anonKey);
      client = Supabase.instance.client;
    }

    // Standstill kazna iz sesije — bez ovoga bi BG-fetch tick slao 0 i
    // gubio akumuliranu kaznu iz FG/FGS isolate-a.
    v3SetStandstillSeconds((saved['standstill_seconds'] as num?)?.toInt() ?? 0);

    await v3RunTrackingTick(
      client: client,
      vozacId: id,
      grad: g,
      vreme: v,
      datumIso: datum,
      logTag: '[BG_TRACKING_IOS]',
    ).timeout(const Duration(seconds: 25));

    // Persist nazad — kazna se nastavlja, ne resetuje na handoff-u.
    try {
      saved['standstill_seconds'] = v3GetStandstillSeconds();
      await v3SaveBgTrackingSession(saved);
    } catch (_) {}

    final allDone = await v3AllPassengersCompleted(
      client: client,
      vozacId: id,
      datumIso: datum,
      grad: g,
      vreme: v,
    ).timeout(const Duration(seconds: 10), onTimeout: () => false);

    if (allDone) {
      await end('all_passengers_completed');
    } else {
      debugPrint('[BG_TRACKING_IOS] jedan background tick OK');
    }
  } catch (e) {
    debugPrint('[BG_TRACKING_IOS] background tick greška: $e');
  }
  return true;
}
