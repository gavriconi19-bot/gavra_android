import 'dart:async';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/v3_belgrade_time.dart';
import 'v3_device_identity_service.dart';
import 'v3_slot_activation.dart';
import 'v3_tracking_config.dart';

/// Ishod [V3VozacLocationTrackingService.start].
enum V3TrackingStartResult {
  started,
  alreadyRunning,
  missingData,
  inProgress,
  gpsDisabled,
  permissionDenied,
  permissionDeniedForever,
  permissionAlwaysRequired,
  failed,
}

extension V3TrackingStartResultX on V3TrackingStartResult {
  bool get isSuccess => this == V3TrackingStartResult.started || this == V3TrackingStartResult.alreadyRunning;

  /// l10n ključ za grešku; `null` ako je uspeh.
  String? get errorL10nKey => switch (this) {
        V3TrackingStartResult.started || V3TrackingStartResult.alreadyRunning => null,
        V3TrackingStartResult.gpsDisabled => 'gpsIskljucen',
        V3TrackingStartResult.permissionDenied => 'dozvolaOdbijena',
        V3TrackingStartResult.permissionDeniedForever => 'dozvolaTrajnoOdbijena',
        V3TrackingStartResult.permissionAlwaysRequired => 'dozvolaPotrebnaUvek',
        V3TrackingStartResult.missingData => 'nemogucIdentifikovatiVozaca',
        V3TrackingStartResult.inProgress => 'autoStartUToku',
        V3TrackingStartResult.failed => 'autoStartVanProzora',
      };
}

/// GPS/ETA tracking vozača — jedan izvor istine za FG i BG.
///
/// Start: V3VozacScreen auto-start (T-15). Zahteva GPS + **Always**.
/// Tick (5s): live GPS → `v3_vozac_location`; `v3-compute-eta` na svaki tick
/// (OSRM /trip reoptimizacija preostalih putnika sa sveže pozicije).
/// Stop: svi putnici gotovi, hard-stop (polazak+[v3TrackingHardStop]),
/// ili ručni stop.
///
/// Platforme (dok traje vožnja):
/// - **Android** — FGS notifikacija živi dok je tracking aktivan
/// - **Android FG** — main ticker; FGS ticker pauziran
/// - **Android BG** — FGS isolate ticker; main ticker ugašen
/// - **iOS** — uvek main ticker + location keep-alive (nema pouzdanog FGS)
/// - cold start — [tryRestoreFromSession] iz prefs / FGS
class V3VozacLocationTrackingService with WidgetsBindingObserver {
  V3VozacLocationTrackingService._();

  static final V3VozacLocationTrackingService instance = V3VozacLocationTrackingService._();

  static const _tag = '[V3VozacLocationTrackingService]';
  static const _bgNotificationId = 888;

  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  String _vozacId = '';
  String _datumIso = '';
  String _grad = '';
  String _vreme = '';
  bool _isRunning = false;
  bool _startInProgress = false;
  bool _stopInProgress = false;
  bool _restoreInProgress = false;
  DateTime? _startedAt;
  DateTime? _polazakAt;
  DateTime? _lastTickAt;
  V3SelfReschedulingTicker? _fgTicker;
  StreamSubscription<Map<String, dynamic>?>? _bgEndedSub;
  StreamSubscription<Position>? _iosKeepAliveSub;
  bool _tickInFlight = false;
  int _noSlotStrikes = 0;

  /// Poslednja stop-ovana sesija — ekran je koristi za cooldown na auto-restart
  /// istog termina (allDone/no_active_slot petlja).
  String _lastStoppedSessionKey = '';
  DateTime? _lastStoppedAt;

  final List<String> _optimizedPutnikIds = [];

  final StreamController<({Map<String, int> etaMap, List<String> order, String? reason})> _etaTickController =
      StreamController<({Map<String, int> etaMap, List<String> order, String? reason})>.broadcast();

  final StreamController<bool> _runningController = StreamController<bool>.broadcast();

  bool get isRunning => _isRunning;
  List<String> get optimizedPutnikIds => List.unmodifiable(_optimizedPutnikIds);

  /// Aktivna tracking sesija (prazno ako ne radi). Nezavisno od UI selekcije termina.
  String get activeDatumIso => _isRunning ? _datumIso : '';
  String get activeGrad => _isRunning ? _grad : '';
  String get activeVreme => _isRunning ? _vreme : '';

  /// Ključ poslednje stop-ovane sesije (`datum|grad|vreme`) i kada je stopovana.
  String get lastStoppedSessionKey => _lastStoppedSessionKey;
  DateTime? get lastStoppedAt => _lastStoppedAt;

  /// Device-identity dokaz za `v3_notify_passengers_driver_started` RPC.
  /// Kesirano — vrednosti su stabilne za trajanje sesije.
  ({String installationId, String? hardwareId})? _deviceIds;

  Future<({String installationId, String? hardwareId})> _resolveDeviceIds() async {
    return _deviceIds ??= await V3DeviceIdentityService.getDeviceIds();
  }

  Stream<({Map<String, int> etaMap, List<String> order, String? reason})> get onEtaTick =>
      _etaTickController.stream;
  Stream<bool> get onRunningChanged => _runningController.stream;

  void _setRunning(bool value) {
    if (_isRunning == value) return;
    _isRunning = value;
    if (!_runningController.isClosed) {
      _runningController.add(value);
    }
  }

  void initialize() {
    WidgetsBinding.instance.addObserver(this);
    _bgEndedSub?.cancel();
    _bgEndedSub = FlutterBackgroundService().on('trackingEnded').listen((event) {
      final reason = event?['reason']?.toString() ?? 'bg';
      debugPrint('$_tag BG trackingEnded reason=$reason');
      if (_isRunning || _vozacId.isNotEmpty) {
        unawaited(stop());
      } else {
        unawaited(v3ClearBgTrackingSession());
        unawaited(_stopBg());
      }
    });
    unawaited(tryRestoreFromSession());
  }

  Map<String, dynamic> _sessionPayload({bool ticksPaused = false}) => <String, dynamic>{
        'vozac_id': _vozacId,
        'datum_iso': _datumIso,
        'grad': _grad,
        'vreme': _vreme,
        'started_at': _startedAt?.toUtc().toIso8601String(),
        'polazak_at': _polazakAt?.toUtc().toIso8601String(),
        'ticks_paused': ticksPaused,
        // FG↔BG handoff: BG isolate nastavlja kaznu umesto da je resetuje.
        'standstill_seconds': v3GetStandstillSeconds(),
        // FG heartbeat — BG watchdog iz zastarelog timestamp-a zaključuje da
        // je main mrtav (app ugašena dok su BG tickovi pauzirani) i nastavlja
        // tickove; inače ticks_paused ostaje true zauvek i notifikacija laže.
        'fg_alive_at': DateTime.now().toUtc().toIso8601String(),
      };

  bool _isSameSession({
    required String vozacId,
    required String datumIso,
    required String grad,
    required String vreme,
  }) {
    return _isRunning && _vozacId == vozacId && _datumIso == datumIso && _grad == grad && _vreme == vreme;
  }

  bool get _isAppInForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  V3TrackingStartResult _prereqToStartResult(V3LocationPrereqResult prereq) => switch (prereq) {
        V3LocationPrereqResult.ok => V3TrackingStartResult.failed,
        V3LocationPrereqResult.gpsDisabled => V3TrackingStartResult.gpsDisabled,
        V3LocationPrereqResult.denied => V3TrackingStartResult.permissionDenied,
        V3LocationPrereqResult.deniedForever => V3TrackingStartResult.permissionDeniedForever,
        V3LocationPrereqResult.alwaysRequired => V3TrackingStartResult.permissionAlwaysRequired,
      };

  /// Jedno mesto: koji engine radi (main ticker / Android FGS / iOS keep-alive).
  Future<void> _syncEngines({bool immediateTick = true}) async {
    if (!_isRunning || _vozacId.isEmpty) return;

    if (Platform.isIOS) {
      await v3SaveBgTrackingSession(_sessionPayload());
      // iOS: main isolate mora da ostane živ — ticker + continuous location.
      _startIosLocationKeepAlive();
      if (_fgTicker == null) _startFgTicker();
      if (immediateTick) unawaited(_fgTick());
      return;
    }

    // Android: notifikacija ostaje dok je tracking aktivan.
    // FG = main ticker (FGS ticker pauziran); BG = FGS ticker.
    await _ensureBgServiceRunning();
    if (_isAppInForeground) {
      await _pauseBgTicks();
      if (_fgTicker == null) _startFgTicker();
      if (immediateTick) unawaited(_fgTick());
    } else {
      _fgTicker?.cancel();
      _fgTicker = null;
      await _startBg();
    }
  }

  /// Reattach posle process death / cold start. Ne zove activate (već urađeno).
  Future<bool> tryRestoreFromSession() async {
    if (_isRunning) return true;
    if (_startInProgress || _stopInProgress || _restoreInProgress) return _isRunning;
    _restoreInProgress = true;

    try {
      final saved = await v3LoadBgTrackingSession();
      var bgRunning = false;
      if (!Platform.isIOS) {
        try {
          bgRunning = await FlutterBackgroundService().isRunning();
        } catch (e) {
          debugPrint('$_tag restore isRunning greška: $e');
        }
      }

      if (saved == null) {
        if (bgRunning) {
          debugPrint('$_tag restore: orphan BG bez sesije — gasim');
        }
        // Uvek: uklanja i orphan FGS notifikaciju kad servis ne radi.
        await _stopBg();
        return false;
      }

      final id = (saved['vozac_id']?.toString() ?? '').trim();
      final datum = V3BelgradeTime.parseIsoDatePart(saved['datum_iso']?.toString() ?? '');
      final g = (saved['grad']?.toString() ?? '').trim().toUpperCase();
      final v = V3BelgradeTime.normalizeToHHmm(saved['vreme']?.toString() ?? '');
      if (id.isEmpty || datum.isEmpty || g.isEmpty || v.isEmpty) {
        debugPrint('$_tag restore: neispravna sesija');
        await v3ClearBgTrackingSession();
        await _stopBg();
        return false;
      }

      final startedAt = V3BelgradeTime.parseTs(saved['started_at']?.toString());
      final polazakAt =
          V3BelgradeTime.parseTs(saved['polazak_at']?.toString()) ?? v3PolazakDateTime(datumIso: datum, vreme: v);

      if (v3TrackingTimedOut(startedAt: startedAt, polazakAt: polazakAt)) {
        debugPrint('$_tag restore: sesija istekla');
        await v3ClearBgTrackingSession();
        await _stopBg();
        return false;
      }

      final prereq = await v3CheckLocationPrerequisites();
      if (prereq != V3LocationPrereqResult.ok) {
        debugPrint('$_tag restore: nema Always GPS ($prereq) — stop');
        await v3ClearBgTrackingSession();
        await _stopBg();
        return false;
      }

      _vozacId = id;
      _datumIso = datum;
      _grad = g;
      _vreme = v;
      _startedAt = startedAt ?? V3BelgradeTime.now();
      _polazakAt = polazakAt;
      _lastTickAt = null;
      _optimizedPutnikIds.clear();
      v3SetStandstillSeconds((saved['standstill_seconds'] as num?)?.toInt() ?? 0);

      debugPrint('$_tag restore OK $g $v bgRunning=$bgRunning fg=$_isAppInForeground');
      // Jednom po T-15..hard-stop prozoru — RPC je no-op ako je već poslato.
      // Pre _setRunning: ako ovde padne (Supabase nije spreman), sesija ostaje
      // u prefs i sledeći resume ponovo pokušava restore.
      final ids = await _resolveDeviceIds();
      await activateSlotWithRetry(
        client: Supabase.instance.client,
        vozacId: id,
        datumIso: datum,
        grad: g,
        vreme: v,
        installationId: ids.installationId,
        hardwareId: ids.hardwareId,
        logTag: _tag,
        log: debugPrint,
      );
      _setRunning(true);
      await _syncEngines(immediateTick: true);
      return true;
    } catch (e) {
      debugPrint('$_tag restore greška: $e');
      // Ne diraj prefs sesiju — sledeći resume ponovo pokušava restore.
      // Bez reset-a bi _isRunning/polja mogli ostati u pola-postavljenom stanju.
      _clearLocalSessionState();
      return false;
    } finally {
      _restoreInProgress = false;
    }
  }

  Future<V3TrackingStartResult> start({
    required String vozacId,
    required String datumIso,
    required String grad,
    required String vreme,
  }) async {
    final id = vozacId.trim();
    final datum = V3BelgradeTime.parseIsoDatePart(datumIso);
    final g = grad.trim().toUpperCase();
    final v = V3BelgradeTime.normalizeToHHmm(vreme);

    debugPrint('$_tag start vozac=$id $g $v');

    if (id.isEmpty || datum.isEmpty || g.isEmpty || v.isEmpty) {
      debugPrint('$_tag start prekinut: nedostaju podaci');
      return V3TrackingStartResult.missingData;
    }
    if (_startInProgress || _restoreInProgress) {
      debugPrint('$_tag start u toku, preskačem');
      return V3TrackingStartResult.inProgress;
    }

    if (_isSameSession(vozacId: id, datumIso: datum, grad: g, vreme: v)) {
      debugPrint('$_tag start: ista sesija već radi');
      if (v3TrackingTimedOut(startedAt: _startedAt, polazakAt: _polazakAt)) {
        await stop();
        return V3TrackingStartResult.failed;
      }
      // Garantuj push jednom po prozoru ako prvi put nije prošao.
      final sameIds = await _resolveDeviceIds();
      await activateSlotWithRetry(
        client: Supabase.instance.client,
        vozacId: id,
        datumIso: datum,
        grad: g,
        vreme: v,
        installationId: sameIds.installationId,
        hardwareId: sameIds.hardwareId,
        logTag: _tag,
        log: debugPrint,
      );
      await _syncEngines(immediateTick: true);
      return V3TrackingStartResult.alreadyRunning;
    }

    _startInProgress = true;

    try {
      if (_isRunning) {
        await stop();
      } else {
        await _stopBg();
      }

      _vozacId = id;
      _datumIso = datum;
      _grad = g;
      _vreme = v;
      _polazakAt = v3PolazakDateTime(datumIso: datum, vreme: v);
      _startedAt = V3BelgradeTime.now();
      _lastTickAt = null;
      _optimizedPutnikIds.clear();
      v3SetStandstillSeconds(0);

      if (_polazakAt == null || !v3IsTrackingWindowOpen(polazakAt: _polazakAt!)) {
        debugPrint('$_tag start prekinut: van T-15..hard-stop');
        await _resetLocalSessionFields();
        return V3TrackingStartResult.failed;
      }

      final prereq = await v3CheckLocationPrerequisites();
      if (prereq != V3LocationPrereqResult.ok) {
        debugPrint('$_tag start prekinut: $prereq');
        await _resetLocalSessionFields();
        return _prereqToStartResult(prereq);
      }

      // Slot aktivacija SAMO ovde (main) — BG ne radi activate.
      final ids = await _resolveDeviceIds();
      await activateSlotWithRetry(
        client: Supabase.instance.client,
        vozacId: id,
        datumIso: datum,
        grad: g,
        vreme: v,
        installationId: ids.installationId,
        hardwareId: ids.hardwareId,
        logTag: _tag,
        log: debugPrint,
      );

      _setRunning(true);
      try {
        await _syncEngines(immediateTick: true);
      } catch (e) {
        debugPrint('$_tag start: engine/tick greška, tracking ostaje aktivan: $e');
      }
      return V3TrackingStartResult.started;
    } catch (e) {
      debugPrint('$_tag start greška: $e');
      await stop();
      return V3TrackingStartResult.failed;
    } finally {
      _startInProgress = false;
    }
  }

  /// Resetuje samo lokalno stanje (bez prefs/BG) — za prekidane restore/start
  /// putanje gde sesija treba da ostane u prefs za sledeći pokušaj.
  void _clearLocalSessionState() {
    _vozacId = '';
    _datumIso = '';
    _grad = '';
    _vreme = '';
    _polazakAt = null;
    _startedAt = null;
    _lastTickAt = null;
    _optimizedPutnikIds.clear();
    v3SetStandstillSeconds(0);
    _setRunning(false);
  }

  Future<void> _resetLocalSessionFields() async {
    _clearLocalSessionState();
    await v3ClearBgTrackingSession();
    await _stopBg();
  }

  Future<void> stop() async {
    if (_stopInProgress) return;
    _stopInProgress = true;
    debugPrint('$_tag stop()');
    try {
      _startInProgress = false;
      if (_vozacId.isNotEmpty) {
        _lastStoppedSessionKey = '$_datumIso|$_grad|$_vreme';
        _lastStoppedAt = DateTime.now();
      }
      _vozacId = '';
      _datumIso = '';
      _grad = '';
      _vreme = '';
      _polazakAt = null;
      _startedAt = null;
      _lastTickAt = null;
      _optimizedPutnikIds.clear();
      _noSlotStrikes = 0;
      v3SetStandstillSeconds(0);
      _setRunning(false);

      _fgTicker?.cancel();
      _fgTicker = null;
      await _stopIosLocationKeepAlive();
      await v3ClearBgTrackingSession();
      await _stopBg();

      // ETA se NE briše ovde. Poslednji red ostaje putniku do:
      // pokupljen / otkazan / retention 55min (edge + cleanup cron).
    } finally {
      _stopInProgress = false;
    }
  }

  /// Jednokratni GPS+ETA (UI resume / reoptimizacija).
  Future<({Map<String, int> etaMap, List<String> order, String? reason})> fetchPositionAndComputeEta() async {
    if (_vozacId.isEmpty) {
      return (etaMap: <String, int>{}, order: List<String>.from(_optimizedPutnikIds), reason: null);
    }
    try {
      return await _runTick();
    } catch (e) {
      debugPrint('$_tag fetchPositionAndComputeEta error: $e');
      return (etaMap: <String, int>{}, order: List<String>.from(_optimizedPutnikIds), reason: null);
    }
  }

  void _startFgTicker() {
    _fgTicker?.cancel();
    _fgTicker = V3SelfReschedulingTicker(interval: v3TrackingTickInterval, onTick: _fgTick)..start();
  }

  /// iOS: continuous CLLocationManager — sprečava suspend tokom vožnje.
  void _startIosLocationKeepAlive() {
    if (!Platform.isIOS || !_isRunning) return;
    if (_iosKeepAliveSub != null) return;

    debugPrint('$_tag iOS location keep-alive start');
    _iosKeepAliveSub = Geolocator.getPositionStream(
      locationSettings: v3IosBackgroundStreamSettings,
    ).listen(
      (position) {
        if (!_isRunning) return;
        final last = _lastTickAt;
        if (last != null && DateTime.now().difference(last) < v3TrackingTickInterval) {
          return;
        }
        unawaited(_fgTick());
      },
      onError: (Object e) {
        debugPrint('$_tag iOS location stream error: $e');
      },
      cancelOnError: false,
    );
  }

  Future<void> _stopIosLocationKeepAlive() async {
    if (_iosKeepAliveSub == null) return;
    await _iosKeepAliveSub!.cancel();
    _iosKeepAliveSub = null;
    debugPrint('$_tag iOS location keep-alive stop');
  }

  Future<({Map<String, int> etaMap, List<String> order, String? reason})> _runTick() async {
    final result = await v3RunTrackingTick(
      client: Supabase.instance.client,
      vozacId: _vozacId,
      grad: _grad,
      vreme: _vreme,
      datumIso: _datumIso,
      logTag: _tag,
    );
    _lastTickAt = DateTime.now();
    // Prazan odgovor (OSRM greška / no location) ne briše poslednji dobar redosled.
    if (result.order.isNotEmpty) {
      _optimizedPutnikIds
        ..clear()
        ..addAll(result.order);
    }
    if (!_etaTickController.isClosed) {
      _etaTickController.add(result);
    }
    return result;
  }

  DateTime? _lastFgAliveStamp;

  /// FG heartbeat u session prefs — BG watchdog iz njega zaključuje da je
  /// main isolate mrtav (app ugašena u FG pauzi) i nastavlja tickove.
  /// Throttle ~30s (watchdog jede na 60s; prag zastarelosti je 150s).
  Future<void> _stampFgAlive() async {
    final now = DateTime.now();
    final last = _lastFgAliveStamp;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) return;
    _lastFgAliveStamp = now;
    try {
      final saved = await v3LoadBgTrackingSession();
      if (saved == null) return;
      saved['fg_alive_at'] = now.toUtc().toIso8601String();
      await v3SaveBgTrackingSession(saved);
    } catch (_) {}
  }

  Future<void> _fgTick() async {
    if (!_isRunning || _tickInFlight || _vozacId.isEmpty) return;
    if (v3TrackingTimedOut(startedAt: _startedAt, polazakAt: _polazakAt)) {
      debugPrint('$_tag stop reason=timeout polazak=$_polazakAt');
      await stop();
      return;
    }

    _tickInFlight = true;
    try {
      unawaited(_stampFgAlive());
      final allDone = await v3AllPassengersCompleted(
        client: Supabase.instance.client,
        vozacId: _vozacId,
        datumIso: _datumIso,
        grad: _grad,
        vreme: _vreme,
      );
      if (allDone) {
        debugPrint('$_tag stop reason=all_passengers_completed');
        await stop();
        return;
      }
      final result = await _runTick();

      // Slot obrisan u hodu (admin) → edge vraća no_active_slot a
      // allPassengersCompleted ne može da dokaze "gotovo". Pre polaska je
      // no_active_slot legitiman (auto-prepare kasni), pa strikes brojimo
      // tek od polazka; posle ~60s konzistentnog odgovora gasimo (12 strikes
      // po tick-u — compute-eta ide na svaki tick).
      final postDeparture = _polazakAt == null || !V3BelgradeTime.now().isBefore(_polazakAt!);
      if (result.reason == 'no_active_slot' && postDeparture) {
        _noSlotStrikes++;
        if (_noSlotStrikes >= 12) {
          debugPrint('$_tag stop reason=no_active_slot strikes=$_noSlotStrikes');
          await stop();
          return;
        }
      } else {
        _noSlotStrikes = 0;
      }
    } catch (e) {
      debugPrint('$_tag tick error: $e');
    } finally {
      _tickInFlight = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_onResumed());
      return;
    }
    if (!_isRunning) return;

    switch (state) {
      case AppLifecycleState.inactive:
        // Kratki UI prekidi — ne diraj engine.
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_syncEngines(immediateTick: false));
        break;
      case AppLifecycleState.resumed:
        break;
    }
  }

  Future<void> _onResumed() async {
    if (!_isRunning) {
      final restored = await tryRestoreFromSession();
      if (!restored) return;
    }
    if (!_isRunning) return;

    if (v3TrackingTimedOut(startedAt: _startedAt, polazakAt: _polazakAt)) {
      debugPrint('$_tag stop reason=timeout_on_resume');
      await stop();
      return;
    }

    if (_vozacId.isNotEmpty && _datumIso.isNotEmpty && _grad.isNotEmpty && _vreme.isNotEmpty) {
      try {
        final allDone = await v3AllPassengersCompleted(
          client: Supabase.instance.client,
          vozacId: _vozacId,
          datumIso: _datumIso,
          grad: _grad,
          vreme: _vreme,
        );
        if (allDone) {
          debugPrint('$_tag stop reason=all_passengers_completed_on_resume');
          await stop();
          return;
        }
      } catch (e) {
        debugPrint('$_tag resume allDone check greška: $e');
      }
    }

    await _syncEngines(immediateTick: true);
  }

  int? _androidSdkInt;

  /// Android 12+ (API 31) zabranjuje start FGS iz pozadine; stariji smeju.
  Future<bool> _canStartFgsFromBackground() async {
    if (!Platform.isAndroid) return false;
    _androidSdkInt ??=
        await DeviceInfoPlugin().androidInfo.then((i) => i.version.sdkInt).catchError((_) => 0);
    return _androidSdkInt! < 31;
  }

  /// `gavra_bg_tracking` kanal mora postojati pre `startService()` — plugin
  /// prosleđeni channelId ne kreira sam, a cold-start restore može pobediti
  /// `_ensureLocalNotificationsInitialized` u main-u. Isti parametri kao tamo.
  Future<void> _ensureBgNotificationChannel() async {
    try {
      final androidImpl =
          _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          'gavra_bg_tracking',
          'Praćenje vožnje',
          description: 'Aktivno praćenje lokacije vozača u pozadini',
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
        ),
      );
    } catch (e) {
      debugPrint('$_tag BG channel greška: $e');
    }
  }

  /// startService() + verifikacija: na nekim OEM-ima FGS tiho propadne
  /// (startForeground izuzetak u nativnom delu) pa isRunning ostane false —
  /// tracking bi onda zamro bez ijedne greške. Retry jednom.
  Future<bool> _startBgServiceVerified() async {
    final service = FlutterBackgroundService();
    await _ensureBgNotificationChannel();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await service.startService();
      } catch (e) {
        debugPrint('$_tag startService greška (attempt ${attempt + 1}): $e');
      }
      for (var i = 0; i < 10; i++) {
        if (await service.isRunning()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      debugPrint('$_tag BG service nije podignut (attempt ${attempt + 1})');
    }
    debugPrint('$_tag BG service se nije podigao nakon 2 pokušaja');
    return false;
  }

  Future<void> _startBg() async {
    if (_vozacId.isEmpty || !_isRunning || Platform.isIOS) return;
    try {
      final payload = _sessionPayload(ticksPaused: false);
      await v3SaveBgTrackingSession(payload);

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        // Na API 31+ startService iz pozadine baca izuzetak — servis se
        // podiže na sledećem resume-u; sesija je već u prefs.
        if (!_isAppInForeground && !await _canStartFgsFromBackground()) return;
        if (!await _startBgServiceVerified()) return;
      }

      // servicePipe može dropovati event pre listenera — prefs je fallback.
      for (var i = 0; i < 4; i++) {
        service.invoke('startTracking', payload);
        await Future<void>.delayed(Duration(milliseconds: 200 + (i * 100)));
        if (await service.isRunning() && i >= 1) break;
      }
      debugPrint('$_tag BG startovan');
    } catch (e) {
      debugPrint('$_tag BG start greška: $e');
    }
  }

  Future<void> _ensureBgServiceRunning() async {
    if (_vozacId.isEmpty || !_isRunning || Platform.isIOS) return;
    try {
      await v3SaveBgTrackingSession(_sessionPayload(ticksPaused: _isAppInForeground));
      final service = FlutterBackgroundService();
      if (await service.isRunning()) return;
      if (!_isAppInForeground && !await _canStartFgsFromBackground()) return;
      await _startBgServiceVerified();
    } catch (e) {
      debugPrint('$_tag BG ensure greška: $e');
    }
  }

  Future<void> _pauseBgTicks() async {
    if (Platform.isIOS) return;
    try {
      final payload = _sessionPayload(ticksPaused: true);
      // BG isolate je vlasnik standstill brojača dok je on tickovao —
      // usvoji njegovu persist-ovanu vrednost da se kazna ne resetuje
      // na BG→FG prelazu.
      final saved = await v3LoadBgTrackingSession();
      final bgStandstill = (saved?['standstill_seconds'] as num?)?.toInt();
      if (bgStandstill != null) {
        payload['standstill_seconds'] = bgStandstill;
        v3SetStandstillSeconds(bgStandstill);
      }
      await v3SaveBgTrackingSession(payload);
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) return;
      // servicePipe može dropovati event — retry kao u _startBg, inače bi BG
      // ticker nastavio paralelno sa FG (dupli upis lokacije + dupli ETA).
      for (var i = 0; i < 3; i++) {
        service.invoke('pauseTicks');
        if (i < 2) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      debugPrint('$_tag BG pause greška: $e');
    }
  }

  Future<void> _cancelBgNotification() async {
    try {
      await _notifications.cancel(_bgNotificationId);
    } catch (e) {
      debugPrint('$_tag cancel BG notifikacije greška: $e');
    }
  }

  Future<void> _stopBg() async {
    if (Platform.isIOS) return;
    try {
      final service = FlutterBackgroundService();
      // Invoke bezuslovno: isRunning() može vratiti false dok se native
      // servis još diže (engine boot), a invoke je u tom slučaju no-op —
      // onStart će ionako videti obrisanu sesiju i sam uraditi stopSelf.
      service.invoke('stopService');
      if (await service.isRunning()) {
        for (var i = 0; i < 15; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!await service.isRunning()) {
            debugPrint('$_tag BG zaustavljen');
            break;
          }
        }
        if (await service.isRunning()) {
          debugPrint('$_tag BG još radi posle stopService — ponavljam');
          service.invoke('stopService');
        }
      }
    } catch (e) {
      debugPrint('$_tag BG stop greška: $e');
    }
    await _cancelBgNotification();
  }
}
