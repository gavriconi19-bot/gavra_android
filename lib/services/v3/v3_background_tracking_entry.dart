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

  int stopStrikes = 0;
  bool tickInFlight = false;
  int prefsCheckCounter = 0;
  DateTime? lastTickStamp;
  String? lastBgError;
  V3TrackingSession? session;
  V3SelfReschedulingTicker? ticker;
  Timer? expiryWatchdog;
  SupabaseClient? client;

  /// Perzistira grešku u session prefs samo pri promeni — supervisor u
  /// main isolate-u je pročita i upiše kao breadcrumb.
  void bgErrorOnce(String error) {
    if (lastBgError == error) return;
    lastBgError = error;
    unawaited(v3SetBgSessionField('bg_last_error', error));
  }

  Future<void> ensureSupabase() async {
    if (client != null) return;
    try {
      if (Supabase.instance.client.auth.currentSession != null) {
        client = Supabase.instance.client;
        return;
      }
    } catch (_) {}
    try {
      // Timeout-i: zaglavljen plugin/dotenv poziv bi držao tickInFlight
      // zauvek (ticker timeout ne resetuje flag) — svaki tick tiho izlazi.
      await configService.initializeBasic().timeout(const Duration(seconds: 15));
      final url = configService.getSupabaseUrl().trim();
      final anonKey = configService.getSupabaseAnonKey().trim();
      if (url.isEmpty || anonKey.isEmpty) {
        debugPrint('[BG_TRACKING] Nedostaju Supabase kredencijali');
        bgErrorOnce('no_credentials');
        return;
      }
      await Supabase.initialize(url: url, anonKey: anonKey).timeout(const Duration(seconds: 20));
      client = Supabase.instance.client;
      unawaited(v3SetBgSessionField('bg_supabase_ok', true));
      unawaited(v3LogTrackingEvent(event: 'bg_supabase_ok', vozacId: session?.vozacId, client: client));
    } catch (e) {
      debugPrint('[BG_TRACKING] Supabase init greška: $e');
      bgErrorOnce('supabase_init:$e');
    }
  }

  void stopTracking() {
    debugPrint('[BG_TRACKING] stop');
    ticker?.cancel();
    ticker = null;
    v3StopPositionKeepAlive(logTag: '[BG_TRACKING]');
    expiryWatchdog?.cancel();
    expiryWatchdog = null;
    session = null;
    stopStrikes = 0;
    prefsCheckCounter = 0;
    // Ako je prethodni tick zaglavio (half-open TCP), flag bi preživeo
    // stop/start i onemogućio svaki sledeći doTick zauvek.
    tickInFlight = false;
  }

  void pauseTicks() {
    ticker?.cancel();
    ticker = null;
    // Pauza = main preuzeo tickove — stream u BG isolate-u tada samo
    // prazn drži GNSS budnim.
    v3StopPositionKeepAlive(logTag: '[BG_TRACKING]');
    debugPrint('[BG_TRACKING] pauseTicks');
  }

  void finishAndStop(String reason) {
    debugPrint('[BG_TRACKING] stop reason=$reason');
    unawaited(v3LogTrackingEvent(
      event: 'bg_stop',
      vozacId: session?.vozacId,
      client: client,
      detail: <String, dynamic>{'reason': reason},
    ));
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
    final s = session;
    if (s == null) return;
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

      if (v3TrackingTimedOut(startedAt: s.startedAt, polazakAt: s.polazakAt)) {
        finishAndStop('timeout polazak=${s.polazakAt}');
        return;
      }

      // Zdravstveni marker — supervisor u main-u iz njega vidi da isolate
      // živi čak i kad mrežni deo tick-a ne prolazi (svež marker + zamrznuta
      // lokacija = mrežni/doze stall, zastareo marker = mrtav isolate).
      // Throttle ~10s — prefs write je mala vrednost.
      final now = DateTime.now();
      if (lastTickStamp == null || now.difference(lastTickStamp!) > const Duration(seconds: 10)) {
        lastTickStamp = now;
        unawaited(v3SetBgSessionField('bg_tick_at', now.toUtc().toIso8601String()));
      }

      await ensureSupabase();
      if (client == null) return;

      try {
        // Kao FG: compute-eta (OSRM reoptimizacija) na svaki tick.
        final result = await v3RunTrackingTick(
          client: client!,
          vozacId: s.vozacId,
          grad: s.grad,
          vreme: s.vreme,
          datumIso: s.datumIso,
          logTag: '[BG_TRACKING]',
        );

        // Isti guard kao FG: terminalni razlozi iz edge odgovora.
        // no_active_slot se broji tek od polazka (pre toga auto-prepare
        // moze kasniti); ostali razlozi su stabilna stanja i broj se
        // i pre polaska (kao raniji allDone). 12 strikes ≈ ~60s.
        final postDeparture = s.polazakAt == null || !V3BelgradeTime.now().isBefore(s.polazakAt!);
        final terminal = switch (result.reason) {
          'no_active_slot' => postDeparture,
          'no_remaining_passengers' ||
          'no_active_passengers' ||
          'slot_not_owner' =>
            true,
          _ => false,
        };
        if (terminal) {
          stopStrikes++;
          if (stopStrikes >= 12) {
            finishAndStop(result.reason ?? 'terminal');
            return;
          }
        } else {
          stopStrikes = 0;
        }
      } catch (e) {
        debugPrint('[BG_TRACKING] tick greška: $e');
      }
    } finally {
      tickInFlight = false;
    }
  }

  /// Self-heal suprotno od doTick pause-check-a: ako je ticker mrtav a prefs
  /// kažu da tickovi treba da rade — restartuje ticker. Zove ga watchdog
  /// (svakih 60s), pa najviše ~1min izgubljenih tickova.
  Future<void> maybeResumeTicks() async {
    if (ticker != null || session == null) return;
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

  void startTracking(V3TrackingSession s) {
    stopStrikes = 0;
    prefsCheckCounter = 0;
    // Novi ticker ne sme naslediti flag zaglavljenog tick-a.
    tickInFlight = false;
    session = s;
    debugPrint('[BG_TRACKING] start ${s.grad} ${s.vreme} polazak=${s.polazakAt}');
    // Dokaz da je invoke stigao i engine živ — supervisor ovo čita za
    // grace period (boot + prvi tick mogu potrajati).
    unawaited(v3SetBgSessionField('bg_tracking_start_at', DateTime.now().toUtc().toIso8601String()));

    // Hard-stop provera i dok su tickovi pauzirani (app u FG ili ugašen) —
    // inače bi FGS + notifikacija stajali bez aktivnog trackinga.
    expiryWatchdog ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (v3TrackingTimedOut(startedAt: s.startedAt, polazakAt: s.polazakAt)) {
        finishAndStop('timeout_watchdog');
        return;
      }
      // Self-heal: 'startTracking' invoke je servicePipe (best-effort) i može
      // dropovati — ticker tada ostaje null dok prefs kažu da treba da radi
      // (ticks_paused=false). Bez ovoga tracking ćutke zamre do sledećeg
      // invoke-a ili resume-a. Radi i dok je ticker pauziran (watchdog živi).
      if (ticker == null && session != null) {
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
    final s = V3TrackingSession.tryParse(event is Map ? event : null);
    if (s != null) startTracking(s);
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

    // Engine boot sa živom sesijom (respawn ili prvi start) — marker za
    // dijagnostiku bez posebnog DB upisa (supervisor ga prosledi uz stall).
    unawaited(v3SetBgSessionField('bg_booted_at', DateTime.now().toUtc().toIso8601String()));

    // Sesija je mogla isteći dok je ticker bio pauziran (app ugašen u FG).
    final savedSession = V3TrackingSession.tryParse(saved);
    if (savedSession == null ||
        v3TrackingTimedOut(startedAt: savedSession.startedAt, polazakAt: savedSession.polazakAt)) {
      debugPrint('[BG_TRACKING] sesija istekla/neispravna — stopSelf');
      unawaited(v3ClearBgTrackingSession());
      service.stopSelf();
      return;
    }

    if (savedSession.ticksPaused) {
      // startTracking puni session polja (potrebna expiry watchdog-u), pa pauza.
      startTracking(savedSession);
      pauseTicks();
    } else {
      debugPrint('[BG_TRACKING] resume iz prefs');
      startTracking(savedSession);
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

    final session = V3TrackingSession.tryParse(saved);
    if (session == null) return true;

    Future<void> end(String reason) async {
      debugPrint('[BG_TRACKING_IOS] stop reason=$reason');
      await v3ClearBgTrackingSession();
      try {
        service.invoke('trackingEnded', <String, dynamic>{'reason': reason});
      } catch (e) {
        debugPrint('[BG_TRACKING_IOS] trackingEnded invoke greška: $e');
      }
    }

    if (v3TrackingTimedOut(startedAt: session.startedAt, polazakAt: session.polazakAt)) {
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

    await v3RunTrackingTick(
      client: client,
      vozacId: session.vozacId,
      grad: session.grad,
      vreme: session.vreme,
      datumIso: session.datumIso,
      logTag: '[BG_TRACKING_IOS]',
    ).timeout(const Duration(seconds: 25));

    final allDone = await v3AllPassengersCompleted(
      client: client,
      vozacId: session.vozacId,
      datumIso: session.datumIso,
      grad: session.grad,
      vreme: session.vreme,
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
