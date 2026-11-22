import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../globals.dart';
import '../../models/v3_uplata_pazara.dart';
import '../../utils/v3_belgrade_time.dart';
import '../../utils/v3_status_policy.dart';
import '../v3/v3_address_coordinate_service.dart';
import '../v3/v3_app_settings_state.dart';
import '../v3/v3_app_update_service.dart';
import '../v3/v3_finansije_service.dart';
import '../v3/v3_operativna_nedelja_service.dart';
import '../v3/v3_uplata_pazara_service.dart';
import '../v3/v3_vozac_service.dart';
import 'engine/v3_bootstrap_loader.dart';
import 'engine/v3_cache_persistence.dart';
import 'engine/v3_cache_store.dart';
import 'engine/v3_event_bus.dart';
import 'engine/v3_table_registry.dart';
import 'repositories/v3_realtime_bootstrap_repository.dart';

class V3PazarPromptEvent {
  final DateTime datum;
  final double ukupno;
  final double predao;
  final bool naknadnaNaplataDetektovana;

  const V3PazarPromptEvent({
    required this.datum,
    required this.ukupno,
    this.predao = 0,
    this.naknadnaNaplataDetektovana = false,
  });
}

class _V3PendingPazarEntry {
  final DateTime datum;
  final double ukupno;
  final double predao;

  const _V3PendingPazarEntry({
    required this.datum,
    required this.ukupno,
    this.predao = 0,
  });
}

/// V3MasterRealtimeManager - Centralized cache and realtime manager for v3 tables.
class V3MasterRealtimeManager {
  V3MasterRealtimeManager._internal();
  static final V3MasterRealtimeManager _instance =
      V3MasterRealtimeManager._internal();
  static V3MasterRealtimeManager get instance => _instance;
  static final V3RealtimeBootstrapRepository _bootstrapRepository =
      V3RealtimeBootstrapRepository();

  static final DateTime _defaultPazarPolicyStartDate =
      V3BelgradeTime.dateTime(2026, 9, 4);
  static const int _pazarDailyTriggerHour = 16;
  static const int _pazarDailyTriggerMinute = 30;
  static const double _pazarIznosEps = 0.009;
  static const Duration _pazarAutoCheckInterval = Duration(minutes: 1);

  final V3CacheStore _cacheStore = V3CacheStore();
  final V3EventBus _eventBus = V3EventBus();
  late final V3BootstrapLoader _bootstrapLoader =
      V3BootstrapLoader(repository: _bootstrapRepository);
  bool _cacheStoreRegistered = false;

  // --- REALTIME ---
  RealtimeChannel? _channel;
  int _reconnectAttempts = 0;
  bool _isSubscribing = false;
  bool _hasConnectedBefore = false;
  DateTime? _lastSubscribedAt;
  AppLifecycleListener? _lifecycleListener;
  Future<void>? _resumeReconnectInFlight;
  DateTime? _lastResumeReconnectAt;
  static const Duration _resumeReconnectCooldown = Duration(seconds: 3);
  Future<void>? _fullResyncInFlight;
  DateTime? _lastFullResyncAt;
  static const Duration _fullResyncCooldown = Duration(seconds: 20);
  int _deltaResyncFailures = 0;
  static const int _maxDeltaResyncFailuresBeforeFull = 3;
  // Periodičan full resync — delta resync ne može da detektuje DELETE-ove
  // propustene dok je kanal bio down (red više ne postoji u bazi), pa bi
  // cache zadržao fantomske redove do restarta appa.
  Timer? _periodicFullResyncTimer;
  static const Duration _periodicFullResyncInterval = Duration(minutes: 30);
  // Posle dužeg disconnecta preskačemo delta i idemo direktno na full resync.
  static const Duration _fullResyncStaleThreshold = Duration(minutes: 15);
  // Perzistirani keš stariji od ovoga se smatra zastarelim → cold start ide
  // na full bootstrap umesto delta. 12h pokriva tipično "app ubijena
  // preko noci" — delta i dalje vazi za kratke kill/restart cikluse.
  static const Duration _persistedCacheStaleThreshold = Duration(hours: 12);

  final StreamController<V3PazarPromptEvent> _pazarPromptController =
      StreamController<V3PazarPromptEvent>.broadcast();
  StreamSubscription<int>? _pazarRevisionSub;
  StreamSubscription<int>? _pazarFinansijeRevisionSub;
  Timer? _pazarAutoCheckTimer;
  bool _pazarMonitoringStarted = false;
  int _pazarMonitoringSubscribers = 0;
  bool _pazarCheckInFlight = false;

  // --- IN-MEMORY CACHE ---
  final Map<String, Map<String, dynamic>> adreseCache = {};
  final Map<String, Map<String, dynamic>> authCache = {};
  final Map<String, Map<String, dynamic>> vozaciCache = {};
  final Map<String, Map<String, dynamic>> vozilaCache = {};
  final Map<String, Map<String, dynamic>> putniciCache = {};
  final Map<String, Map<String, dynamic>> zahteviCache = {};
  final Map<String, Map<String, dynamic>> gorivoCache = {};
  final Map<String, Map<String, dynamic>> finansijeCache = {};
  final Map<String, Map<String, dynamic>> kreditiCache = {};
  final Map<String, Map<String, dynamic>> racuniCache = {};
  final Map<String, Map<String, dynamic>> uplataPazaraCache = {};
  final Map<String, Map<String, dynamic>> trenutnaDodelaCache = {};
  final Map<String, Map<String, dynamic>> trenutnaDodelaSlotCache = {};
  final Map<String, Map<String, dynamic>> operativnaNedeljaCache = {};
  final Map<String, Map<String, dynamic>> kapacitetSlotsCache = {};
  final Map<String, Map<String, dynamic>> appSettingsCache = {};
  final Map<String, Map<String, dynamic>> operativnaAssignedCache = {};
  final Map<String, Map<String, dynamic>> etaResultsCache = {};
  final Map<String, Map<String, dynamic>> vozacLocationCache = {};

  void _rebuildAssignedCacheFromOperativna() {
    operativnaAssignedCache.clear();
    for (final entry in operativnaNedeljaCache.values) {
      final id = entry['id']?.toString();
      if (id == null) continue;

      final row = Map<String, dynamic>.from(entry);
      row['vreme'] = row['vreme'] ?? row['polazak_at'];
      row['polazak_vreme'] = row['polazak_at'];
      operativnaAssignedCache[id] = row;
    }
  }

  /// Primenjuje vrednosti iz v3_app_settings na globalne notifiere
  void _applyAppSettings(Map<String, dynamic> row) {
    // rasporedi polazaka
    List<String> _toList(dynamic val) {
      if (val == null) return [];
      if (val is List) return val.map((e) => e.toString()).toList();
      return [];
    }

    Map<String, List<String>> _toCustomByDay(dynamic val) {
      final result = {
        for (final day in V3DanHelper.workdayNames) day: <String>[],
      };
      if (val is! Map) return result;

      for (final entry in val.entries) {
        final normalizedDay =
            V3DanHelper.normalizeToWorkdayFull(entry.key.toString());
        if (normalizedDay.isEmpty) continue;
        result[normalizedDay] = _toList(entry.value);
      }

      return result;
    }

    final customByDayUpdated = {
      'bc': Map<String, List<String>>.from(
          customRasporedByDayNotifier.value['bc'] ?? {}),
      'vs': Map<String, List<String>>.from(
          customRasporedByDayNotifier.value['vs'] ?? {}),
    };
    bool customByDayChanged = false;

    if (row.containsKey('bc_custom_by_day')) {
      customByDayUpdated['bc'] = _toCustomByDay(row['bc_custom_by_day']);
      customByDayChanged = true;
    }
    if (row.containsKey('vs_custom_by_day')) {
      customByDayUpdated['vs'] = _toCustomByDay(row['vs_custom_by_day']);
      customByDayChanged = true;
    }

    if (customByDayChanged) {
      customRasporedByDayNotifier.value = customByDayUpdated;
    }

    if (row.containsKey('neradni_dani')) {
      applyNeradniDaniFromSettings(row['neradni_dani']);
    }

    if (row.containsKey('info_banner')) {
      applyInfoBannerFromSettings(row['info_banner']);
    }

    if (row.containsKey('active_week_start')) {
      // DATE kolona — parseDatum (kalendar), nikad parseTs / zona telefona.
      final awsParsed = V3BelgradeTime.parseDatum(row['active_week_start']);
      if (awsParsed != null) {
        V3AppSettingsState.instance.setActiveWeekStart(awsParsed);
      } else {
        debugPrint(
            '[V3MasterRealtimeManager] active_week_start je nevažeći, zadržavam postojeću vrednost.');
      }
    }

    if (row.containsKey('active_week_end')) {
      final aweParsed = V3BelgradeTime.parseDatum(row['active_week_end']);
      if (aweParsed != null) {
        V3AppSettingsState.instance.setActiveWeekEnd(aweParsed);
      } else {
        debugPrint(
            '[V3MasterRealtimeManager] active_week_end je nevažeći, zadržavam postojeću vrednost.');
      }
    }

    if (row.containsKey('pazar_policy_start_date')) {
      final pazarStartParsed =
          V3BelgradeTime.parseDatum(row['pazar_policy_start_date']);
      if (pazarStartParsed != null) {
        V3AppSettingsState.instance.setPazarPolicyStartDate(pazarStartParsed);
      } else {
        debugPrint(
            '[V3MasterRealtimeManager] pazar_policy_start_date je nevažeći, zadržavam postojeću vrednost.');
      }
    }

    if (row.containsKey('here_wego_install_url_android')) {
      V3AppSettingsState.instance.setHereWegoInstallUrlAndroid(
        row['here_wego_install_url_android']?.toString(),
      );
    }
    if (row.containsKey('here_wego_install_url_ios')) {
      V3AppSettingsState.instance.setHereWegoInstallUrlIos(
        row['here_wego_install_url_ios']?.toString(),
      );
    }
    if (row.containsKey('maps_app_url_template_android')) {
      V3AppSettingsState.instance.setMapsAppUrlTemplateAndroid(
        row['maps_app_url_template_android']?.toString(),
      );
    }
    if (row.containsKey('maps_app_url_template_ios')) {
      V3AppSettingsState.instance.setMapsAppUrlTemplateIos(
        row['maps_app_url_template_ios']?.toString(),
      );
    }

    unawaited(
      V3AppUpdateService.refreshUpdateInfo(appSettingsRow: row).catchError(
          (Object e) => debugPrint(
              '[V3MasterRealtimeManager] app update info error: $e')),
    );
  }

  Stream<Map<String, int>> get onRevisions => _eventBus.onRevisions;

  Future<void>? _initInFlight;
  bool _isInitialized = false;

  /// Non-null dok pozadinski load sekundarnih (teških) tabela traje.
  /// Kod koji mora da zna da li su sekundarne stigle (npr. debt-gate na
  /// putnik profilu — finansije stižu posle kritične faze) ga await-uje
  /// sa kratkim timeout-om.
  Future<void>? _secondaryInFlight;
  Future<void>? get secondaryInFlight => _secondaryInFlight;

  void _scheduleEmit({Set<String>? tables, bool immediate = false}) {
    _markPersistDirty();
    _eventBus.scheduleEmit(
      tables: tables,
      immediate: immediate,
      revisions: _cacheStore.revisionsSnapshot(),
    );
  }

  // --- PERSISTED CACHE ---
  // Keš se snima debounce-ovano tokom rada (da cold start ima svežu tačku
  // za delta sync) i odmah na app pause. Ako app bude ubijen pre snimanja,
  // sledeći cold start prosto povuče malo veći delta — ispravnost ne pati.
  Timer? _persistDebounceTimer;
  bool _persistInFlight = false;
  bool _persistPending = false;
  static const Duration _persistDebounce = Duration(seconds: 30);

  void _markPersistDirty() {
    if (_persistDebounceTimer?.isActive ?? false) return;
    _persistDebounceTimer = Timer(_persistDebounce, () {
      unawaited(_persistCachesNow());
    });
  }

  Future<void> _persistCachesNow() async {
    if (_persistInFlight) {
      _persistPending = true;
      return;
    }
    _persistInFlight = true;
    try {
      final snapshot = <String, Map<String, Map<String, dynamic>>>{};
      for (final config in V3RealtimeTableRegistry.defaults) {
        final table = _cacheStore.table(config.name);
        if (table.isNotEmpty) {
          snapshot[config.name] =
              Map<String, Map<String, dynamic>>.from(table);
        }
      }
      if (snapshot.isNotEmpty) {
        await V3CachePersistence.instance.save(snapshot);
      }
    } finally {
      _persistInFlight = false;
      if (_persistPending) {
        _persistPending = false;
        _markPersistDirty();
      }
    }
  }

  void _registerCacheStoreIfNeeded() {
    if (_cacheStoreRegistered) return;

    _cacheStore.registerTable('v3_adrese', adreseCache);
    _cacheStore.registerTable('v3_auth', authCache);
    _cacheStore.registerTable('v3_vozila', vozilaCache);
    _cacheStore.registerTable('v3_zahtevi', zahteviCache);
    _cacheStore.registerTable('v3_gorivo', gorivoCache);
    _cacheStore.registerTable('v3_finansije', finansijeCache);
    _cacheStore.registerTable('v3_krediti', kreditiCache);
    _cacheStore.registerTable('v3_uplata_pazara', uplataPazaraCache);
    _cacheStore.registerTable('v3_racuni', racuniCache);
    _cacheStore.registerTable('v3_trenutna_dodela', trenutnaDodelaCache);
    _cacheStore.registerTable(
        'v3_trenutna_dodela_slot', trenutnaDodelaSlotCache);
    _cacheStore.registerTable('v3_operativna_nedelja', operativnaNedeljaCache);
    _cacheStore.registerTable('v3_kapacitet_slots', kapacitetSlotsCache);
    _cacheStore.registerTable('v3_app_settings', appSettingsCache);
    _cacheStore.registerTable(
        'v3_operativna_assigned', operativnaAssignedCache);
    _cacheStore.registerTable('v3_eta_results', etaResultsCache);
    _cacheStore.registerTable('v3_vozac_location', vozacLocationCache);

    _cacheStoreRegistered = true;
  }

  void _rebuildRoleCachesFromAuth() {
    vozaciCache
      ..clear()
      ..addAll(
        {
          for (final row in authCache.values)
            if ((row['tip']?.toString().trim().toLowerCase() ?? '') == 'vozac')
              (row['id']?.toString() ?? ''): <String, dynamic>{
                'id': row['id'],
                'ime_prezime': row['ime'],
                'telefon_1': row['telefon'],
                'telefon_2': row['telefon_2'],
                'boja': row['boja'],
                'push_token': row['push_token'],
                'push_token_2': row['push_token_2'],
                'push_token_3': row['push_token_3'],
                'push_token_hms': row['push_token_hms'],
                'push_token_hms_2': row['push_token_hms_2'],
                'push_token_hms_3': row['push_token_hms_3'],
                'pin_hash': row['pin_hash'],
                'uloga': row['uloga'],
                'created_at': row['created_at'],
                'updated_at': row['updated_at'],
              }
        }..removeWhere((key, value) => key.isEmpty),
      );

    putniciCache
      ..clear()
      ..addAll(
        {
          for (final row in authCache.values)
            if ((row['tip']?.toString().trim().toLowerCase() ?? '')
                    .isNotEmpty &&
                (row['tip']?.toString().trim().toLowerCase() ?? '') != 'vozac')
              (row['id']?.toString() ?? ''): <String, dynamic>{
                'id': row['id'],
                'ime_prezime': row['ime'],
                'telefon_1': row['telefon'],
                'telefon_2': row['telefon_2'],
                'tip_putnika': row['tip'],
                'adresa_bc_id': row['adresa_primary_bc_id'],
                'adresa_vs_id': row['adresa_primary_vs_id'],
                'adresa_bc_id_2': row['adresa_secondary_bc_id'],
                'adresa_vs_id_2': row['adresa_secondary_vs_id'],
                'cena_po_danu': row['cena_po_danu'],
                'cena_po_pokupljenju': row['cena_po_pokupljenju'],
                'push_token': row['push_token'],
                'push_token_2': row['push_token_2'],
                'push_token_3': row['push_token_3'],
                'push_token_hms': row['push_token_hms'],
                'push_token_hms_2': row['push_token_hms_2'],
                'push_token_hms_3': row['push_token_hms_3'],
                'pin_hash': row['pin_hash'],
                'created_at': row['created_at'],
                'updated_at': row['updated_at'],
                'last_seen_at': row['last_seen_at'],
                'last_seen_at_2': row['last_seen_at_2'],
                'last_seen_at_3': row['last_seen_at_3'],
              }
        }..removeWhere((key, value) => key.isEmpty),
      );
  }

  Future<void> initV3() async {
    if (_isInitialized) return;
    if (_initInFlight != null) {
      await _initInFlight;
      return;
    }

    _initInFlight = _initV3Internal();
    try {
      await _initInFlight;
    } finally {
      _initInFlight = null;
    }
  }

  Future<void> _initV3Internal() async {
    debugPrint('[V3MasterRealtimeManager] ⚡ STARTED initV3()');
    if (!isSupabaseReady) {
      debugPrint(
          '[V3MasterRealtimeManager] Supabase nije spreman, preskačem initV3.');
      return;
    }
    try {
      _lifecycleListener ??= AppLifecycleListener(
        onResume: () {
          unawaited(_handleAppResume());
        },
        onPause: () {
          unawaited(_persistCachesNow());
        },
      );

      _registerCacheStoreIfNeeded();

      // 1) Perzistirani keš sa diska → UI renderuje odmah, pre mreže.
      var restoredFresh = false;
      final persisted = await V3CachePersistence.instance.load();
      if (persisted != null && persisted.tables.isNotEmpty) {
        _applyPersistedCaches(persisted.tables);
        final savedAt = persisted.savedAt;
        restoredFresh = savedAt != null &&
            V3BelgradeTime.now().difference(savedAt) <
                _persistedCacheStaleThreshold;
        _scheduleEmit(tables: {'*'}, immediate: true);
        debugPrint(
            '[V3MasterRealtimeManager] disk cache restored (fresh=$restoredFresh)');
      }

      // 2) Svež keš → delta; prazan/zastareo → kritični full bootstrap.
      var needSecondary = true;
      if (restoredFresh) {
        needSecondary = !(await _applyMissedDelta());
      }
      if (needSecondary) {
        await _loadInitialCachesWithRetry();
      }
      _lastFullResyncAt = V3BelgradeTime.now();

      await _setupRealtime();
      _periodicFullResyncTimer ??= Timer.periodic(
        _periodicFullResyncInterval,
        (_) => unawaited(_runFullResync('periodic')),
      );
      _isInitialized = true;
      _scheduleEmit(tables: {'*'}, immediate: true);

      // 3) Teške sekundarne tabele u pozadini — ekrani su već renderovani.
      //    Na delta putanju delta već pokriva sve tabele pa ovo nije potrebno.
      if (needSecondary) {
        final op = _loadSecondaryCaches().catchError((Object e) => debugPrint(
            '[V3MasterRealtimeManager] secondary load error: $e'));
        _secondaryInFlight = op;
        unawaited(op.whenComplete(() {
          if (identical(_secondaryInFlight, op)) _secondaryInFlight = null;
        }));
      }
      unawaited(_persistCachesNow());
      // Pre-geocodiramo koordinate gradova u pozadini — bez blokiranja bootstrapa.
      // Time se izbjegava Nominatim poziv pri prvom kliku na Start/Mapa.
      unawaited(
        V3AddressCoordinateService.instance.warmUpCities().catchError(
            (Object e) =>
                debugPrint('[V3MasterRealtimeManager] warmUpCities error: $e')),
      );
      debugPrint('[V3MasterRealtimeManager] Initialized successfully');
    } catch (e) {
      debugPrint('[V3MasterRealtimeManager] Initialization error: $e');
      rethrow;
    }
  }

  Future<void> _setupRealtime() async {
    if (!isSupabaseReady) {
      debugPrint('[RT] Supabase nije spreman, preskačem setupRealtime.');
      return;
    }

    if (_isSubscribing) {
      debugPrint('[RT] setupRealtime već u toku, preskačem paralelni poziv.');
      return;
    }

    _registerCacheStoreIfNeeded();

    final existing = _channel;
    _channel = null;
    if (existing != null) {
      try {
        await supabase.removeChannel(existing);
      } catch (e) {
        debugPrint('[RT] removeChannel warning: $e');
      }
    }

    final channel = supabase.channel('v3_realtime_all');
    for (final config in V3RealtimeTableRegistry.defaults) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: config.name,
        callback: (payload) {
          _onTablePayload(config: config, payload: payload);
        },
      );
    }

    _channel = channel;
    _isSubscribing = true;

    channel.subscribe((status, [error]) {
      if (_channel != channel) {
        return;
      }
      _isSubscribing = false;
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          _lastSubscribedAt = V3BelgradeTime.now();
          final isFirstSubscribe = !_hasConnectedBefore;
          _reconnectAttempts = 0;
          debugPrint(
              '[RT] subscribed (hasConnectedBefore=$_hasConnectedBefore)');
          if (isFirstSubscribe) {
            _hasConnectedBefore = true;
            _scheduleEmit(tables: {'*'}, immediate: true);
            unawaited(_applyMissedDelta().then((_) {}));
          } else {
            unawaited(_resyncCachesAfterReconnectSmart());
          }
          break;
        case RealtimeSubscribeStatus.channelError:
          debugPrint('[RT] channelError: $error');
          unawaited(_scheduleReconnect());
          break;
        case RealtimeSubscribeStatus.timedOut:
          debugPrint('[RT] timedOut');
          unawaited(_scheduleReconnect());
          break;
        case RealtimeSubscribeStatus.closed:
          debugPrint('[RT] closed');
          unawaited(_scheduleReconnect());
          break;
      }
    });
  }

  Future<void> _resyncCachesAfterReconnectSmart() async {
    // Delta ne može da vrati DELETE-ove propustene dok je kanal bio down —
    // posle dužeg disconnecta idemo direktno na full resync.
    final lastFull = _lastFullResyncAt;
    if (lastFull != null &&
        V3BelgradeTime.now().difference(lastFull) >=
            _fullResyncStaleThreshold) {
      await _runFullResync('reconnect-stale');
      _deltaResyncFailures = 0;
      return;
    }

    final deltaOk = await _applyMissedDelta();
    if (deltaOk) {
      _deltaResyncFailures = 0;
      return;
    }

    _deltaResyncFailures += 1;
    debugPrint(
        '[RT] reconnect → delta sync failed ($_deltaResyncFailures/$_maxDeltaResyncFailuresBeforeFull)');

    if (_deltaResyncFailures < _maxDeltaResyncFailuresBeforeFull) {
      return;
    }

    await _runFullResync('reconnect-delta-failures');
  }

  Future<void> _runFullResync(String reason) async {
    final inFlight = _fullResyncInFlight;
    if (inFlight != null) {
      debugPrint('[RT] $reason full-resync već u toku, preskačem dupli poziv');
      return;
    }

    final now = V3BelgradeTime.now();
    final lastRun = _lastFullResyncAt;
    final canRunFullResync =
        lastRun == null || now.difference(lastRun) >= _fullResyncCooldown;
    if (!canRunFullResync) {
      debugPrint('[RT] $reason full-resync cooldown aktivan, preskačem.');
      return;
    }

    final operation = _resyncCachesAfterReconnect();
    _fullResyncInFlight = operation;
    try {
      await operation;
      _lastFullResyncAt = V3BelgradeTime.now();
      _deltaResyncFailures = 0;
    } finally {
      if (identical(_fullResyncInFlight, operation)) {
        _fullResyncInFlight = null;
      }
    }
  }

  Future<void> _handleAppResume() async {
    if (!isSupabaseReady) return;

    if (!_isInitialized) {
      debugPrint('[RT] app resumed → initV3 retry (not initialized yet)');
      await initV3();
      return;
    }

    final now = V3BelgradeTime.now();
    final lastRun = _lastResumeReconnectAt;
    if (lastRun != null && now.difference(lastRun) < _resumeReconnectCooldown) {
      debugPrint('[RT] app resumed → reconnect cooldown aktivan, preskačem.');
      return;
    }

    final inFlight = _resumeReconnectInFlight;
    if (inFlight != null) {
      debugPrint('[RT] app resumed → reconnect već u toku, preskačem.');
      return;
    }

    _lastResumeReconnectAt = now;
    final operation = _setupRealtime();
    _resumeReconnectInFlight = operation;
    debugPrint('[RT] app resumed → reconnect + missed delta');

    try {
      await operation;
    } finally {
      if (identical(_resumeReconnectInFlight, operation)) {
        _resumeReconnectInFlight = null;
      }
    }
  }

  Future<void> _resyncCachesAfterReconnect() async {
    debugPrint('[RT] reconnect → full cache resync');
    try {
      final results = await _bootstrapLoader.loadFull();
      _applyBootstrapResults(results);
      _scheduleEmit(tables: {'*'}, immediate: true);
      debugPrint('[RT] reconnect resync → completed');
    } catch (e) {
      debugPrint('[RT] reconnect resync error: $e');
      await _applyMissedDelta();
    }
  }

  Future<void> _loadInitialCachesWithRetry({int maxAttempts = 3}) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final results = await _bootstrapLoader.loadCritical();
        _applyBootstrapResults(results);
        return;
      } catch (e) {
        lastError = e;
        if (attempt >= maxAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      }
    }
    throw StateError(
        'Bootstrap init failed after $maxAttempts attempts: $lastError');
  }

  /// Sekundarne (teške) tabele — fetchuje ih initV3 u pozadini posle
  /// kritične faze. Rezultat se emituje kao nova revizija, pa ekrani koji
  /// slušaju revision stream sami rebuild-uju kad podaci stignu.
  Future<void> _loadSecondaryCaches({int maxAttempts = 3}) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final results = await _bootstrapLoader.loadSecondary();
        _applyBootstrapResults(results);
        // Dovuci redove koji su se promenili dok je secondary fetch leteo —
        // realtime eventi upisani u cache između snapshot-a i replaceAll bi
        // inače bili pregazeni starijim stanjem.
        await _applyMissedDelta();
        _scheduleEmit(tables: {'*'}, immediate: true);
        _markPersistDirty();
        return;
      } catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
        }
      }
    }
    debugPrint(
        '[V3MasterRealtimeManager] secondary load failed after $maxAttempts attempts: $lastError');
  }

  /// Primena parcijalnog bootstrap rezultata — dira SAMO tabele prisutne
  /// u [results] (ostale keševe ne sme da očisti).
  void _applyBootstrapResults(Map<String, List<dynamic>> results) {
    for (final entry in results.entries) {
      final normalizedRows = _normalizeRowsForTable(entry.key, entry.value);
      _cacheStore.replaceAll(entry.key, normalizedRows);
    }

    _rebuildRoleCachesFromAuth();
    _rebuildAssignedCacheFromOperativna();

    final globalSettings = appSettingsCache['global'];
    if (globalSettings != null) _applyAppSettings(globalSettings);
  }

  void _applyPersistedCaches(
      Map<String, Map<String, Map<String, dynamic>>> tables) {
    for (final entry in tables.entries) {
      final rows = _normalizeRowsForTable(
          entry.key, entry.value.values.toList(growable: false));
      _cacheStore.replaceAll(entry.key, rows);
    }

    _rebuildRoleCachesFromAuth();
    _rebuildAssignedCacheFromOperativna();

    final globalSettings = appSettingsCache['global'];
    if (globalSettings != null) _applyAppSettings(globalSettings);
  }

  bool _isScheduleReconnectRunning = false;

  Future<void> _scheduleReconnect() async {
    if (_isSubscribing || _isScheduleReconnectRunning) return;
    _isScheduleReconnectRunning = true;
    final scheduledAt = V3BelgradeTime.now();
    try {
      _reconnectAttempts += 1;
      final cappedAttempt = _reconnectAttempts > 6 ? 6 : _reconnectAttempts;
      final baseMs = 500 * (1 << cappedAttempt);
      final jitter = Random().nextInt(250);
      await Future<void>.delayed(
          Duration(milliseconds: (baseMs + jitter).toInt()));

      if (_isSubscribing) return;

      final recoveredAt = _lastSubscribedAt;
      if (recoveredAt != null && recoveredAt.isAfter(scheduledAt)) {
        debugPrint('[RT] reconnect skipped (already recovered)');
        return;
      }

      try {
        await _setupRealtime();
      } catch (e) {
        debugPrint('[RT] reconnect error: $e');
      }
    } finally {
      _isScheduleReconnectRunning = false;
    }
  }

  Future<bool> _applyMissedDelta() async {
    debugPrint('[RT] _applyMissedDelta → pulling missed rows...');
    try {
      final watermarks = {
        for (final t in V3RealtimeTableRegistry.defaults)
          t.name: _cacheStore.watermark(t.name),
      };
      final deltas = await _bootstrapLoader.loadDeltaAll(watermarks);
      if (deltas.isEmpty) {
        debugPrint('[RT] _applyMissedDelta → nema izmena');
        return true;
      }
      for (final entry in deltas.entries) {
        final config = V3RealtimeTableRegistry.defaults
            .firstWhere((t) => t.name == entry.key);
        for (final row in entry.value) {
          final normalized = _normalizeRowForTable(entry.key, row);
          _cacheStore.applyDeltaRow(
            table: entry.key,
            row: normalized,
          );
        }
        for (final hook in config.hooks) {
          switch (hook) {
            case V3RealtimeHook.rebuildAssignedCache:
              _rebuildAssignedCacheFromOperativna();
              break;
            case V3RealtimeHook.applyGlobalAppSettings:
              final globalRow = appSettingsCache['global'];
              if (globalRow != null) _applyAppSettings(globalRow);
              break;
          }
        }
        if (config.name == 'v3_auth') _rebuildRoleCachesFromAuth();
      }
      debugPrint('[RT] _applyMissedDelta → applied ${deltas.length} tabela');
      _scheduleEmit(tables: {'*'}, immediate: true);
      return true;
    } catch (e) {
      debugPrint('[RT] _applyMissedDelta error: $e');
      return false;
    }
  }

  void _onTablePayload({
    required V3RealtimeTableConfig config,
    required PostgresChangePayload payload,
  }) {
    final normalizedNew = _normalizeRowForTable(config.name, payload.newRecord);
    final normalizedOld = _normalizeRowForTable(config.name, payload.oldRecord);

    final changed = _cacheStore.applyRealtimeMutation(
      table: config.name,
      newRecord: normalizedNew,
      oldRecord: normalizedOld,
      isDelete: payload.eventType == PostgresChangeEvent.delete,
    );

    if (!changed) return;

    final id = (payload.newRecord['id'] ?? payload.oldRecord['id'])?.toString();

    for (final hook in config.hooks) {
      switch (hook) {
        case V3RealtimeHook.rebuildAssignedCache:
          _rebuildAssignedCacheFromOperativna();
          break;
        case V3RealtimeHook.applyGlobalAppSettings:
          if (id == 'global') {
            _applyAppSettings(payload.newRecord);
          }
          break;
      }
    }

    if (config.name == 'v3_auth') {
      _rebuildRoleCachesFromAuth();
    }

    if (config.name == 'v3_operativna_nedelja' &&
        payload.eventType != PostgresChangeEvent.delete &&
        payload.newRecord.isNotEmpty) {
      unawaited(
        V3OperativnaNedeljaService.syncTerminDodelaFromSlotForRow(
          operativnaRow: normalizedNew,
        ).catchError(
          (Object e) => debugPrint('[RT] syncTerminDodela error: $e'),
        ),
      );
    }

    final affected = <String>{config.name, ...config.dependsOn};
    _scheduleEmit(tables: affected);
  }

  Stream<T> v3StreamFromRevisions<T>(
      {required List<String> tables, required T Function() build}) {
    final normalized = tables
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);

    return Stream<T>.multi(
      (controller) {
        controller.add(build());
        final sub = tablesRevisionStream(normalized).listen(
          (_) => controller.add(build()),
          onError: controller.addError,
        );
        controller.onCancel = sub.cancel;
      },
      isBroadcast: true,
    );
  }

  Stream<int> tableRevisionStream(String table) {
    final normalized = table.trim();
    return Stream<int>.multi(
      (controller) {
        controller.add(_cacheStore.revision(normalized));
        final sub = onRevisions
            .map((snapshot) =>
                snapshot[normalized] ?? _cacheStore.revision(normalized))
            .distinct()
            .listen(
              controller.add,
              onError: controller.addError,
            );
        controller.onCancel = sub.cancel;
      },
      isBroadcast: true,
    ).distinct();
  }

  Stream<int> tablesRevisionStream(List<String> tables) {
    final normalized = tables
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (normalized.isEmpty) {
      return onRevisions.map((_) => 0).distinct();
    }

    int buildHashFromSnapshot(Map<String, int>? snapshot) {
      var hash = 17;
      for (final table in normalized) {
        final revision = snapshot?[table] ?? _cacheStore.revision(table);
        hash = (hash * 31) ^ revision;
      }
      return hash;
    }

    return Stream<int>.multi(
      (controller) {
        controller.add(buildHashFromSnapshot(null));
        final sub = onRevisions.map(buildHashFromSnapshot).distinct().listen(
              controller.add,
              onError: controller.addError,
            );
        controller.onCancel = sub.cancel;
      },
      isBroadcast: true,
    ).distinct();
  }

  void v3UpsertToCache(String table, Map<String, dynamic> row) {
    final normalizedRow = _normalizeRowForTable(table, row);

    // Kompozitni / specijalni ključevi — nema standardne 'id' kolone.
    if (table != 'v3_eta_results' && table != 'v3_vozac_location') {
      final id = normalizedRow['id']?.toString();
      if (id == null) return;
    }

    _cacheStore.upsert(table, normalizedRow);

    switch (table) {
      case 'v3_auth':
        _rebuildRoleCachesFromAuth();
        break;
      case 'v3_operativna_nedelja':
        _rebuildAssignedCacheFromOperativna();
        break;
      case 'v3_app_settings':
        if (normalizedRow['id']?.toString() == 'global') {
          _applyAppSettings(normalizedRow);
        }
        break;
    }

    _scheduleEmit(tables: {table});
  }

  void v3RemoveFromCache(String table, String id) {
    if (id.isEmpty) return;
    _cacheStore.remove(table, id);

    if (table == 'v3_auth') {
      _rebuildRoleCachesFromAuth();
    }

    _scheduleEmit(tables: {table});
  }

  Map<String, dynamic> _normalizeRowForTable(
      String table, Map<String, dynamic> row) {
    if (row.isEmpty) return row;
    final normalized = Map<String, dynamic>.from(row);

    if (table == 'v3_trenutna_dodela') {
      final fallbackId = normalized['termin_id']?.toString();
      final currentId = normalized['id']?.toString();
      if ((currentId == null || currentId.isEmpty) &&
          fallbackId != null &&
          fallbackId.isNotEmpty) {
        normalized['id'] = fallbackId;
      }
    }

    if (table == 'v3_vozac_location') {
      final vozacId = normalized['vozac_id']?.toString();
      if (vozacId != null && vozacId.isNotEmpty) {
        normalized['id'] = vozacId;
      }
    }

    return normalized;
  }

  List<dynamic> _normalizeRowsForTable(String table, List<dynamic> rows) {
    if (rows.isEmpty) return rows;
    return rows.map((row) {
      if (row is Map<String, dynamic>) {
        return _normalizeRowForTable(table, row);
      }
      return row;
    }).toList(growable: false);
  }

  Map<String, dynamic>? getPutnik(String id) => putniciCache[id];

  Stream<V3PazarPromptEvent> get pazarPromptStream =>
      _pazarPromptController.stream;

  void startPazarMonitoring() {
    _pazarMonitoringSubscribers++;
    if (_pazarMonitoringStarted) return;
    _pazarMonitoringStarted = true;

    debugPrint('[V3MasterRealtimeManager] pazar monitoring start');
    unawaited(_checkPazarForCurrentDriver());

    _pazarRevisionSub =
        tableRevisionStream('v3_uplata_pazara').listen((revision) {
      debugPrint('[V3MasterRealtimeManager] pazar revision=$revision');
      unawaited(_checkPazarForCurrentDriver());
    });

    _pazarFinansijeRevisionSub =
        tableRevisionStream('v3_finansije').listen((revision) {
      debugPrint('[V3MasterRealtimeManager] finansije revision hash=$revision');
      unawaited(_checkPazarForCurrentDriver());
    });

    _pazarAutoCheckTimer = Timer.periodic(_pazarAutoCheckInterval, (_) {
      unawaited(_checkPazarForCurrentDriver());
    });
  }

  void stopPazarMonitoring() {
    if (_pazarMonitoringSubscribers > 0) {
      _pazarMonitoringSubscribers--;
    }
    if (_pazarMonitoringSubscribers > 0) return;
    if (!_pazarMonitoringStarted) return;
    _pazarMonitoringStarted = false;
    _pazarRevisionSub?.cancel();
    _pazarRevisionSub = null;
    _pazarFinansijeRevisionSub?.cancel();
    _pazarFinansijeRevisionSub = null;
    _pazarAutoCheckTimer?.cancel();
    _pazarAutoCheckTimer = null;
    debugPrint('[V3MasterRealtimeManager] pazar monitoring stop');
  }

  bool _isPazarPolicyActiveFor(DateTime dayBelgrade) {
    final dayOnly = V3BelgradeTime.dateTime(
        dayBelgrade.year, dayBelgrade.month, dayBelgrade.day);
    final configuredStart =
        V3AppSettingsState.instance.pazarPolicyStartDateValue;
    final effectiveStart = configuredStart ?? _defaultPazarPolicyStartDate;
    return !dayOnly.isBefore(effectiveStart);
  }

  bool _isPazarDueFor(DateTime day, DateTime nowBelgrade) {
    final dueAt = V3BelgradeTime.dateTime(
      day.year,
      day.month,
      day.day,
      _pazarDailyTriggerHour,
      _pazarDailyTriggerMinute,
    );
    return !nowBelgrade.isBefore(dueAt);
  }

  /// Mesecni zapis iz baze, memoizovan po proveri. Baza je autoritativni izvor —
  /// cache se koristi samo kao hint za kandidate, a odluke se donose nad sveze
  /// procitanim stanjem da zastareli cache ne bi digao lazni popup ni prepisao
  /// upravo sacuvanu predaju.
  Future<V3UplataPazara?> _uplataZaMesec({
    required String vozacId,
    required DateTime day,
    required Map<String, V3UplataPazara?> memo,
  }) async {
    final key = '${day.year}-${day.month}';
    if (memo.containsKey(key)) return memo[key];

    final uplata = await V3UplataPazaraService.getZaVozacaIMesec(
      vozacId: vozacId,
      datum: day,
    );
    memo[key] = uplata;
    if (uplata != null) {
      v3UpsertToCache('v3_uplata_pazara', uplata.toJson());
    }
    return uplata;
  }

  /// Sinhronizuje zahtev za unos pazara za jedan dan i vraca pending zapis ako
  /// postoji. Upis delegira na [V3UplataPazaraService.syncZahtevanUnos] koji
  /// merge-uje na svezem stanju iz baze:
  ///  - nema zapisa: posle 16:30 kreira auto-zahtev (isti mehanizam radi i
  ///    backfill dana kada aplikacija nije bila pokrenuta posle 16:30)
  ///  - `zahtevan_unos=false` a pazar je porastao: reblokada (naknadna naplata
  ///    posle predaje)
  ///  - `ukupno` se osvezava u oba smera (ispravke/storna)
  Future<({_V3PendingPazarEntry? pending, bool naknadna})> _syncPazarZaDan({
    required String vozacId,
    required DateTime day,
    required DateTime nowBelgrade,
    required double trenutnoUkupno,
    required Map<String, V3UplataPazara?> mesecMemo,
  }) async {
    var uplata =
        await _uplataZaMesec(vozacId: vozacId, day: day, memo: mesecMemo);
    var dnevna = uplata?.uplataZaDan(day.day);
    var naknadna = false;

    final potrebanSync = dnevna == null
        ? _isPazarDueFor(day, nowBelgrade) && trenutnoUkupno > 0
        : (trenutnoUkupno - dnevna.ukupno).abs() > _pazarIznosEps;

    if (potrebanSync) {
      try {
        final res = await V3UplataPazaraService.syncZahtevanUnos(
          vozacId: vozacId,
          datum: day,
          ukupno: trenutnoUkupno,
        );
        if (res.uplata != null) {
          uplata = res.uplata;
          mesecMemo['${day.year}-${day.month}'] = uplata;
          v3UpsertToCache('v3_uplata_pazara', uplata!.toJson());
          dnevna = uplata.uplataZaDan(day.day);
          naknadna = res.bilaPredaja;
          debugPrint(res.bilaPredaja
              ? '[V3MasterRealtimeManager] reblokada pazara: detektovana naknadna naplata'
              : '[V3MasterRealtimeManager] sinhronizovan zahtev unosa za ${V3BelgradeTime.toIsoDate(day)}');
        }
      } catch (e) {
        debugPrint('[V3MasterRealtimeManager] pazar sync error: $e');
      }
    }

    if (dnevna != null && dnevna.zahtevanUnos == true && dnevna.ukupno > 0) {
      return (
        pending: _V3PendingPazarEntry(
          datum: day,
          ukupno: dnevna.ukupno,
          predao: dnevna.predao,
        ),
        naknadna: naknadna,
      );
    }
    return (pending: null, naknadna: naknadna);
  }

  Future<void> _checkPazarForCurrentDriver() async {
    if (!_pazarMonitoringStarted) return;
    if (_pazarCheckInFlight) return;
    _pazarCheckInFlight = true;

    try {
      final currentVozac = V3VozacService.currentVozac;
      final vozacId = currentVozac?.id;
      if (vozacId == null || vozacId.isEmpty) return;

      final now = V3BelgradeTime.now();
      final today = V3BelgradeTime.dateTime(now.year, now.month, now.day);
      if (!_isPazarPolicyActiveFor(today)) return;

      // Kandidati za sync: svi dani kada je vozac naplatio pazar (iz
      // finansija) + svi dani sa postojecim uplata zapisima. Nije ograniceno
      // lookback prozorom — backfill pokriva i dane kada aplikacija nije
      // bila pokrenuta posle 16:30.
      final pazarPoDanu = V3FinansijeService.getPazarPoVozacuPoDanima(vozacId);
      final kandidati = <String>{};
      pazarPoDanu.forEach((iso, iznos) {
        if (iznos > 0) kandidati.add(iso);
      });
      for (final row in uplataPazaraCache.values) {
        if ((row['vozac_id']?.toString() ?? '').trim() != vozacId) continue;
        final uplata = V3UplataPazara.fromJson(row);
        for (final dnevna in uplata.dnevneUplate) {
          kandidati.add(V3BelgradeTime.toIsoDate(
              DateTime(uplata.godina, uplata.mesec, dnevna.dan)));
        }
      }

      final mesecMemo = <String, V3UplataPazara?>{};
      _V3PendingPazarEntry? oldestPending;
      var oldestNaknadna = false;

      final sorted = kandidati.toList()..sort();
      for (final iso in sorted) {
        final parsed = V3BelgradeTime.parseDatum(iso);
        if (parsed == null) continue;
        final day =
            V3BelgradeTime.dateTime(parsed.year, parsed.month, parsed.day);
        if (day.isAfter(today)) continue;
        if (!_isPazarPolicyActiveFor(day)) continue;

        final result = await _syncPazarZaDan(
          vozacId: vozacId,
          day: day,
          nowBelgrade: now,
          trenutnoUkupno: pazarPoDanu[iso] ?? 0.0,
          mesecMemo: mesecMemo,
        );
        final pending = result.pending;
        if (pending != null &&
            (oldestPending == null ||
                pending.datum.isBefore(oldestPending.datum))) {
          oldestPending = pending;
          oldestNaknadna = result.naknadna;
        }
      }

      if (oldestPending != null) {
        // Verifikacija iz baze neposredno pre emitovanja — vozac ili drugi
        // uredjaj je mozda upravo zavrsio unos za ovaj dan.
        final fresh = await V3UplataPazaraService.getZaVozacaIMesec(
          vozacId: vozacId,
          datum: oldestPending.datum,
        );
        if (fresh != null) {
          v3UpsertToCache('v3_uplata_pazara', fresh.toJson());
        }
        final dnevna = fresh?.uplataZaDan(oldestPending.datum.day);
        if (dnevna != null &&
            dnevna.zahtevanUnos == true &&
            dnevna.ukupno > 0) {
          _pazarPromptController.add(
            V3PazarPromptEvent(
              datum: oldestPending.datum,
              ukupno: dnevna.ukupno,
              predao: dnevna.predao,
              naknadnaNaplataDetektovana: oldestNaknadna,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[V3MasterRealtimeManager] check pazar error: $e');
    } finally {
      _pazarCheckInFlight = false;
    }
  }

  Map<String, Map<String, dynamic>> getCache(String table) {
    switch (table) {
      case 'v3_adrese':
        return adreseCache;
      case 'v3_auth':
        return authCache;
      case 'v3_vozila':
        return vozilaCache;
      case 'v3_zahtevi':
        return zahteviCache;
      case 'v3_gorivo':
        return gorivoCache;
      case 'v3_finansije':
        return finansijeCache;
      case 'v3_krediti':
        return kreditiCache;
      case 'v3_uplata_pazara':
        return uplataPazaraCache;
      case 'v3_racuni':
        return racuniCache;
      case 'v3_trenutna_dodela':
        return trenutnaDodelaCache;
      case 'v3_trenutna_dodela_slot':
        return trenutnaDodelaSlotCache;
      case 'v3_operativna_nedelja':
        return operativnaNedeljaCache;
      case 'v3_kapacitet_slots':
        return kapacitetSlotsCache;
      case 'v3_app_settings':
        return appSettingsCache;
      case 'v3_operativna_assigned':
        return operativnaAssignedCache;
      case 'v3_eta_results':
        return etaResultsCache;
      case 'v3_vozac_location':
        return vozacLocationCache;
      default:
        return {};
    }
  }

  /// Lokalni upsert posle GPS tick-a (main isolate) — UI vidi lokaciju odmah,
  /// realtime potvrđuje sa drugih uređaja.
  void applyLocalVozacLocation({
    required String vozacId,
    required double lat,
    required double lng,
    double? speedKmh,
    String? updatedAtIso,
  }) {
    final id = vozacId.trim();
    if (id.isEmpty) return;
    _registerCacheStoreIfNeeded();
    v3UpsertToCache('v3_vozac_location', <String, dynamic>{
      'vozac_id': id,
      'lat': lat,
      'lng': lng,
      if (speedKmh != null) 'speed_kmh': speedKmh,
      'updated_at': updatedAtIso ?? V3BelgradeTime.nowIsoUtc(),
    });
  }

  /// `true`/`false` iz cache-a; `null` ako nema dovoljno podataka (BG isolate / prazan cache).
  /// Samo putnici ovog vozača na slotu (multi-driver safe).
  bool? tryAllPassengersCompleted({
    required String datumIso,
    required String grad,
    required String vreme,
    required String vozacId,
  }) {
    if (datumIso.isEmpty || grad.isEmpty || vreme.isEmpty) return false;
    final wantVozac = vozacId.trim();
    if (wantVozac.isEmpty) return false;
    if (trenutnaDodelaSlotCache.isEmpty) return null;

    final wantGrad = grad.trim().toUpperCase();
    final wantVreme = V3BelgradeTime.normalizeToHHmm(vreme);
    final wantDatum = V3BelgradeTime.parseIsoDatePart(datumIso);

    // Svi fizički duplikati slota (format vremena) — dodele mogu biti na
    // bilo kom, isto kao u edge funkciji.
    final matchingSlots = <Map<String, dynamic>>[];
    for (final row in trenutnaDodelaSlotCache.values) {
      final rowDatum =
          V3BelgradeTime.parseIsoDatePart(row['datum']?.toString() ?? '');
      final rowGrad = (row['grad']?.toString() ?? '').trim().toUpperCase();
      final rowVreme = V3BelgradeTime.normalizeToHHmm(row['vreme']?.toString());
      if (rowDatum == wantDatum &&
          rowGrad == wantGrad &&
          rowVreme == wantVreme) {
        matchingSlots.add(row);
      }
    }
    if (matchingSlots.isEmpty) return null;

    final slotIds = matchingSlots
        .map((s) => s['id']?.toString() ?? '')
        .where((sid) => sid.isNotEmpty)
        .toSet();
    if (slotIds.isEmpty) return null;

    if (trenutnaDodelaCache.isEmpty && operativnaNedeljaCache.isEmpty)
      return null;

    final terminIds = <String>{};
    final otherVozacTerminIds = <String>{};
    for (final row in trenutnaDodelaCache.values) {
      final rowSlotId = row['slot_id']?.toString() ?? '';
      if (!slotIds.contains(rowSlotId)) continue;
      final tid = row['termin_id']?.toString();
      if (tid == null || tid.isEmpty) continue;
      if ((row['vozac_v3_auth_id']?.toString() ?? '').trim() == wantVozac) {
        terminIds.add(tid);
      } else {
        otherVozacTerminIds.add(tid);
      }
    }
    if (terminIds.isEmpty) {
      // Prazna dodela ≠ svi gotovi (auto-prepare race) — isto kao DB put u
      // v3AllPassengersCompleted. Gasi kad ni jedan slot nije moj, ili kad
      // termin nema aktivnih putnika koji nisu tuđi.
      final slotIsMine = matchingSlots.any((s) =>
          (s['vozac_v3_auth_id']?.toString() ?? '').trim() == wantVozac);
      if (!slotIsMine) return true;
      if (operativnaNedeljaCache.isEmpty) return null;
      for (final row in operativnaNedeljaCache.values) {
        final rowDatum =
            V3BelgradeTime.parseIsoDatePart(row['datum']?.toString() ?? '');
        final rowGrad = (row['grad']?.toString() ?? '').trim().toUpperCase();
        final rowVreme =
            V3BelgradeTime.normalizeToHHmm(row['polazak_at']?.toString());
        if (rowDatum != wantDatum || rowGrad != wantGrad || rowVreme != wantVreme) {
          continue;
        }
        final tid = row['id']?.toString() ?? '';
        if (tid.isEmpty || otherVozacTerminIds.contains(tid)) continue;
        final active = V3StatusPolicy.canAssign(
          status: row['status']?.toString(),
          otkazanoAt: row['otkazano_at'],
          pokupljenAt: row['pokupljen_at'],
        );
        if (active) return false;
      }
      return true;
    }

    for (final tid in terminIds) {
      final op = operativnaNedeljaCache[tid] ?? operativnaAssignedCache[tid];
      if (op == null) return null;
      final pokupljen = V3StatusPolicy.isTimestampSet(op['pokupljen_at']);
      final otkazan = V3StatusPolicy.isTimestampSet(op['otkazano_at']);
      if (!pokupljen && !otkazan) return false;
    }
    return true;
  }
}
