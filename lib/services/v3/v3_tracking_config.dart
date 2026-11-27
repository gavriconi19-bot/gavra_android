import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/v3_belgrade_time.dart';
import '../../utils/v3_status_policy.dart';
import '../realtime/v3_master_realtime_manager.dart';

/// Auto-start koliko pre polaska (T-15). Uskladiti sa `v3-auto-prepare-termins`.
const Duration v3AutoStartLeadTime = Duration(minutes: 15);

const Duration v3TrackingTickInterval = Duration(seconds: 5);

/// Maksimalna starost GPS fix-a koji sme u `v3_vozac_location` i ETA payload.
/// `getLastKnownPosition` fallback bez ovoga upisuje staru poziciju kao svežu
/// (updated_at=now) — otrovan admin prikaz i ETA.
const Duration v3TrackingMaxPositionAge = Duration(seconds: 30);

/// Sigurnosni hard-stop: tracking se gasi ovoliko posle polaska čak i ako
/// putnici ostanu nefinalizovani (stuck podatak) — inače bi FGS, GPS i
/// notifikacija radili neograničeno.
const Duration v3TrackingHardStop = Duration(hours: 3);

/// Spoljni timeout jednog tick-a (GPS + ETA).
const Duration v3TrackingTickTimeout = Duration(seconds: 90);

/// Client timeout za `v3-compute-eta`.
const Duration v3ComputeEtaNetworkTimeout = Duration(seconds: 65);

/// GPS settings za `getCurrentPosition` (tick).
///
/// iOS: Always + `allowBackgroundLocationUpdates` + automotive navigation —
/// inače OS suspenduje app i ETA zastari u pozadini.
/// Android: high accuracy + interval hint za FusedLocation.
LocationSettings get v3TrackingLocationSettings {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSettings(
      accuracy: LocationAccuracy.high,
      activityType: ActivityType.automotiveNavigation,
      distanceFilter: 0,
      pauseLocationUpdatesAutomatically: false,
      showBackgroundLocationIndicator: true,
      allowBackgroundLocationUpdates: true,
      timeLimit: const Duration(seconds: 12),
    );
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 3),
      timeLimit: const Duration(seconds: 12),
    );
  }
  return const LocationSettings(
    accuracy: LocationAccuracy.high,
    timeLimit: Duration(seconds: 12),
  );
}

/// iOS continuous stream — drži proces živim u pozadini (UIBackgroundModes=location).
/// `distanceFilter` smanjuje wake-upove; tick i dalje ide na [v3TrackingTickInterval] tajmeru / throttle.
LocationSettings get v3IosBackgroundStreamSettings {
  return AppleSettings(
    accuracy: LocationAccuracy.high,
    activityType: ActivityType.automotiveNavigation,
    distanceFilter: 25,
    pauseLocationUpdatesAutomatically: false,
    showBackgroundLocationIndicator: true,
    allowBackgroundLocationUpdates: true,
  );
}

/// Keep-alive stream settings — kontinuiran `requestLocationUpdates`.
///
/// Bez aktivnog kontinuiranog zahteva OS sa zaključanim ekranom duty-
/// cycluje GNSS pa one-shot `getCurrentPosition` (12s limit) završava u
/// timeout-u — `v3_vozac_location` se tada smrzava iako FGS + ticker rade
/// (14-22min tišine tokom vožnje, mereno). Stream drži GNSS budnim; tick
/// troši poslednji stream fix ako je svež, one-shot ostaje fallback.
/// Namerno bez `timeLimit` — taj parametar bi stream ugasio posle 12s.
LocationSettings get v3PositionKeepAliveSettings {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 2),
    );
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return v3IosBackgroundStreamSettings;
  }
  return const LocationSettings(accuracy: LocationAccuracy.high);
}

StreamSubscription<Position>? _positionKeepAliveSub;
Position? _lastKeepAlivePosition;

/// Pokreće keep-alive position stream (idempotentno). Pozivati u isolate-u
/// koji radi tickove (Android: FGS BG isolate; iOS ga ne treba — tamo već
/// postoji keep-alive u main isolate-u).
void v3StartPositionKeepAlive({String logTag = '[v3KeepAlive]'}) {
  if (_positionKeepAliveSub != null) return;
  _lastKeepAlivePosition = null;
  try {
    _positionKeepAliveSub = Geolocator.getPositionStream(
      locationSettings: v3PositionKeepAliveSettings,
    ).listen(
      (position) {
        _lastKeepAlivePosition = position;
      },
      onError: (Object e) {
        debugPrint('$logTag stream greška: $e');
      },
      cancelOnError: false,
    );
    debugPrint('$logTag stream startovan');
  } catch (e) {
    debugPrint('$logTag stream start greška: $e');
  }
}

void v3StopPositionKeepAlive({String logTag = '[v3KeepAlive]'}) {
  final sub = _positionKeepAliveSub;
  _positionKeepAliveSub = null;
  _lastKeepAlivePosition = null;
  if (sub != null) {
    unawaited(sub.cancel());
    debugPrint('$logTag stream zaustavljen');
  }
}

/// SharedPreferences ključ — BG isolate čita ovo ako `invoke(startTracking)` stigne pre listener-a.
const String v3BgTrackingSessionPrefsKey = 'v3_bg_tracking_session';

/// Snima aktivnu tracking sesiju da BG FGS može da je podigne bez race-a na invoke.
Future<void> v3SaveBgTrackingSession(Map<String, dynamic> session) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(v3BgTrackingSessionPrefsKey, jsonEncode(session));
  } catch (e) {
    debugPrint('[v3SaveBgTrackingSession] greška: $e');
  }
}

Future<Map<String, dynamic>?> v3LoadBgTrackingSession() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    // BG isolate često vidi stale snapshot dok se ne uradi reload.
    await prefs.reload();
    final raw = prefs.getString(v3BgTrackingSessionPrefsKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (e) {
    debugPrint('[v3LoadBgTrackingSession] greška: $e');
  }
  return null;
}

Future<void> v3ClearBgTrackingSession() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(v3BgTrackingSessionPrefsKey);
  } catch (e) {
    debugPrint('[v3ClearBgTrackingSession] greška: $e');
  }
}

/// Tracking sesija — jedini format zapisa u prefs (`v3_bg_tracking_session`)
/// i 'startTracking' invoke payload-u. Ranije ga je svaki pozivalac
/// parsirao rucno polje-po-polje (4 razlicita parsera); BG dijagnosticka
/// polja (`bg_*`) namerno nisu ovde — citaju se sirovim map-om.
class V3TrackingSession {
  const V3TrackingSession({
    required this.vozacId,
    required this.datumIso,
    required this.grad,
    required this.vreme,
    this.startedAt,
    this.polazakAt,
    this.ticksPaused = false,
    this.fgAliveAt,
  });

  final String vozacId;
  final String datumIso;
  final String grad;
  final String vreme;
  final DateTime? startedAt;
  final DateTime? polazakAt;
  final bool ticksPaused;
  final DateTime? fgAliveAt;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'vozac_id': vozacId,
        'datum_iso': datumIso,
        'grad': grad,
        'vreme': vreme,
        'started_at': startedAt?.toUtc().toIso8601String(),
        'polazak_at': polazakAt?.toUtc().toIso8601String(),
        'ticks_paused': ticksPaused,
        // FG heartbeat — BG watchdog iz zastarelog timestamp-a zakljucuje da
        // je main mrtav (app ugasena dok su BG tickovi pauzirani) i nastavlja
        // tickove; inace ticks_paused ostaje true zauvek i notifikacija laze.
        'fg_alive_at': fgAliveAt?.toUtc().toIso8601String(),
      };

  /// Parsira core polja; `null` ako identitet sesije nije kompletan.
  /// `polazakAt` fallback-uje na termin iz datum+vreme kao i raniji parseri.
  static V3TrackingSession? tryParse(Map<dynamic, dynamic>? m) {
    if (m == null) return null;
    final id = (m['vozac_id']?.toString() ?? '').trim();
    final datum = V3BelgradeTime.parseIsoDatePart(m['datum_iso']?.toString() ?? '');
    final g = (m['grad']?.toString() ?? '').trim().toUpperCase();
    final v = V3BelgradeTime.normalizeToHHmm(m['vreme']?.toString() ?? '');
    if (id.isEmpty || datum.isEmpty || g.isEmpty || v.isEmpty) return null;
    return V3TrackingSession(
      vozacId: id,
      datumIso: datum,
      grad: g,
      vreme: v,
      startedAt: V3BelgradeTime.parseTs(m['started_at']?.toString()),
      polazakAt: V3BelgradeTime.parseTs(m['polazak_at']?.toString()) ??
          v3PolazakDateTime(datumIso: datum, vreme: v),
      ticksPaused: m['ticks_paused'] == true,
      fgAliveAt: V3BelgradeTime.parseTs(m['fg_alive_at']?.toString()),
    );
  }
}

/// Upisuje jedno polje u aktivnu session mapu (load→set→save). BG isolate
/// tako stampuje `bg_tick_at`/`bg_last_error`/`bg_supabase_ok` — main ih
/// čita u supervisoru i usvaja kao remote dijagnostiku.
Future<void> v3SetBgSessionField(String key, Object? value) async {
  try {
    final saved = await v3LoadBgTrackingSession();
    if (saved == null) return;
    saved[key] = value;
    await v3SaveBgTrackingSession(saved);
  } catch (_) {}
}

/// Remote breadcrumb — retki događaji tracking lanca u `v3_tracking_debug`
/// (start/handoff/stall/fail — NE svaki tick). Best-effort: nikad ne baca,
/// 5s timeout; bez klijenta preskače (gubitak je samo dijagnostika).
Future<void> v3LogTrackingEvent({
  required String event,
  String? vozacId,
  SupabaseClient? client,
  Map<String, dynamic>? detail,
}) async {
  try {
    var c = client;
    if (c == null) {
      try {
        c = Supabase.instance.client;
      } catch (_) {
        c = null;
      }
    }
    if (c == null) return;
    await c.from('v3_tracking_debug').insert(<String, dynamic>{
      'v3_auth_id': vozacId,
      'event': event,
      if (detail != null) 'detail': detail,
    }).timeout(const Duration(seconds: 5));
  } catch (_) {}
}

/// Polazak termina u Europe/Belgrade (datum ISO + HH:mm).
DateTime? v3PolazakDateTime({required String datumIso, required String vreme}) {
  final datePart = V3BelgradeTime.parseIsoDatePart(datumIso);
  final parsedDate = V3BelgradeTime.parseDatum(datePart);
  if (parsedDate == null) return null;
  final hhmm = V3BelgradeTime.normalizeToHHmm(vreme);
  final parts = hhmm.split(':');
  if (parts.length < 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  return V3BelgradeTime.dateTime(
    parsedDate.year,
    parsedDate.month,
    parsedDate.day,
    hour,
    minute,
  );
}

/// Hard-stop: `true` kad prođe [v3TrackingHardStop] posle polaska (ili
/// [startedAt] kad polazak nedostaje). Primarni uslov gašenja ostaje
/// "svi putnici pokupljeni/otkazani" — ovo je samo sigurnosna mreža.
bool v3TrackingTimedOut({DateTime? startedAt, DateTime? polazakAt}) {
  final ref = polazakAt ?? startedAt;
  if (ref == null) return false;
  return V3BelgradeTime.now().isAfter(ref.add(v3TrackingHardStop));
}

/// Prozor se otvara na T-15 i zatvara na hard-stop ([v3TrackingHardStop]
/// posle polaska). Između te granice tracking živi dok ima aktivnih
/// putnika (proverava pozivalac preko `_terminHasActivePassengers` i sl.).
bool v3IsTrackingWindowOpen({required DateTime polazakAt, DateTime? now}) {
  final n = now ?? V3BelgradeTime.now();
  final start = polazakAt.subtract(v3AutoStartLeadTime);
  final end = polazakAt.add(v3TrackingHardStop);
  return !n.isBefore(start) && n.isBefore(end);
}

/// Sam-zakazujući tajmer — fiksni razmak [interval] između početaka tick-ova.
class V3SelfReschedulingTicker {
  V3SelfReschedulingTicker({
    required this.interval,
    required this.onTick,
    this.tickTimeout = v3TrackingTickTimeout,
  });

  final Duration interval;
  final Future<void> Function() onTick;
  final Duration tickTimeout;

  Timer? _timer;
  bool _cancelled = true;
  DateTime? _nextTickAt;

  void start() {
    cancel();
    _cancelled = false;
    _nextTickAt = DateTime.now();
    unawaited(_scheduleNext());
  }

  Future<void> _scheduleNext() async {
    try {
      await onTick().timeout(tickTimeout);
    } catch (e) {
      debugPrint('[V3SelfReschedulingTicker] tick greška/timeout: $e');
    }
    if (_cancelled) return;

    _nextTickAt = _nextTickAt!.add(interval);
    final now = DateTime.now();
    final delay = _nextTickAt!.isAfter(now) ? _nextTickAt!.difference(now) : Duration.zero;
    _timer = Timer(delay, () => unawaited(_scheduleNext()));
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    _nextTickAt = null;
  }
}

/// Operativni region (Bela Crkva / Vršac + okolina) — OSRM mapa pokriva samo
/// ovo područje, pa je pozicija van box-a loš GPS fix. Edge funkcija
/// (`v3-compute-eta`) primenjuje isti box; tick sa takvom pozicijom se
/// preskače (ne piše ni `v3_vozac_location`).
bool v3IsInOperatingRegion(double lat, double lng) {
  return lat >= 44.5 && lat <= 45.5 && lng >= 20.6 && lng <= 21.9;
}

/// Parsira odgovor edge funkcije `v3-compute-eta`.
///
/// Jednostavno: ok=true → etaMap (putnik_id → sekunde) + optimized_order.
/// ok=false / prazno → prazan rezultat (pozivalac zadržava prethodni order).
/// `reason` nosi edge razlog (`no_active_slot`, `fallback` razlozi...) ili
/// klijentski razlog ranog izlaska (`out_of_region`).
({Map<String, int> etaMap, List<String> order, String? reason}) v3ParseEtaResponse(dynamic data) {
  final etaMap = <String, int>{};
  final order = <String>[];
  if (data is! Map || data['ok'] != true) {
    final reason = data is Map ? data['reason']?.toString() : null;
    return (etaMap: etaMap, order: order, reason: reason);
  }

  final etaList = data['eta_results'];
  if (etaList is List) {
    for (final item in etaList) {
      if (item is! Map) continue;
      final pid = item['putnik_id']?.toString().trim() ?? '';
      final sec = (item['eta_seconds'] as num?)?.toInt();
      if (pid.isNotEmpty && sec != null) {
        etaMap[pid] = sec;
      }
    }
  }

  final optimizedOrder = data['optimized_order'];
  if (optimizedOrder is List) {
    for (final pid in optimizedOrder) {
      final s = pid?.toString().trim() ?? '';
      if (s.isNotEmpty) order.add(s);
    }
  }

  return (etaMap: etaMap, order: order, reason: data['reason']?.toString());
}

/// Jedan tick: live GPS fix + upsert `v3_vozac_location` + `v3-compute-eta`.
///
/// Trenutna GPS lokacija ide u tabelu i u payload edge funkcije (payload je
/// preferiran izvor da se izbegne race/clock na updated_at). Edge
/// `v3-compute-eta` se poziva na SVAKI tick — OSRM /trip reoptimizuje
/// preostale putnike sa sveže pozicije vozača.
/// Koriste ga i foreground servis i background isolate.
Future<({Map<String, int> etaMap, List<String> order, String? reason})> v3RunTrackingTick({
  required SupabaseClient client,
  required String vozacId,
  required String grad,
  required String vreme,
  required String datumIso,
  String logTag = '[v3RunTrackingTick]',
}) async {
  Position position;
  // Keep-alive stream (zaključan ekran): svež stream fix ima prednost — bez
  // njega one-shot getCurrentPosition na ugasenom ekranu zna da visi u
  // timeout-u jer OS nema aktivni kontinuiran GNSS zahtev.
  final streamed = _lastKeepAlivePosition;
  if (streamed != null &&
      DateTime.now().difference(streamed.timestamp).abs() <= v3TrackingMaxPositionAge) {
    position = streamed;
  } else {
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: v3TrackingLocationSettings,
      );
    } on TimeoutException {
      // GPS fix nije stigao na vreme (slab signal / cold start).
      // Fallback na poslednju poznatu poziciju umesto da tick potpuno propadne
      // — inače optimized_order ostaje "zamrznut" i novi putnici trajno
      // dobijaju OsrmIdx=999 dok se ne desi sledeći uspešan tick.
      // Timeout i ovde: zaglavljen method-channel poziv bi držao tickInFlight
      // zauvek (ticker timeout ne resetuje flag) — tracking bi se tiho smrzao.
      final last = await Geolocator.getLastKnownPosition().timeout(const Duration(seconds: 5));
      if (last == null) rethrow;
      debugPrint('$logTag getCurrentPosition timeout — koristim getLastKnownPosition fallback');
      position = last;
    }
  }

  // Stari fix (getLastKnownPosition može vratiti poziciju od pre nekoliko
  // minuta): ne sme ni u tabelu (admin mapa bi je video kao svežu) ni u ETA
  // payload (edge payload-u veruje bezuslovno). Bolje preskočiti tick nego
  // računati ETA na lažnoj poziciji.
  if (DateTime.now().difference(position.timestamp) > v3TrackingMaxPositionAge) {
    debugPrint(
      '$logTag pozicija prestara ${DateTime.now().difference(position.timestamp).inSeconds}s — tick preskočen',
    );
    return (etaMap: <String, int>{}, order: <String>[], reason: 'stale_position');
  }

  // Loš fix van operativnog regiona ne sme ni u tabelu ni u ETA — OSRM mapa
  // ne pokriva to područje, a `v3_vozac_location` bi dobila otrovane podatke.
  if (!v3IsInOperatingRegion(position.latitude, position.longitude)) {
    debugPrint(
      '$logTag pozicija van regiona ${position.latitude},${position.longitude} — tick preskočen',
    );
    return (etaMap: <String, int>{}, order: <String>[], reason: 'out_of_region');
  }

  // Mora uspeti pre compute-eta — inače edge bi računao na staroj lokaciji.
  // Timeout: half-open TCP (prelazak mreže u vožnji) bi bez njega držao
  // tickInFlight zauvek — svi sledeći tick-ovi bi se tiho preskakali.
  await v3UpdateVozacLocation(
    client: client,
    vozacId: vozacId,
    lat: position.latitude,
    lng: position.longitude,
    // Geolocator: m/s; negativno = invalid.
    speedKmh: position.speed >= 0 ? position.speed * 3.6 : null,
    logTag: logTag,
  ).timeout(const Duration(seconds: 15));

  // lat/lng u payload-u: edge preferira ovo nad čitanjem tabele (isti tick).
  final requestBody = <String, dynamic>{
    'vozac_id': vozacId,
    'grad': grad,
    'vreme': vreme,
    'lat': position.latitude,
    'lng': position.longitude,
    if (datumIso.isNotEmpty) 'datum_iso': datumIso,
  };
  debugPrint('$logTag computeEta request: $requestBody');

  final response =
      await client.functions.invoke('v3-compute-eta', body: requestBody).timeout(v3ComputeEtaNetworkTimeout);
  debugPrint('$logTag computeEta response status=${response.status} data=${response.data}');

  final parsed = v3ParseEtaResponse(response.data);
  if (parsed.etaMap.isEmpty) {
    final data = response.data;
    final reason = data is Map ? data['reason']?.toString() : null;
    final ok = data is Map ? data['ok'] : null;
    final warning = data is Map ? data['warning']?.toString() : null;
    final fallback = data is Map ? data['fallback'] : null;
    debugPrint('$logTag computeEta empty etaMap ok=$ok reason=$reason warning=$warning fallback=$fallback');
  }
  return parsed;
}

/// `true` samo ako ovaj vozač nema više aktivnih putnika na terminu (pokupljeni/otkazani).
/// Jedan vozač po slotu — sve dodele na slotu su njegove.
Future<bool> v3AllPassengersCompleted({
  required SupabaseClient client,
  required String vozacId,
  required String datumIso,
  required String grad,
  required String vreme,
}) async {
  final id = vozacId.trim();
  if (id.isEmpty || datumIso.isEmpty || grad.isEmpty || vreme.isEmpty) return false;

  // Main: cache iz master managera. BG isolate → null → DB fallback.
  try {
    final cached = V3MasterRealtimeManager.instance.tryAllPassengersCompleted(
      datumIso: datumIso,
      grad: grad,
      vreme: vreme,
      vozacId: id,
    );
    if (cached != null) return cached;
  } catch (_) {}

  try {
    // Timeout: zaglavljen REST poziv (half-open TCP pri prelasku mreže) bi bez
    // njega držao tickInFlight zauvek — tracking bi se tiho smrzao. `false`
    // = "ne dokazuje kraj" = tracking nastavlja (isti fail-safe kao catch).
    return await _v3AllPassengersCompletedDb(
      client: client,
      vozacId: id,
      datumIso: datumIso,
      grad: grad,
      vreme: vreme,
    ).timeout(const Duration(seconds: 20), onTimeout: () {
      debugPrint('[v3AllPassengersCompleted] DB timeout — ne dokazuje kraj');
      return false;
    });
  } catch (e) {
    debugPrint('[v3AllPassengersCompleted] greška: $e');
    return false;
  }
}

/// DB deo [v3AllPassengersCompleted] — poziva se pod timeout-om.
Future<bool> _v3AllPassengersCompletedDb({
  required SupabaseClient client,
  required String vozacId,
  required String datumIso,
  required String grad,
  required String vreme,
}) async {
  final id = vozacId.trim();
  try {
    // Isto kao edge: datum+grad, pa match HH:mm (DB može biti 07:00 ili
    // 07:00:00). Svih fizičkih duplikata — dodele mogu biti na bilo kom.
    final slotRows = await client
        .from('v3_trenutna_dodela_slot')
        .select('id, vreme, vozac_v3_auth_id')
        .eq('datum', datumIso)
        .eq('grad', grad);

    final wantVreme = V3BelgradeTime.normalizeToHHmm(vreme);
    final matchingSlots = <Map<String, dynamic>>[];
    for (final raw in (slotRows as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      if (V3BelgradeTime.normalizeToHHmm(row['vreme']?.toString()) == wantVreme) {
        matchingSlots.add(row);
      }
    }
    if (matchingSlots.isEmpty) return false;

    final slotIds = matchingSlots
        .map((s) => s['id']?.toString() ?? '')
        .where((sid) => sid.isNotEmpty)
        .toList();
    if (slotIds.isEmpty) return false;

    final dodelaRows = await client
        .from('v3_trenutna_dodela')
        .select('termin_id, vozac_v3_auth_id')
        .inFilter('slot_id', slotIds);

    final slotTerminIds = <String>{};
    for (final raw in (dodelaRows as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final tid = row['termin_id']?.toString() ?? '';
      if (tid.isEmpty) continue;
      if ((row['vozac_v3_auth_id']?.toString() ?? '').trim() == id) {
        slotTerminIds.add(tid);
      }
    }

    if (slotTerminIds.isEmpty) {
      // Prazna dodela ≠ svi gotovi: dodele mogu kasniti (auto-prepare race u
      // T-15 prozoru). Gasi samo kad tracking nema šta da radi:
      //  - nijedan fizički slot nije dodeljen ovom vozaču (transfer), ili
      //  - termin nema aktivnih putnika.
      // Inače bi stop → auto-start → stop pravilo petlju.
      final slotIsMine = matchingSlots
          .any((s) => (s['vozac_v3_auth_id']?.toString() ?? '').trim() == id);
      if (!slotIsMine) return true;
      return !(await _v3TerminHasActivePassengers(
        client: client,
        datumIso: datumIso,
        grad: grad,
        wantVreme: wantVreme,
      ));
    }

    final rows = await client
        .from('v3_operativna_nedelja')
        .select('id, pokupljen_at, otkazano_at')
        .inFilter('id', slotTerminIds.toList());

    if (rows.isEmpty) return false;

    for (final row in rows) {
      final pokupljen = V3StatusPolicy.isTimestampSet(row['pokupljen_at']);
      final otkazan = V3StatusPolicy.isTimestampSet(row['otkazano_at']);
      if (!pokupljen && !otkazan) return false;
    }
    return true;
  } catch (e) {
    debugPrint('[v3AllPassengersCompleted] greška: $e');
    return false;
  }
}

/// Ima li termin (datum+grad+vreme) bar jednog aktivnog putnika — isti
/// kriterijum kao `V3VozacScreen._terminHasActivePassengers`, ali direktno
/// iz baze (BG isolate nema realtime cache). Jedan vozač po slotu — svi
/// aktivni putnici termina pripadaju vozaču slota.
Future<bool> _v3TerminHasActivePassengers({
  required SupabaseClient client,
  required String datumIso,
  required String grad,
  required String wantVreme,
}) async {
  try {
    // `status` ne postoji na operativna_nedelja — select sa njom pada (400) i
    // pogrešno "dokazuje" da putnika nema. Aktivnost = nije pokupljen/otkazan.
    // Server-side datum filter: bez njega upit vuče celu nedelju za grad i
    // PostgREST max_rows=1000 može tiho odseći redove baš ovog termina.
    final rows = await client
        .from('v3_operativna_nedelja')
        .select('id, datum, polazak_at, pokupljen_at, otkazano_at')
        .eq('grad', grad)
        .eq('datum', datumIso);

    for (final raw in (rows as List<dynamic>? ?? const [])) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      if (V3BelgradeTime.parseIsoDatePart(row['datum']?.toString() ?? '') != datumIso) continue;
      if (V3BelgradeTime.normalizeToHHmm(row['polazak_at']?.toString()) != wantVreme) continue;
      final terminId = row['id']?.toString() ?? '';
      if (terminId.isEmpty) continue;
      final active = V3StatusPolicy.canAssign(
        otkazanoAt: row['otkazano_at'],
        pokupljenAt: row['pokupljen_at'],
      );
      if (active) return true;
    }
    return false;
  } catch (e) {
    // Fail-safe: greška u proveri ne sme da "dokaže" prazan termin — pozivalac
    // negira rezultat u allDone pa bi tracking pogrešno stao (lock/BG kill).
    debugPrint('[_v3TerminHasActivePassengers] greška: $e');
    return true;
  }
}

/// Rezultat provere GPS + Always dozvole pre starta trackinga.
enum V3LocationPrereqResult {
  ok,
  gpsDisabled,
  denied,
  deniedForever,
  alwaysRequired,
}

/// `ok` samo ako je GPS uključen i dozvola **Always** (Android + iOS).
///
/// WhenInUse nije dovoljno za background ETA.
/// Request UI je isključivo u [V3RolePermissionService] (permission_handler) —
/// ovde samo gate (check), bez drugog request dijaloga.
Future<V3LocationPrereqResult> v3CheckLocationPrerequisites() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    debugPrint('[v3CheckLocationPrerequisites] GPS isključen');
    return V3LocationPrereqResult.gpsDisabled;
  }

  final permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    return V3LocationPrereqResult.denied;
  }
  if (permission == LocationPermission.deniedForever) {
    return V3LocationPrereqResult.deniedForever;
  }
  if (permission != LocationPermission.always) {
    debugPrint('[v3CheckLocationPrerequisites] treba Always, ima: $permission');
    return V3LocationPrereqResult.alwaysRequired;
  }

  return V3LocationPrereqResult.ok;
}

Future<void> v3UpdateVozacLocation({
  required SupabaseClient client,
  required String vozacId,
  required double lat,
  required double lng,
  double? speedKmh,
  String logTag = '[v3UpdateVozacLocation]',
}) async {
  if (vozacId.isEmpty) {
    throw StateError('$logTag empty vozacId');
  }

  final updatedAt = V3BelgradeTime.nowIsoUtc();
  // Zaokruži na 1 decimalu radi čitljivog UI-a; null ostaje null.
  final speed = speedKmh == null ? null : double.parse(speedKmh.clamp(0, 300).toStringAsFixed(1));
  await client.from('v3_vozac_location').upsert(<String, dynamic>{
    'vozac_id': vozacId,
    'lat': lat,
    'lng': lng,
    'speed_kmh': speed,
    'updated_at': updatedAt,
  });
  try {
    V3MasterRealtimeManager.instance.applyLocalVozacLocation(
      vozacId: vozacId,
      lat: lat,
      lng: lng,
      speedKmh: speed,
      updatedAtIso: updatedAt,
    );
  } catch (_) {}
  debugPrint('$logTag lokacija $lat, $lng speed=$speed km/h vozac=$vozacId');
}
