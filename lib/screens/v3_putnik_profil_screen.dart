import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';

import '../globals.dart';
import '../l10n/app_translations.dart';
import '../models/v3_adresa.dart';
import '../models/v3_putnik.dart';
import '../services/realtime/v3_master_realtime_manager.dart';
import '../services/v3/v3_adresa_service.dart';
import '../services/v3/v3_closed_auth_service.dart';
import '../services/v3/v3_device_identity_service.dart';
import '../services/v3/v3_push_token_edge_service.dart';
import '../services/v3/v3_push_token_provider.dart';
import '../services/v3/v3_putnik_service.dart';
import '../services/v3/v3_putnik_statistika_service.dart';
import '../services/v3/v3_weather_service.dart';
import '../services/v3/v3_zahtev_service.dart';
import '../services/v3_locale_manager.dart';
import '../services/v3_theme_manager.dart';
import '../theme.dart';
import '../utils/v3_app_messages.dart';
import '../utils/v3_app_snack_bar.dart';
import '../utils/v3_belgrade_time.dart';
import '../utils/v3_button_utils.dart';
import '../utils/v3_container_utils.dart';
import '../utils/v3_dialog_helper.dart';
import '../utils/v3_error_utils.dart';
import '../utils/v3_input_utils.dart';
import '../utils/v3_navigation_utils.dart';
import '../utils/v3_phone_utils.dart';
import '../utils/v3_putnik_id_resolver.dart';
import '../utils/v3_safe_text.dart';
import '../utils/v3_state_utils.dart';
import '../utils/v3_status_policy.dart';
import '../utils/v3_stream_utils.dart';
import '../utils/v3_style_helper.dart';
import '../utils/v3_uuid_utils.dart';
import '../widgets/v3_fade_slide_in.dart';
import '../widgets/v3_info_banner.dart';
import '../widgets/v3_update_banner.dart';
import '../widgets/v3_vreme_dolaska_widget.dart';
import 'v3_putnik_statistika_screen.dart';
import 'v3_welcome_screen.dart';

// Prevodi za dijaloge izmene profila / promene PIN-a (SR/EN/RU/DE).
final Map<String, Map<String, String>> _profileDialogT = AppTranslations.ns('putnikProfilScreenProfileDialogT');

String _trProfileDialog(String key) {
  final code = V3LocaleManager().currentLocale.languageCode;
  return _profileDialogT[key]?[code] ?? _profileDialogT[key]?['sr'] ?? key;
}

class V3PutnikProfilScreen extends StatefulWidget {
  final Map<String, dynamic> putnikData;

  /// Da li je instanca profil ekrana trenutno u navigation stack-u.
  /// Sprečava da tap na uzastopne push notifikacije nagomila više instanci
  /// istog ekrana — sve koriste iste V3StreamUtils ključeve
  /// ('putnik_profil_cache'/'putnik_profil_fin'), pa bi se ekran ispod
  /// novog tiho prestao osvežavati dok drži svoje timere.
  static bool isOpen = false;

  const V3PutnikProfilScreen({super.key, required this.putnikData});
  @override
  State<V3PutnikProfilScreen> createState() => _V3PutnikProfilScreenState();
}

class _V3PutnikProfilScreenState extends State<V3PutnikProfilScreen> with WidgetsBindingObserver {
  static const String _giroRacun = '340-11436537-92';
  late Map<String, dynamic> _putnikData;
  // Operativni termini po danu
  // key = dan kratica npr 'pon', value = lista termina (BC i VS)
  final Map<String, List<_ZahtevInfo>> _rasporedMap = {};
  // Ključevi (putnikId|dan|grad) za koje je trenutno u toku slanje/otkazivanje
  // zahteva. Sprečava da brzi uzastopni klikovi (2-3 puta zaredom) kreiraju
  // više zahteva pre nego što prvi stigne da se upiše i osveži u kešu.
  final Set<String> _pendingActionContexts = {};
  // Aktivne ponude oslobođenih mesta (zahtevi status='odbijeno' + mesto_ponuda)
  // — prikazuju se kao banner sa Prihvati/Ne dugmadima, da putnik vidi ponudu
  // i kad push notifikacija ne stigne ili tapne telo notifikacije.
  List<Map<String, dynamic>> _aktivnePonude = [];
  // Zahtevi u statusu 'alternativa' — dispečer je ponudio 1-2 zamenska
  // termina (alternativa_pre_at/posle_at). Prikazuju se kao banner sa
  // izborom termina da putnik može da odgovori i kad push ne stigne.
  List<Map<String, dynamic>> _aktivneAlternative = [];
  final Set<String> _pendingPonudaZahtevi = {};
  Timer? _ponudaRefreshTimer;
  Timer? _refreshDebounceTimer;
  bool _timePickerOpen = false;
  Map<String, V3WeatherSnapshot> _weatherByGrad = const {};
  Timer? _weatherTimer;
  Timer? _weatherRetryTimer;
  int _weatherRetryCount = 0;

  static final RegExp _timeFormat = RegExp(r'^\d{2}:\d{2}$');

  /// Debounce ključ za akcije otkazivanja/sačuvaj u profilu.
  String get _actionDebounceKey {
    final putnikId = _currentPutnikId() ?? 'unknown';
    return 'putnik_profil_${putnikId}_action_debounce';
  }

  String? _currentPutnikId() {
    return V3PutnikIdResolver.fromPutnikData(_putnikData);
  }

  String _rowPutnikId(Map<String, dynamic> row) {
    return V3PutnikIdResolver.fromRow(row);
  }

  // Prevodi za profil ekran (SR/EN/RU/DE) — isti obrazac kao welcome screen.
  static final Map<String, Map<String, String>> _t = AppTranslations.ns('putnikProfilScreen');

  String _tr(String key) {
    final code = V3LocaleManager().currentLocale.languageCode;
    return _t[key]?[code] ?? _t[key]?['sr'] ?? key;
  }

  /// Prevodi puni srpski naziv dana (npr. 'Ponedeljak') u naziv na trenutnom jeziku, samo za prikaz.
  /// Interna logika (matchovanje rasporeda) i dalje koristi V3DanHelper.fullName na srpskom.
  String _trDanFullName(String srDanFullName) {
    const map = {
      'Ponedeljak': 'danPonedeljak',
      'Utorak': 'danUtorak',
      'Sreda': 'danSreda',
      'Cetvrtak': 'danCetvrtak',
      'Petak': 'danPetak',
      'Subota': 'danSubota',
      'Nedelja': 'danNedelja',
    };
    final key = map[srDanFullName];
    return key != null ? _tr(key) : srDanFullName;
  }

  String? _normalizeValidTime(String? value) {
    if (value == null) return null;
    final normalized = V3BelgradeTime.normalizeToHHmm(value).trim();
    if (normalized.isEmpty) return null;
    if (!_timeFormat.hasMatch(normalized)) return null;
    return normalized;
  }

  String _formatNedeljaOpsegLabel() {
    final weekRange = V3DanHelper.schedulingWeekRange();
    final ponedeljak = weekRange.start;
    final petak = weekRange.end;
    final od = '${ponedeljak.day.toString().padLeft(2, '0')}.${ponedeljak.month.toString().padLeft(2, '0')}.';
    final doDatuma = '${petak.day.toString().padLeft(2, '0')}.${petak.month.toString().padLeft(2, '0')}.';
    return '$od - $doDatuma';
  }

  // Memoizacija finansijskog obračuna — getUkupanDug*/getTekuciMesec rade
  // ~10 punih skenova finansije keša po mesecu istorije. Bez memoizacije se
  // to računalo na SVAKI build (a rebuild ide na svaki realtime revision
  // event — u smeni to znači stotine hiljada row-poseta po sekundi).
  String? _statsKey;
  V3PutnikMesecnaStatistika? _statsTekuci;
  double _statsUkupanDug = 0;
  double _statsUkupanVisak = 0;
  double _statsPrevMonthDebt = 0;
  List<V3PutnikDnevnaStavka> _statsDnevne = const [];

  ({
    V3PutnikMesecnaStatistika tekuci,
    double ukupanDug,
    double ukupanVisak,
    double prevMonthDebt,
    List<V3PutnikDnevnaStavka> dnevne,
  }) _profilStats(String? putnikId) {
    final rm = V3MasterRealtimeManager.instance;
    final now = V3BelgradeTime.now();
    // Ključ: putnik + revision-i tabela od kojih obračun zavisi + mesec
    // (da ekran ostavljen otvoren preko prelaska meseca ne pokazuje staro).
    final key = '${putnikId ?? ''}|fin:${rm.tableRevision('v3_finansije')}'
        '|auth:${rm.tableRevision('v3_auth')}|${now.year}-${now.month}';
    if (key != _statsKey || _statsTekuci == null) {
      final id = putnikId ?? '';
      _statsKey = key;
      _statsTekuci = V3PutnikStatistikaService.getTekuciMesec(id);
      _statsUkupanDug = V3PutnikStatistikaService.getUkupanDugZaSveMesece(id);
      _statsUkupanVisak = V3PutnikStatistikaService.getUkupanViskDoMeseca(
        putnikId: id,
        godina: now.year,
        mesec: now.month,
      );
      _statsPrevMonthDebt = _historicalDebtAmountUntilPreviousMonth(id);
      // Dnevne vožnje za mini-grafik — tip se resolve-uje iz keša u samom
      // servisu pa '' fallback nije problem.
      _statsDnevne = V3PutnikStatistikaService.getDnevneStavkeZaMesec(
        putnikId: id,
        godina: now.year,
        mesec: now.month,
        tipPutnika: '',
      );
    }
    return (
      tekuci: _statsTekuci!,
      ukupanDug: _statsUkupanDug,
      ukupanVisak: _statsUkupanVisak,
      prevMonthDebt: _statsPrevMonthDebt,
      dnevne: _statsDnevne,
    );
  }

  double _historicalDebtAmountUntilPreviousMonth(String putnikId) {
    final normalizedId = putnikId.trim();
    if (normalizedId.isEmpty) return 0;
    final now = V3BelgradeTime.now();
    final ukupniDugDoSada = V3PutnikStatistikaService.getUkupanDugDoMeseca(
      putnikId: normalizedId,
      godina: now.year,
      mesec: now.month,
    );
    final tekuciMesecObracun = V3PutnikStatistikaService.getMesecniObracun(
      putnikId: normalizedId,
      godina: now.year,
      mesec: now.month,
    );

    final istorijskiDug = (ukupniDugDoSada - tekuciMesecObracun.dug).clamp(0.0, double.infinity).toDouble();
    return istorijskiDug;
  }

  String _formatWholeRsd(double value) {
    final raw = value.toStringAsFixed(0);
    final isNegative = raw.startsWith('-');
    final digits = isNegative ? raw.substring(1) : raw;
    final grouped = digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
    return isNegative ? '-$grouped' : grouped;
  }

  Future<void> _showPreviousMonthDebtDialog(BuildContext ctx, {required double dugIznos}) async {
    final formatiranIznos = _formatWholeRsd(dugIznos);
    final content =
        '${V3PutnikProfilMessages.previousMonthDebtLocked(_giroRacun)}\n\n${V3PutnikProfilMessages.previousMonthDebtAmount(formatiranIznos)}';
    await V3DialogHelper.showBasicDialog<void>(
      context: ctx,
      title: V3PutnikProfilMessages.previousMonthDebtTitle,
      content: content,
      titleIcon: Icons.lock_outline,
      titleIconColor: Colors.orange,
      actions: [
        V3ButtonUtils.textButton(
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
          text: V3PutnikProfilMessages.close,
          foregroundColor: Colors.grey,
        ),
        V3ButtonUtils.textButton(
          onPressed: () {
            Clipboard.setData(const ClipboardData(text: _giroRacun));
            Navigator.of(ctx, rootNavigator: true).pop();
            if (mounted) {
              V3AppSnackBar.success(context, V3PutnikProfilMessages.giroAccountCopied);
            }
          },
          text: V3PutnikProfilMessages.copyGiroAccount,
          foregroundColor: Colors.amber,
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    V3PutnikProfilScreen.isOpen = true;
    _putnikData = Map<String, dynamic>.from(widget.putnikData);
    _refresh();
    _refreshWeather(forceRefresh: true);
    _weatherTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) _refreshWeather();
    });
    // Periodično osveži prikaz preostalog vremena aktivnih ponuda
    // (mesto + alternativa) — countdown i lokalni expiry bez realtime-a.
    _ponudaRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (_aktivnePonude.isNotEmpty || _aktivneAlternative.isNotEmpty)) _refresh();
    });
    // Pratimo promjene cache-a
    V3StreamUtils.subscribe<int>(
      key: 'putnik_profil_cache',
      stream: V3MasterRealtimeManager.instance.tablesRevisionStream(const [
        'v3_auth',
        'v3_zahtevi',
        'v3_operativna_nedelja',
        'v3_app_settings',
      ]),
      onData: (_) {
        if (mounted) _scheduleRefresh();
      },
    );
    // v3_finansije ne ulazi u _refresh (raspored ne zavisi od nje) — samo
    // setState da bi se memoizovani obračun reinvaldirao po revision-u.
    V3StreamUtils.subscribe<int>(
      key: 'putnik_profil_fin',
      stream: V3MasterRealtimeManager.instance.tablesRevisionStream(const [
        'v3_finansije',
      ]),
      onData: (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    V3PutnikProfilScreen.isOpen = false;
    WidgetsBinding.instance.removeObserver(this);
    V3StreamUtils.cancelSubscription('putnik_profil_cache');
    V3StreamUtils.cancelSubscription('putnik_profil_fin');
    V3StreamUtils.cancelTimer(_actionDebounceKey);
    _weatherTimer?.cancel();
    _weatherRetryTimer?.cancel();
    _ponudaRefreshTimer?.cancel();
    _refreshDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshWeather();
      _refresh();
    }
  }

  Future<void> _refreshWeather({bool forceRefresh = false}) async {
    final snapshots = await V3WeatherService.fetchBcVs(forceRefresh: forceRefresh);
    if (!mounted) return;
    if (snapshots.isNotEmpty) {
      V3StateUtils.safeSetState(this, () => _weatherByGrad = snapshots);
    }
    // Ako nedostaje neki grad (BC ili VS), verovatno je prvi pokušaj
    // pao usled slabe/spore mreže na hladnom startu - probaj ponovo uskoro
    // umesto da čekamo pun period od 15 minuta.
    final missing = const ['BC', 'VS'].any((g) => !_weatherByGrad.containsKey(g));
    if (missing && _weatherRetryCount < 5) {
      _weatherRetryCount++;
      _weatherRetryTimer?.cancel();
      _weatherRetryTimer = Timer(const Duration(seconds: 20), () {
        if (mounted) _refreshWeather(forceRefresh: true);
      });
    } else {
      _weatherRetryCount = 0;
    }
  }

  /// Pull-to-refresh — lokalni re-render + force-ovana weather provera +
  /// pametan resync (delta, full fallback) kroz realtime manager.
  Future<void> _pullRefresh() async {
    _refresh();
    unawaited(_refreshWeather(forceRefresh: true));
    try {
      await V3MasterRealtimeManager.instance
          .requestManualResync()
          .timeout(const Duration(seconds: 10), onTimeout: () {});
    } catch (_) {}
    if (mounted) _refresh();
  }

  /// Da li je kritična faza bootstrap-a stigla — dok ne stigne, ispod
  /// header-a prikazujemo skeleton umesto rasporeda sa "➕ dodaj" ćelijama
  /// (na cold start bez disk keša izgledalo je kao da nema termina).
  bool get _criticalDataLoaded {
    final rm = V3MasterRealtimeManager.instance;
    return rm.tableRevision('v3_operativna_nedelja') > 0 || rm.operativnaNedeljaCache.isNotEmpty;
  }

  Widget _buildSkeletonCard({required double height}) {
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.05),
      highlightColor: Colors.white.withValues(alpha: 0.14),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }

  /// Trailing debounce za realtime revision event-e — u smeni jedan
  /// operativna/zahtevi burst može ispaliti desetine event-a u sekundi,
  /// a svaki _refresh skenira ceo zahtevi + operativna keš ~10×.
  void _scheduleRefresh() {
    _refreshDebounceTimer?.cancel();
    _refreshDebounceTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _refresh();
    });
  }

  void _refresh() {
    final putnikId = _currentPutnikId();
    if (putnikId == null) {
      debugPrint('[V3PutnikProfilScreen] _refresh: putnikId nije resolovan — raspored ostaje prazan');
      return;
    }
    // Osvježi putnik iz cache-a
    final cached = V3MasterRealtimeManager.instance.putniciCache[putnikId];
    if (cached != null) _putnikData = Map<String, dynamic>.from(cached);
    // Raspored po danima iz v3_operativna_nedelja kao jedinog izvora istine za READ
    final dani = V3DanHelper.workdayAbbrs.toList(); // pon-pet (radni dani)
    final anchor = V3DanHelper.schedulingWeekAnchor();
    final rm = V3MasterRealtimeManager.instance;
    // Aktivne ponude oslobođenih mesta za ovog putnika (odbijeni zahtevi sa
    // mesto_ponuda flagom, kao i odobreni zahtevi sa upgrade ponudom za
    // prvobitno traženi termin) — prikazuju se kao banner van rasporeda.
    final ponude = rm.zahteviCache.values
        .where((z) =>
            (z['created_by']?.toString() ?? '') == putnikId &&
            (V3StatusPolicy.isRejected(z['status']?.toString()) ||
                V3StatusPolicy.normalizeStatus(z['status']?.toString()) == 'odobreno') &&
            z['mesto_ponuda'] == true &&
            _ponudaJosTraje(z))
        .map((z) => Map<String, dynamic>.from(z))
        .toList()
      ..sort((a, b) => (a['mesto_ponuda_at']?.toString() ?? '').compareTo(b['mesto_ponuda_at']?.toString() ?? ''));
    // Aktivne alternativa ponude (status='alternativa' + pre/posle termini) —
    // isti 10-min expiry kao server (alternativa_offered_at, fallback
    // updated_at). Bez ovoga putnik može da odgovori jedino kroz push.
    final alternative = rm.zahteviCache.values
        .where((z) =>
            (z['created_by']?.toString() ?? '') == putnikId &&
            V3StatusPolicy.isOfferLike(z['status']?.toString()) &&
            _alternativaJosTraje(z))
        .map((z) => Map<String, dynamic>.from(z))
        .toList()
      ..sort((a, b) => (a['alternativa_offered_at']?.toString() ?? a['updated_at']?.toString() ?? '')
          .compareTo(b['alternativa_offered_at']?.toString() ?? b['updated_at']?.toString() ?? ''));
    final newMap = <String, List<_ZahtevInfo>>{};
    for (final dan in dani) {
      final datumIso = V3DanHelper.datumIsoZaDanAbbrUTekucojSedmici(dan, anchor: anchor);
      final infos = <_ZahtevInfo>[];

      for (final grad in const ['BC', 'VS']) {
        final opRows = rm.operativnaNedeljaCache.values.where((e) {
          return _rowPutnikId(e) == putnikId &&
              (e['datum'] as String? ?? '').startsWith(datumIso) &&
              (e['grad']?.toString().toUpperCase() ?? '') == grad;
        }).toList();

        final zahtevRows = rm.zahteviCache.values.where((z) {
          final status = V3StatusPolicy.normalizeStatus(z['status']?.toString());
          return (z['created_by']?.toString() ?? '') == putnikId &&
              (z['datum'] as String? ?? '').startsWith(datumIso) &&
              (z['grad']?.toString().toUpperCase() ?? '') == grad &&
              (V3StatusPolicy.isPending(status) || V3StatusPolicy.isOfferLike(status));
        }).toList();

        _ZahtevInfo? bestZahtevInfo;
        int bestZahtevPriority = -1;
        DateTime bestZahtevTs = DateTime.fromMillisecondsSinceEpoch(0);

        for (final zahtev in zahtevRows) {
          final status = V3StatusPolicy.normalizeStatus(zahtev['status']?.toString());
          final priority = V3StatusPolicy.displayPriority(status: status, pokupljen: false);
          final zahtevTs = V3BelgradeTime.parseTs(zahtev['updated_at']?.toString()) ??
              V3BelgradeTime.parseTs(zahtev['created_at']?.toString()) ??
              DateTime.fromMillisecondsSinceEpoch(0);

          final trazeniVreme = _normalizeValidTime(zahtev['trazeni_polazak_at']?.toString()) ??
              _normalizeValidTime(zahtev['polazak_at']?.toString()) ??
              _normalizeValidTime(zahtev['alternativa_pre_at']?.toString()) ??
              _normalizeValidTime(zahtev['alternativa_posle_at']?.toString()) ??
              '—';

          final info = _ZahtevInfo(
            grad: grad,
            vreme: trazeniVreme,
            status: status,
            pokupljen: false,
            koristiSekundarnu: zahtev['koristi_sekundarnu'] as bool? ?? false,
          );

          if (priority > bestZahtevPriority || (priority == bestZahtevPriority && zahtevTs.isAfter(bestZahtevTs))) {
            bestZahtevInfo = info;
            bestZahtevPriority = priority;
            bestZahtevTs = zahtevTs;
          }
        }

        Map<String, dynamic>? selected;
        int selectedRank = -1;
        for (final row in opRows) {
          final status = V3StatusPolicy.normalizeStatus(
            V3StatusPolicy.deriveOperativnaStatus(
              otkazanoAt: row['otkazano_at'],
              polazakAt: row['polazak_at'],
            ),
          );
          final rank = V3StatusPolicy.displayPriority(
            status: status,
            pokupljen: V3StatusPolicy.isTimestampSet(row['pokupljen_at']),
          );
          if (rank > selectedRank) {
            selected = row;
            selectedRank = rank;
          }
        }

        _ZahtevInfo? bestOperativnaInfo;
        if (selected != null) {
          final status = V3StatusPolicy.normalizeStatus(
            V3StatusPolicy.deriveOperativnaStatus(
              otkazanoAt: selected['otkazano_at'],
              polazakAt: selected['polazak_at'],
            ),
          );
          final opPolazakAt = _normalizeValidTime(selected['polazak_at']?.toString());
          final displayVreme = opPolazakAt ?? '—';

          bestOperativnaInfo = _ZahtevInfo(
            grad: grad,
            vreme: displayVreme,
            status: status,
            pokupljen: V3StatusPolicy.isTimestampSet(selected['pokupljen_at']),
            koristiSekundarnu: selected['koristi_sekundarnu'] as bool? ?? false,
          );
        }

        if (bestOperativnaInfo == null && bestZahtevInfo == null) continue;

        if (bestOperativnaInfo == null) {
          infos.add(bestZahtevInfo!);
          continue;
        }

        if (bestZahtevInfo == null) {
          infos.add(bestOperativnaInfo);
          continue;
        }

        final operativnaPriority = V3StatusPolicy.displayPriority(
          status: bestOperativnaInfo.status,
          pokupljen: bestOperativnaInfo.pokupljen,
        );
        final zahtevPriority = V3StatusPolicy.displayPriority(
          status: bestZahtevInfo.status,
          pokupljen: bestZahtevInfo.pokupljen,
        );

        infos.add(zahtevPriority > operativnaPriority ? bestZahtevInfo : bestOperativnaInfo);
      }

      final bestByGrad = <String, _ZahtevInfo>{};
      for (final info in infos) {
        final current = bestByGrad[info.grad];
        final infoPriority = V3StatusPolicy.displayPriority(
          status: info.status,
          pokupljen: info.pokupljen,
        );
        final currentPriority = current == null
            ? -1
            : V3StatusPolicy.displayPriority(
                status: current.status,
                pokupljen: current.pokupljen,
              );
        if (current == null || infoPriority > currentPriority) {
          bestByGrad[info.grad] = info;
        }
      }
      newMap[dan] = bestByGrad.values.toList();
    }
    if (mounted) {
      setState(() {
        _rasporedMap
          ..clear()
          ..addAll(newMap);
        _aktivnePonude = ponude;
        _aktivneAlternative = alternative;
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // TIME PICKER
  // ─────────────────────────────────────────────────────────────────
  /// Vraća datum za dati dan abbr u tekućoj sedmici.
  Future<void> _updatePolazak(String dan, String grad, String? novoVreme,
      {_ZahtevInfo? trenutniInfo, bool koristiSekundarnu = false}) async {
    final putnikId = _currentPutnikId();
    if (putnikId == null) return;

    // Debounce: ignoriši dvostruki klik u roku od 500 ms
    if (V3StreamUtils.isTimerActive(_actionDebounceKey)) return;
    V3StreamUtils.createTimer(
      key: _actionDebounceKey,
      duration: const Duration(milliseconds: 500),
      callback: () => V3StreamUtils.cancelTimer(_actionDebounceKey),
    );

    // Guard za CEO trajanje akcije (putnik + dan + grad): sprečava da 2-3
    // uzastopna klika (van 500ms debounce prozora, dok prvi zahtev još nije
    // stigao/osvežio keš) kreiraju više zahteva istovremeno za isti kontekst.
    final contextKey = '$putnikId|$dan|$grad';
    if (_pendingActionContexts.contains(contextKey)) return;

    final validNovoVreme = _normalizeValidTime(novoVreme);
    final datumPolaska = V3DanHelper.datumZaDanAbbrUTekucojSedmici(
      dan,
      anchor: V3DanHelper.schedulingWeekAnchor(),
    );

    if (novoVreme != null && validNovoVreme == null) {
      if (mounted) V3AppSnackBar.warning(context, V3PutnikProfilMessages.invalidTermTime);
      return;
    }

    // Sveži pogled u keš neposredno pre slanja: ako već postoji zahtev u
    // obradi/ponudi za ovaj kontekst (npr. iz prethodnog klika koji je već
    // stigao na server ali UI dijalog to još nije prikazao), ne dozvoli novi.
    if (validNovoVreme != null) {
      final datumIso = V3DanHelper.toIsoDate(datumPolaska);
      final vecPostojiUObradi = V3MasterRealtimeManager.instance.zahteviCache.values.any((z) {
        final status = V3StatusPolicy.normalizeStatus(z['status']?.toString());
        return _rowPutnikId(z) == putnikId &&
            (z['datum'] as String? ?? '').startsWith(datumIso) &&
            (z['grad']?.toString().toUpperCase() ?? '') == grad &&
            (V3StatusPolicy.isPending(status) || V3StatusPolicy.isOfferLike(status));
      });
      if (vecPostojiUObradi) {
        if (mounted) V3AppSnackBar.info(context, V3PutnikProfilMessages.requestPendingDispatcher);
        return;
      }

      // Re-check 15-min zaključavanja U TRENUTKU slanja — picker proverava
      // samo pri otvaranju dijaloga. Ako dijalog ostane otvoren preko
      // granice, klik bi napravio 'obrada' zahtev za termin koji server
      // više ne obrađuje (zabrana prošlih termina) → putnik zaglavi
      // 'u obradi' i pending-guard mu blokira dalje izmene konteksta.
      final parts = validNovoVreme.split(':');
      final polazak = V3BelgradeTime.dateTime(
        datumPolaska.year,
        datumPolaska.month,
        datumPolaska.day,
        int.parse(parts[0]),
        int.parse(parts[1]),
      );
      final sendNow = V3BelgradeTime.now();
      if (sendNow.isAfter(polazak.subtract(const Duration(minutes: 15)))) {
        final unlockAt = V3DanHelper.nextSchedulingUnlock(now: sendNow);
        final unlockStr =
            '${unlockAt.day}.${unlockAt.month}.${unlockAt.year}. ${unlockAt.hour.toString().padLeft(2, '0')}:${unlockAt.minute.toString().padLeft(2, '0')}';
        if (mounted) V3AppSnackBar.info(context, V3PutnikProfilMessages.schedulingLocked(validNovoVreme, unlockStr));
        return;
      }
    }

    V3StateUtils.safeSetState(this, () => _pendingActionContexts.add(contextKey));
    try {
      if (validNovoVreme == null) {
        // Otkaži postojeći zahtev
        if (trenutniInfo == null) return;
        await V3ZahtevService.otkaziPolazakPutnikaPoKontekstu(
          putnikId: putnikId,
          datum: datumPolaska,
          grad: grad,
          otkazaoPutnikId: putnikId,
        );
        if (mounted) V3AppSnackBar.success(context, V3PutnikProfilMessages.tripCanceled(dan, grad));
      } else {
        // Sačuvaj izmenu po kontekstu (putnik + dan + grad)
        await V3ZahtevService.sacuvajPolazakPutnikaPoKontekstu(
          putnikId: putnikId,
          datum: datumPolaska,
          grad: grad,
          novoVreme: validNovoVreme,
          koristiSekundarnu: koristiSekundarnu,
          updatedBy: V3UuidUtils.normalizeUuid(putnikId),
        );
        if (mounted) {
          V3AppSnackBar.success(context, V3PutnikProfilMessages.requestReceived);
        }
      }
    } catch (e) {
      V3ErrorUtils.asyncError(this, context, e);
    } finally {
      V3StateUtils.safeSetState(this, () => _pendingActionContexts.remove(contextKey));
    }
  }

  Future<void> _showTimePicker(BuildContext ctx, String dan, String grad, _ZahtevInfo? info) async {
    // Guard protiv duplih dijaloga — ćelija je GestureDetector bez
    // debounce-a, a metod ima async gap-ove pre showDialogBuilder pa bi
    // brzi dupli tap naslagao dva identična pickera.
    if (_timePickerOpen) return;
    _timePickerOpen = true;
    try {
      await _showTimePickerInner(ctx, dan, grad, info);
    } finally {
      _timePickerOpen = false;
    }
  }

  Future<void> _showTimePickerInner(BuildContext ctx, String dan, String grad, _ZahtevInfo? info) async {
    final currentPutnikId = _currentPutnikId() ?? '';
    // v3_finansije je sekundarna tabela — na cold start bez disk keša stigne
    // posle kritične faze. Sačekaj je nakratko da debt-gate ne bi propuštio
    // putnika sa dugom u prozoru dok podaci još nisu stigli.
    final rm = V3MasterRealtimeManager.instance;
    if (rm.finansijeCache.isEmpty) {
      final inFlight = rm.secondaryInFlight;
      if (inFlight != null) {
        await inFlight.timeout(const Duration(seconds: 3), onTimeout: () {});
      }
    }
    final previousMonthDebt = _profilStats(currentPutnikId).prevMonthDebt;
    if (previousMonthDebt > 0.009) {
      if (mounted) {
        await _showPreviousMonthDebtDialog(ctx, dugIznos: previousMonthDebt);
      }
      return;
    }

    final datumPolaska = V3DanHelper.datumZaDanAbbrUTekucojSedmici(
      dan,
      anchor: V3DanHelper.schedulingWeekAnchor(),
    );

    // Scenario 2: zahtev u obradi — blokirati sve akcije
    if (V3StatusPolicy.isPending(info?.status)) {
      if (mounted) V3AppSnackBar.info(ctx, V3PutnikProfilMessages.requestPendingDispatcher);
      return;
    }
    // Scenario 6: putnik je već pokupljen — ne može da otkazuje
    if (V3StatusPolicy.isActionLocked(status: info?.status, pokupljen: info?.pokupljen ?? false)) {
      if (mounted) V3AppSnackBar.info(ctx, V3PutnikProfilMessages.alreadyPickedUp);
      return;
    }
    // Aktivna alternativa ponuda — odgovor ide kroz banner iznad rasporeda,
    // ne kroz picker (svi termini bi ionako bili blokirani offer-guardom).
    if (V3StatusPolicy.isOfferLike(info?.status)) {
      if (mounted) V3AppSnackBar.info(ctx, _tr('alternativaAktivnaInfo'));
      return;
    }
    // Scenario 5: zaključavanje 15 min pre polaska
    final datumIso = V3DanHelper.toIsoDate(datumPolaska);
    // Prošli dan — svi termini bi bili zaključani, dijalog nema svrhe.
    if (datumIso.compareTo(V3BelgradeTime.todayIso()) < 0) {
      if (mounted) V3AppSnackBar.info(ctx, _tr('terminiProsli'));
      return;
    }
    final neradanRazlog = getNeradanDanRazlog(datumIso: datumIso, grad: grad.toLowerCase());
    if (neradanRazlog != null) {
      if (mounted) {
        V3AppSnackBar.info(ctx, V3PutnikProfilMessages.nonWorkingDay(datumIso, neradanRazlog));
      }
      return;
    }

    final now = V3BelgradeTime.now();
    final dayFullName = V3DanHelper.fullName(datumPolaska);
    var vremena = getRasporedVremena(grad.toLowerCase(), navBarTypeNotifier.value, day: dayFullName)
        .where((v) => _normalizeValidTime(v) != null)
        .toList();
    if (vremena.isEmpty) {
      // Raspored stiže sa v3_app_settings u kritičnoj bootstrap fazi — na
      // sporoj vezi (Funnel/cold start) može kasniti i picker bi se otvorio
      // prazan. Sačekaj kratko da init/bootstrap završi pa preracunaj.
      try {
        await rm.initV3().timeout(const Duration(seconds: 6), onTimeout: () {});
      } catch (_) {}
      vremena = getRasporedVremena(grad.toLowerCase(), navBarTypeNotifier.value, day: dayFullName)
          .where((v) => _normalizeValidTime(v) != null)
          .toList();
    }
    if (vremena.isEmpty) {
      // Bez termina ne otvaraj prazan dijalog — putnik bi video samo
      // naslov bez ikakvih opcija.
      if (mounted) V3AppSnackBar.info(ctx, _tr('rasporedSeUcitava'));
      return;
    }
    final currentVreme = info?.vreme;
    final hasActive =
        info != null && !V3StatusPolicy.isCanceledOrRejected(info.status) && !V3StatusPolicy.isOfferLike(info.status);
    // Provera da li putnik ima drugu adresu za ovaj grad
    final putnikId = _currentPutnikId();
    final putnikCache = V3MasterRealtimeManager.instance.putniciCache[putnikId];
    final hasSecondary =
        grad == 'BC' ? (putnikCache?['adresa_bc_id_2'] != null) : (putnikCache?['adresa_vs_id_2'] != null);
    String? secondaryId;
    if (grad == 'BC') {
      secondaryId = putnikCache?['adresa_bc_id_2'] as String?;
    } else {
      secondaryId = putnikCache?['adresa_vs_id_2'] as String?;
    }
    final secondaryNaziv = V3AdresaService.getAdresaById(secondaryId)?.naziv ?? _tr('drugaAdresa');
    bool koristiSekundarnu = info?.koristiSekundarnu ?? false;
    await V3DialogHelper.showDialogBuilder<void>(
      context: ctx,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          child: SizedBox.expand(
            child: V3ContainerUtils.gradientContainer(
              gradient: V3ThemeManager().currentGradient,
              borderRadius: BorderRadius.zero,
              child: SafeArea(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Column(
                          children: [
                            Text(
                              grad == 'BC' ? _tr('bcPolazak') : _tr('vsPolazak'),
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _getDanLabel(dan),
                              style: TextStyle(color: V3StyleHelper.whiteAlpha5, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: Colors.white12, height: 1),
                      // Address Selector (Prikazuje se samo ako postoji druga adresa)
                      if (hasSecondary)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: InkWell(
                            onTap: () => setDialogState(() => koristiSekundarnu = !koristiSekundarnu),
                            borderRadius: BorderRadius.circular(8),
                            child: V3ContainerUtils.styledContainer(
                              padding: const EdgeInsets.all(10),
                              backgroundColor: V3StyleHelper.whiteAlpha05,
                              border: Border.all(
                                color: Colors.white12,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              child: Row(
                                children: [
                                  Icon(
                                    koristiSekundarnu ? Icons.location_on : Icons.location_on_outlined,
                                    color: Colors.white54,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          koristiSekundarnu ? _tr('drugaAdresa') : _tr('primarnaAdresa'),
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11,
                                          ),
                                        ),
                                        Text(
                                          koristiSekundarnu
                                              ? secondaryNaziv
                                              : (grad == 'BC'
                                                  ? (V3AdresaService.getAdresaById(
                                                              putnikCache?['adresa_bc_id'] as String?)
                                                          ?.naziv ??
                                                      _tr('glavnaAdresa'))
                                                  : (V3AdresaService.getAdresaById(
                                                              putnikCache?['adresa_vs_id'] as String?)
                                                          ?.naziv ??
                                                      _tr('glavnaAdresa'))),
                                          style: TextStyle(
                                            color: koristiSekundarnu ? Colors.greenAccent : Colors.white,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: koristiSekundarnu,
                                    onChanged: (val) => setDialogState(() => koristiSekundarnu = val),
                                    activeColor: Colors.orange,
                                    activeTrackColor: Colors.orange.withValues(alpha: 0.3),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      // Grid vremena
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Otkaži dugme — sa potvrdom: jedan slučajni tap
                            // je ranije odmah slao RPC otkazivanja.
                            if (hasActive)
                              SizedBox(
                                width: double.infinity,
                                child: V3ButtonUtils.outlinedButton(
                                  onPressed: () async {
                                    final ok = await V3DialogHelper.showConfirmDialog(
                                      dialogCtx,
                                      title: _tr('otkaziTermin'),
                                      message: _tr('otkaziTerminPotvrda'),
                                      confirmText: _tr('otkaziTermin'),
                                      cancelText: _tr('otkaziBtn'),
                                      isDangerous: true,
                                    );
                                    if (ok != true) return;
                                    if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
                                    await _updatePolazak(dan, grad, null, trenutniInfo: info);
                                  },
                                  text: _tr('otkaziTermin'),
                                  icon: Icons.cancel_outlined,
                                  borderColor: Colors.redAccent,
                                  foregroundColor: Colors.redAccent,
                                  fontSize: 14,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            if (hasActive) const SizedBox(height: 10),
                            if (hasActive) const Divider(color: Colors.white24, height: 1),
                            if (hasActive) const SizedBox(height: 10),
                            // Grid 2 kolone
                            GridView.count(
                              crossAxisCount: 2,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              childAspectRatio: 3.2,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              children: vremena.map((vreme) {
                                final isSelected =
                                    currentVreme != null && V3BelgradeTime.normalizeToHHmm(currentVreme) == vreme;
                                // Scenario 5: zaključaj dugme 15 min pre polaska
                                final parts = vreme.split(':');
                                final polazak = V3BelgradeTime.dateTime(
                                  datumPolaska.year,
                                  datumPolaska.month,
                                  datumPolaska.day,
                                  int.parse(parts[0]),
                                  int.parse(parts[1]),
                                );
                                final isLocked = now.isAfter(polazak.subtract(const Duration(minutes: 15)));
                                return OutlinedButton(
                                  onPressed: isLocked
                                      ? () async {
                                          Navigator.of(dialogCtx).pop();
                                          final unlockAt = V3DanHelper.nextSchedulingUnlock(now: now);
                                          final unlockStr =
                                              '${unlockAt.day}.${unlockAt.month}.${unlockAt.year}. ${unlockAt.hour.toString().padLeft(2, '0')}:${unlockAt.minute.toString().padLeft(2, '0')}';
                                          await Future<void>.delayed(const Duration(milliseconds: 120));
                                          if (!mounted) return;
                                          V3AppSnackBar.info(
                                              ctx, V3PutnikProfilMessages.schedulingLocked(vreme, unlockStr));
                                        }
                                      : () async {
                                          Navigator.of(dialogCtx).pop();
                                          await _updatePolazak(dan, grad, vreme,
                                              trenutniInfo: info, koristiSekundarnu: koristiSekundarnu);
                                        },
                                  style: OutlinedButton.styleFrom(
                                    backgroundColor: isLocked
                                        ? V3StyleHelper.whiteAlpha05
                                        : isSelected
                                            ? Colors.green.withValues(alpha: 0.45)
                                            : V3StyleHelper.whiteAlpha15,
                                    side: BorderSide(
                                      color: isLocked
                                          ? Colors.white12
                                          : isSelected
                                              ? Colors.greenAccent
                                              : Colors.white60,
                                      width: isSelected ? 2.5 : 1.5,
                                    ),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    padding: EdgeInsets.symmetric(vertical: isSelected ? 4 : 10),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isSelected)
                                        const Icon(Icons.check_circle, color: Colors.greenAccent, size: 12),
                                      Text(
                                        vreme,
                                        style: TextStyle(
                                          color: isLocked ? Colors.white24 : Colors.white,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      // Zatvori
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: V3ButtonUtils.textButton(
                          onPressed: () => Navigator.of(dialogCtx).pop(),
                          text: _tr('zatvori'),
                          foregroundColor: Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Helper za konverziju kratice dana u puni naziv (fiksno pon–pet).
  /// Ne računa iz datuma — labela ne sme da "skoči" na Nedelju zbog TZ.
  String _getDanLabel(String danAbbr) {
    final name = V3DanHelper.fullNameFromWorkdayAbbr(danAbbr);
    return name.isEmpty ? danAbbr : _trDanFullName(name);
  }

  Widget _buildLanguageFlag() {
    return ValueListenableBuilder<Locale>(
      valueListenable: V3LocaleManager().localeNotifier,
      builder: (context, locale, _) {
        final code = locale.languageCode;
        final currentFlag = code == 'en'
            ? '🇬🇧'
            : code == 'ru'
                ? '🇷🇺'
                : code == 'de'
                    ? '🇩🇪'
                    : code == 'zh'
                        ? '🇨🇳'
                        : '🇷🇸';
        return PopupMenuButton<String>(
          tooltip: _tr('jezik'),
          offset: const Offset(0, 44),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.black.withValues(alpha: 0.85),
          onSelected: (newCode) => V3LocaleManager().changeLocale(Locale(newCode)),
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              value: 'sr',
              child: Row(
                children: [
                  const Text('🇷🇸', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Text(
                    'Srpski',
                    style: TextStyle(color: Colors.white.withValues(alpha: code == 'sr' ? 1 : 0.6)),
                  ),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'en',
              child: Row(
                children: [
                  const Text('🇬🇧', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Text(
                    'English',
                    style: TextStyle(color: Colors.white.withValues(alpha: code == 'en' ? 1 : 0.6)),
                  ),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'ru',
              child: Row(
                children: [
                  const Text('🇷🇺', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Text(
                    'Русский',
                    style: TextStyle(color: Colors.white.withValues(alpha: code == 'ru' ? 1 : 0.6)),
                  ),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'de',
              child: Row(
                children: [
                  const Text('🇩🇪', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Text(
                    'Deutsch',
                    style: TextStyle(color: Colors.white.withValues(alpha: code == 'de' ? 1 : 0.6)),
                  ),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'zh',
              child: Row(
                children: [
                  const Text('🇨🇳', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Text(
                    '中文',
                    style: TextStyle(color: Colors.white.withValues(alpha: code == 'zh' ? 1 : 0.6)),
                  ),
                ],
              ),
            ),
          ],
          child: Text(currentFlag, style: const TextStyle(fontSize: 18)),
        );
      },
    );
  }

  Future<void> _logout() async {
    final ok = await V3DialogHelper.showConfirmDialog(
      context,
      title: _tr('odjavaTitle'),
      message: _tr('odjavaMessage'),
      confirmText: _tr('odjaviSe'),
      cancelText: _tr('otkaziBtn'),
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    // Otkaži stream subscription pre brisanja sesije
    V3StreamUtils.cancelSubscription('putnik_profil_cache');
    V3StreamUtils.cancelSubscription('putnik_profil_fin');
    // Obrisi sesiju i kredencijale
    V3PutnikService.currentPutnik = null;

    // Oslobodi uređaj slot u bazi — best-effort, NE sme da blokira odjavu.
    // Fire-and-forget: edge invoke bez timeout-a bi na mrtvoj vezi ostavio
    // korisnika na mrtvom ekranu (ništa se ne dešava posle confirm-a).
    final putnikId = (_currentPutnikId() ?? '').trim();
    if (putnikId.isNotEmpty) {
      unawaited(() async {
        final deviceId = await V3DeviceIdentityService.getStableDeviceId();
        await V3PushTokenEdgeService.releaseDeviceSlot(
          v3AuthId: putnikId,
          installationId: deviceId,
        );
      }());
    }

    await V3ClosedAuthService.clearManualSmsPutnikPhone();
    await V3ClosedAuthService.clearManualSmsVozacPhone();
    if (!mounted) return;
    V3AppSnackBar.success(context, V3PutnikProfilMessages.logoutSuccess);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      V3SmoothPageRoute<void>(screen: const V3WelcomeScreen()),
      (r) => false,
    );
  }

  Future<void> _showEditProfilDialog() async {
    await V3DialogHelper.showDialogBuilder<void>(
      context: context,
      builder: (ctx) => _EditProfilDialog(
        putnikData: _putnikData,
        onSaved: (updated) {
          V3StateUtils.safeSetState(this, () => _putnikData = updated);
        },
      ),
    );
  }

  // _showAlternativaDialog obrisan jer alternativa ide samo preko push notifikacije.
  // ─── MESTO OSLOBOĐENO (in-app ponuda) ────────────────────────────
  int? _preostaloMinutaZaPonudu(String? mestoPonudaAt) {
    final offeredAt = V3BelgradeTime.parseTs(mestoPonudaAt);
    if (offeredAt == null) return null;
    final elapsed = DateTime.now().difference(offeredAt);
    // inMinutes (floor), ne ceil — ceil je sklanjao ponudu do minut pre
    // isteka, iako je server prihvata punih 10 minuta.
    final remaining = 10 - elapsed.inMinutes;
    return remaining.clamp(0, 10);
  }

  /// Ponuda se sklanja sa ekrana i kad istekne lokalno (10 min od
  /// mesto_ponuda_at) — bez čekanja na serverovo mesto_ponuda=false koje
  /// stiže realtime-om. Ako realtime pauzira, putnik ne bi video zastarelu
  /// ponudu "ističe za 0 min" koju server već ne prihvata.
  bool _ponudaJosTraje(Map<String, dynamic> zahtev) {
    final preostalo = _preostaloMinutaZaPonudu(zahtev['mesto_ponuda_at']?.toString());
    return preostalo == null || preostalo > 0;
  }

  /// Alternativa ponuda važi 10 min od alternativa_offered_at (fallback
  /// updated_at — isti coalesce kao fn_v3_alternativa_action na serveru).
  bool _alternativaJosTraje(Map<String, dynamic> zahtev) {
    final ts = zahtev['alternativa_offered_at']?.toString() ?? zahtev['updated_at']?.toString();
    final preostalo = _preostaloMinutaZaPonudu(ts);
    return preostalo == null || preostalo > 0;
  }

  String _formatDatumKratko(String? datumIso) {
    final datum = V3BelgradeTime.parseDatum(datumIso);
    if (datum == null) return '';
    return '${datum.day.toString().padLeft(2, '0')}.${datum.month.toString().padLeft(2, '0')}.';
  }

  /// Odgovor na ponudu mesta ili alternativu kroz fn_v3_alternativa_action.
  /// [action]: 'accept_pre' | 'accept_posle' | 'reject' (za mesto ponudu
  /// bilo koji accept_* radi — server uzima trazeni_polazak_at).
  Future<void> _odgovoriNaPonudu(Map<String, dynamic> zahtev, {required String action}) async {
    final zahtevId = zahtev['id']?.toString() ?? '';
    if (zahtevId.isEmpty || _pendingPonudaZahtevi.contains(zahtevId)) return;
    V3StateUtils.safeSetState(this, () => _pendingPonudaZahtevi.add(zahtevId));
    try {
      // Dokaz identiteta uređaja — edge/RPC proverava da token ili device id
      // odgovara vlasniku zahteva (v3_auth slotovi). Paralelno — getBestToken
      // može pojedini sekunde (FCM), a ponuda ima 10-min prozor.
      final (tokenResult, hardwareId, installationId) = await (
        V3PushTokenProvider.getBestToken(),
        V3DeviceIdentityService.getHardwareId(),
        V3PushTokenProvider.getInstallationId(),
      ).wait;
      final deviceToken = tokenResult?.token.trim() ?? '';
      final hwId = hardwareId ?? '';
      final instId = installationId?.trim() ?? '';

      // Brza putanja: fn_v3_alternativa_action RPC radi istu device-identity
      // proveru i kapacitet/expiry logiku u plpgsql (~0.3s vs 1-4s edge cold
      // start). Edge invoke ostaje kao fallback (isti pattern kao
      // fn_v3_verify_login).
      dynamic data;
      try {
        data = await supabase.rpc('fn_v3_alternativa_action', params: {
          'p_zahtev_id': zahtevId,
          'p_action': action,
          'p_device_token': deviceToken,
          'p_hardware_id': hwId,
          'p_installation_id': instId,
        }).timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('[Alternativa] RPC fallback na edge: $e');
        final response = await supabase.functions.invoke(
          'v3-alternativa-action',
          body: {
            'zahtev_id': zahtevId,
            'action': action,
            'device_token': deviceToken,
            'hardware_id': hwId,
            'installation_id': instId,
          },
        ).timeout(const Duration(seconds: 20));
        data = response.data;
      }
      final ok = data is Map && data['ok'] == true;
      final reason = data is Map ? (data['reason'] ?? '').toString() : '';
      if (!mounted) return;
      if (ok) {
        // Optimistički upis u keš — banner nestaje odmah (~250ms debounce),
        // autoritativni red ionako stiže realtime-om. Semantika preslikana
        // sa fn_v3_alternativa_action na serveru.
        final cachedRow = V3MasterRealtimeManager.instance.zahteviCache[zahtevId];
        if (cachedRow != null) {
          final mutated = Map<String, dynamic>.from(cachedRow);
          final offerKind = (data['offer_kind'] ?? '').toString();
          if (action == 'reject' && offerKind == 'mesto_oslobodjeno') {
            mutated['mesto_ponuda'] = false;
            mutated['mesto_ponuda_odbijena'] = true;
            mutated['mesto_ponuda_at'] = null;
          } else if (action == 'reject') {
            mutated['status'] = 'odbijeno';
            mutated['alternativa_pre_at'] = null;
            mutated['alternativa_posle_at'] = null;
            mutated['alternativa_offered_at'] = null;
          } else {
            mutated['status'] = 'odobreno';
            final selectedTime = (data['selected_time'] ?? '').toString().trim();
            if (selectedTime.isNotEmpty) mutated['polazak_at'] = selectedTime;
            mutated['mesto_ponuda'] = false;
            mutated['mesto_ponuda_at'] = null;
            mutated['alternativa_pre_at'] = null;
            mutated['alternativa_posle_at'] = null;
            mutated['alternativa_offered_at'] = null;
          }
          mutated['updated_at'] = V3BelgradeTime.nowIsoUtc();
          V3MasterRealtimeManager.instance.v3UpsertToCache('v3_zahtevi', mutated);
        }
        if (action != 'reject') {
          V3AppSnackBar.success(context, V3PutnikProfilMessages.seatAccepted);
        } else {
          V3AppSnackBar.info(context, V3PutnikProfilMessages.seatOfferDeclined);
        }
      } else if (reason == 'offer_expired' || reason == 'selected_slot_past') {
        V3AppSnackBar.info(context, V3PutnikProfilMessages.seatOfferExpired);
      } else if (reason == 'selected_slot_full' || reason == 'no_capacity_slot') {
        V3AppSnackBar.warning(context, V3PutnikProfilMessages.seatTaken);
      } else {
        V3AppSnackBar.warning(context, V3PutnikProfilMessages.seatOfferError);
      }
    } catch (e) {
      V3ErrorUtils.asyncError(this, context, e);
    } finally {
      V3StateUtils.safeSetState(this, () => _pendingPonudaZahtevi.remove(zahtevId));
    }
  }

  Widget _buildMestoPonudaCard() {
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(14),
      backgroundColor: Colors.green.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.55), width: 1.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.event_available, color: Colors.greenAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _tr('mestoOslobodjenoNaslov'),
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          ..._aktivnePonude.map(_buildMestoPonudaRow),
        ],
      ),
    );
  }

  Widget _buildMestoPonudaRow(Map<String, dynamic> zahtev) {
    final zahtevId = zahtev['id']?.toString() ?? '';
    final grad = (zahtev['grad']?.toString() ?? '').toUpperCase();
    final gradLabel = grad == 'VS' ? _tr('vrsac') : _tr('belaCrkva');
    final vreme = _normalizeValidTime(zahtev['trazeni_polazak_at']?.toString()) ?? '—';
    final datum = _formatDatumKratko(zahtev['datum']?.toString());
    final preostalo = _preostaloMinutaZaPonudu(zahtev['mesto_ponuda_at']?.toString());
    final busy = _pendingPonudaZahtevi.contains(zahtevId);
    final opis = [if (datum.isNotEmpty) datum, gradLabel, vreme].join(' • ');

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: V3ContainerUtils.styledContainer(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        backgroundColor: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              opis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            if (preostalo != null) ...[
              const SizedBox(height: 4),
              _PonudaCountdown(
                offeredAt: zahtev['mesto_ponuda_at']?.toString(),
                template: _tr('ponudaIsticeSekunde'),
                onExpired: _scheduleRefresh,
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: V3ButtonUtils.outlinedButton(
                    onPressed: busy ? null : () => _odgovoriNaPonudu(zahtev, action: 'accept_pre'),
                    text: _tr('mestoPrihvati'),
                    icon: Icons.check_circle_outline,
                    borderColor: Colors.greenAccent,
                    foregroundColor: Colors.greenAccent,
                    fontSize: 13,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: V3ButtonUtils.outlinedButton(
                    onPressed: busy ? null : () => _odgovoriNaPonudu(zahtev, action: 'reject'),
                    text: _tr('mestoOdbij'),
                    icon: Icons.cancel_outlined,
                    borderColor: Colors.redAccent,
                    foregroundColor: Colors.redAccent,
                    fontSize: 13,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ─── ALTERNATIVA (in-app ponuda zamenskog termina) ───────────────
  Widget _buildAlternativaCard() {
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(14),
      backgroundColor: Colors.deepOrange.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.deepOrangeAccent.withValues(alpha: 0.6), width: 1.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.swap_calls, color: Colors.deepOrangeAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _tr('alternativaNaslov'),
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          ..._aktivneAlternative.map(_buildAlternativaRow),
        ],
      ),
    );
  }

  Widget _buildAlternativaRow(Map<String, dynamic> zahtev) {
    final zahtevId = zahtev['id']?.toString() ?? '';
    final grad = (zahtev['grad']?.toString() ?? '').toUpperCase();
    final gradLabel = grad == 'VS' ? _tr('vrsac') : _tr('belaCrkva');
    final trazeno = _normalizeValidTime(zahtev['trazeni_polazak_at']?.toString());
    final vremePre = _normalizeValidTime(zahtev['alternativa_pre_at']?.toString());
    final vremePosle = _normalizeValidTime(zahtev['alternativa_posle_at']?.toString());
    final datum = _formatDatumKratko(zahtev['datum']?.toString());
    final ts = zahtev['alternativa_offered_at']?.toString() ?? zahtev['updated_at']?.toString();
    final preostalo = _preostaloMinutaZaPonudu(ts);
    final busy = _pendingPonudaZahtevi.contains(zahtevId);
    final opis = [
      if (datum.isNotEmpty) datum,
      gradLabel,
      if (trazeno != null) '${_tr('trazeno')}: $trazeno',
    ].join(' • ');

    final opcije = <({String vreme, String action})>[
      if (vremePre != null) (vreme: vremePre, action: 'accept_pre'),
      if (vremePosle != null) (vreme: vremePosle, action: 'accept_posle'),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: V3ContainerUtils.styledContainer(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        backgroundColor: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              opis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            if (preostalo != null) ...[
              const SizedBox(height: 4),
              _PonudaCountdown(
                offeredAt: ts,
                template: _tr('ponudaIsticeSekunde'),
                onExpired: _scheduleRefresh,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              _tr('alternativaIzaberi'),
              textAlign: TextAlign.center,
              style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 11),
            ),
            const SizedBox(height: 8),
            // Tri Expanded dugmeta u jednom redu su suviše uska — "06:00"
            // se na ~88px truncate-uje u "0...". Opcije zauzimaju ceo red
            // (svaka ~1/2 širine), a odbijanje ide ispod na punu širinu.
            if (opcije.isNotEmpty)
              Row(
                children: [
                  for (var i = 0; i < opcije.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: V3ButtonUtils.outlinedButton(
                        onPressed: busy ? null : () => _odgovoriNaPonudu(zahtev, action: opcije[i].action),
                        text: opcije[i].vreme,
                        icon: Icons.check_circle_outline,
                        borderColor: Colors.greenAccent,
                        foregroundColor: Colors.greenAccent,
                        fontSize: 13,
                        borderRadius: BorderRadius.circular(8),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                      ),
                    ),
                  ],
                ],
              ),
            if (opcije.isNotEmpty) const SizedBox(height: 8),
            V3ButtonUtils.outlinedButton(
              onPressed: busy ? null : () => _odgovoriNaPonudu(zahtev, action: 'reject'),
              text: _tr('mestoOdbij'),
              icon: Icons.cancel_outlined,
              borderColor: Colors.redAccent,
              foregroundColor: Colors.redAccent,
              fontSize: 13,
              borderRadius: BorderRadius.circular(8),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
            ),
          ],
        ),
      ),
    );
  }

  // ─── STATUS WIDGET ───────────────────────────────────────────────
  // ─────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final putnikId = _currentPutnikId();
    final profilStats = _profilStats(putnikId);
    final previousMonthDebt = profilStats.prevMonthDebt;
    final hasPreviousMonthDebtLock = previousMonthDebt > 0.009;
    final tip = _putnikData['tip_putnika'] as String? ?? 'radnik';
    final cenaPoDanu = (_putnikData['cena_po_danu'] as num?)?.toDouble() ?? 0.0;
    final cenaPoPokupljenju = (_putnikData['cena_po_pokupljenju'] as num?)?.toDouble() ?? 0.0;
    final koristiCenuPoPokupljenju = tip == 'dnevni' || tip == 'posiljka';
    final efektivnaCena = koristiCenuPoPokupljenju ? cenaPoPokupljenju : cenaPoDanu;
    final cenaInfo = efektivnaCena > 0
        ? '${koristiCenuPoPokupljenju ? _tr('cenaPoVoznji') : _tr('cenaPoDanu')}: ${efektivnaCena.toStringAsFixed(0)} RSD'
        : null;
    final imePrezime = _putnikData['ime_prezime'] as String? ?? '';
    final telefon = _putnikData['telefon_1'] as String? ?? '';
    final telefon2 = _putnikData['telefon_2'] as String? ?? '';
    final adresaBcId = _putnikData['adresa_bc_id'] as String?;
    final adresaVsId = _putnikData['adresa_vs_id'] as String?;
    final adresaBcId2 = _putnikData['adresa_bc_id_2'] as String?;
    final adresaVsId2 = _putnikData['adresa_vs_id_2'] as String?;
    final adresaBcNaziv = V3AdresaService.getNazivAdreseById(adresaBcId);
    final adresaVsNaziv = V3AdresaService.getNazivAdreseById(adresaVsId);
    final adresaBcNaziv2 = V3AdresaService.getNazivAdreseById(adresaBcId2);
    final adresaVsNaziv2 = V3AdresaService.getNazivAdreseById(adresaVsId2);
    final nedeljaOpseg = _formatNedeljaOpsegLabel();
    final nedeljaInfo = '${_tr('operativnaNedelja')}: $nedeljaOpseg';
    return ValueListenableBuilder<Locale>(
      valueListenable: V3LocaleManager().localeNotifier,
      builder: (context, __, ___) => ValueListenableBuilder<ThemeData>(
        valueListenable: V3ThemeManager().themeNotifier,
        builder: (context, _, __) {
          final stats = profilStats.tekuci;
          final ukupanDug = profilStats.ukupanDug;
          final ukupanVisak = profilStats.ukupanVisak;

          return V3ContainerUtils.backgroundContainer(
              gradient: V3ThemeManager().currentGradient,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: PreferredSize(
                  preferredSize: Size.zero,
                  child: AppBar(
                    toolbarHeight: 0,
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    systemOverlayStyle: const SystemUiOverlayStyle(
                      statusBarColor: Colors.transparent,
                      statusBarIconBrightness: Brightness.light,
                      statusBarBrightness: Brightness.dark,
                      systemNavigationBarColor: Colors.transparent,
                      systemNavigationBarIconBrightness: Brightness.light,
                    ),
                  ),
                ),
                body: SafeArea(
                  child: Stack(
                    children: [
                      AbsorbPointer(
                        absorbing: hasPreviousMonthDebtLock,
                        child: RefreshIndicator(
                          onRefresh: _pullRefresh,
                          color: Colors.white,
                          backgroundColor: const Color(0xFF1F2430),
                          child: SingleChildScrollView(
                            // AlwaysScrollable — RefreshIndicator mora da
                            // može da se povuče i kad je sadržaj kraći od ekrana.
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Forced update gate
                                const V3UpdateBanner(),
                                // ── HEADER CARD ──────────────────────────────────────
                                V3FadeSlideIn(
                                  child: _buildHeaderCard(
                                    tip: tip,
                                    imePrezime: imePrezime,
                                    telefon: telefon,
                                    telefon2: telefon2,
                                    adresaBcNaziv: adresaBcNaziv,
                                    adresaVsNaziv: adresaVsNaziv,
                                    adresaBcNaziv2: adresaBcNaziv2,
                                    adresaVsNaziv2: adresaVsNaziv2,
                                  ),
                                ),
                                if (!_criticalDataLoaded) ...[
                                  const SizedBox(height: 12),
                                  _buildSkeletonCard(height: 86),
                                  const SizedBox(height: 10),
                                  _buildSkeletonCard(height: 170),
                                  const SizedBox(height: 10),
                                  _buildSkeletonCard(height: 300),
                                ] else ...[
                                  _animatedSection(
                                    visible: putnikId != null && putnikId.isNotEmpty,
                                    delay: const Duration(milliseconds: 70),
                                    child: V3VremeDolaskaWidget(putnikId: putnikId ?? ''),
                                  ),
                                  _animatedSection(
                                    visible: _aktivnePonude.isNotEmpty,
                                    delay: const Duration(milliseconds: 130),
                                    child: _buildMestoPonudaCard(),
                                  ),
                                  _animatedSection(
                                    visible: _aktivneAlternative.isNotEmpty,
                                    delay: const Duration(milliseconds: 170),
                                    child: _buildAlternativaCard(),
                                  ),
                                  const SizedBox(height: 16),
                                  V3FadeSlideIn(
                                    delay: const Duration(milliseconds: 210),
                                    child: _buildStatistikaCard(
                                      tip: tip,
                                      stats: stats,
                                      cenaInfo: cenaInfo,
                                      ukupanDug: ukupanDug,
                                      ukupanVisak: ukupanVisak,
                                      dnevneStavke: profilStats.dnevne,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  V3FadeSlideIn(
                                    delay: const Duration(milliseconds: 260),
                                    child: _buildDetaljneStatistikeSection(
                                      putnikId: putnikId,
                                      imePrezime: imePrezime,
                                      tipPutnika: tip,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  // ── RASPORED TERMINA ─────────────────────────────────
                                  V3FadeSlideIn(
                                    delay: const Duration(milliseconds: 320),
                                    child: _buildRasporedCard(nedeljaInfo: nedeljaInfo),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        left: 16,
                        right: 16,
                        child: const V3InfoBanner(),
                      ),
                      if (hasPreviousMonthDebtLock)
                        Positioned.fill(
                          child: _buildPreviousMonthDebtLockOverlay(previousMonthDebt),
                        ),
                      // Logout mora ostati dostupan i pod debt lock-om — inače
                      // putnik ne može da se odjavi (npr. drugi nalog na istom
                      // telefonu) dok ne plati dug.
                      if (hasPreviousMonthDebtLock)
                        Positioned(
                          top: 8,
                          right: 16,
                          child: Material(
                            color: Colors.black.withValues(alpha: 0.5),
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: const Icon(Icons.logout, color: Colors.redAccent),
                              tooltip: _tr('odjava'),
                              onPressed: _logout,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // WIDGETS
  // ─────────────────────────────────────────────────────────────────

  /// Uslovna sekcija — "rasklopi se" (size + fade animacija) umesto naglog
  /// pojavljivanja kad podatak stigne preko realtime-a. Child se montira
  /// tek kad postane vidljiv pa V3FadeSlideIn odradi entrance.
  Widget _animatedSection({
    required bool visible,
    required Widget child,
    Duration delay = Duration.zero,
  }) {
    return AnimatedCrossFade(
      firstChild: const SizedBox(width: double.infinity),
      secondChild: visible
          ? V3FadeSlideIn(
              delay: delay,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: child,
              ),
            )
          : const SizedBox(width: double.infinity),
      crossFadeState: visible ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 320),
      sizeCurve: Curves.easeInOut,
      firstCurve: Curves.easeOut,
      secondCurve: Curves.easeIn,
    );
  }

  Widget _buildPreviousMonthDebtLockOverlay(double dugIznos) {
    final formatiranIznos = _formatWholeRsd(dugIznos);
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: V3ContainerUtils.styledContainer(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
            backgroundColor: const Color(0xFF1F2430).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.orange.withValues(alpha: 0.45), width: 1.2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_outline, color: Colors.orange, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        V3PutnikProfilMessages.previousMonthDebtTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  V3PutnikProfilMessages.previousMonthDebtLocked(_giroRacun),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 13.5, height: 1.3),
                ),
                const SizedBox(height: 8),
                Text(
                  V3PutnikProfilMessages.previousMonthDebtAmount(formatiranIznos),
                  style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700, fontSize: 14),
                ),
                const SizedBox(height: 12),
                V3ContainerUtils.styledContainer(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  backgroundColor: Colors.black.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _giroRacun,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            letterSpacing: 0.3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      V3ButtonUtils.textButton(
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: _giroRacun));
                          if (!mounted) return;
                          V3AppSnackBar.success(context, V3PutnikProfilMessages.giroAccountCopied);
                        },
                        text: V3PutnikProfilMessages.copyGiroAccount,
                        foregroundColor: Colors.amber,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard({
    required String tip,
    required String imePrezime,
    required String telefon,
    String telefon2 = '',
    required String? adresaBcNaziv,
    required String? adresaVsNaziv,
    String? adresaBcNaziv2,
    String? adresaVsNaziv2,
  }) {
    final tipLabel = _tipLabel(tip);
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(20),
      backgroundColor: V3StyleHelper.whiteAlpha06,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: V3StyleHelper.whiteAlpha13),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Text('🎨', style: TextStyle(fontSize: 18)),
                tooltip: _tr('tema'),
                onPressed: () async {
                  await V3ThemeManager().nextTheme();
                  V3StateUtils.safeSetState(this, () {});
                  if (!mounted) return;
                  V3AppSnackBar.info(context, V3PutnikProfilMessages.themeChanged);
                },
              ),
              const Spacer(),
              _buildLanguageFlag(),
              const Spacer(),
              IconButton(
                icon: const Text('✏️', style: TextStyle(fontSize: 18)),
                tooltip: _tr('izmeniProfil'),
                onPressed: _showEditProfilDialog,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.red),
                tooltip: _tr('odjava'),
                onPressed: _logout,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _WeatherMiniCell(snapshot: _weatherByGrad['BC'], grad: 'BC'),
                ),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _WeatherMiniCell(snapshot: _weatherByGrad['VS'], grad: 'VS'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  imePrezime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Tip putnika (radnik/učenik/dnevni/pošiljka) — korisna info,
          // labela je ranije računata ali nigde prikazana.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: V3StyleHelper.whiteAlpha05,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              tipLabel,
              style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          if (telefon.isNotEmpty || telefon2.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.phone, color: Colors.white54, size: 13),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    [
                      if (telefon.isNotEmpty) _formatPhoneDisplay(telefon),
                      if (telefon2.isNotEmpty) _formatPhoneDisplay(telefon2),
                    ].join('  •  '),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: V3StyleHelper.whiteAlpha9,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          // Adrese
          if (adresaBcNaziv != null || adresaVsNaziv != null) ...[
            const SizedBox(height: 12),
            Divider(color: V3StyleHelper.whiteAlpha15),
            const SizedBox(height: 8),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // BC kolona
                  if (adresaBcNaziv != null && adresaBcNaziv.isNotEmpty)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.location_city, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(_tr('belaCrkva'),
                                style: TextStyle(
                                    color: V3StyleHelper.whiteAlpha45, fontSize: 14, fontWeight: FontWeight.bold)),
                          ]),
                          const SizedBox(height: 3),
                          Row(children: [
                            const Icon(Icons.home, color: Colors.white60, size: 14),
                            const SizedBox(width: 4),
                            Expanded(
                                child: Text(adresaBcNaziv,
                                    style: TextStyle(color: V3StyleHelper.whiteAlpha9, fontSize: 14))),
                          ]),
                          if (adresaBcNaziv2 != null && adresaBcNaziv2.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              const Icon(Icons.home_outlined, color: Colors.white60, size: 14),
                              const SizedBox(width: 4),
                              Expanded(
                                  child: Text(adresaBcNaziv2,
                                      style: TextStyle(color: V3StyleHelper.whiteAlpha9, fontSize: 14))),
                            ]),
                          ],
                        ],
                      ),
                    ),
                  if (adresaBcNaziv != null && adresaVsNaziv != null)
                    Container(
                        width: 1,
                        color: Colors.white12,
                        margin: const EdgeInsets.symmetric(horizontal: 10)),
                  // VS kolona
                  if (adresaVsNaziv != null && adresaVsNaziv.isNotEmpty)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.location_city, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(_tr('vrsac'),
                                style: TextStyle(
                                    color: V3StyleHelper.whiteAlpha45, fontSize: 14, fontWeight: FontWeight.bold)),
                          ]),
                          const SizedBox(height: 3),
                          Row(children: [
                            const Icon(Icons.work, color: Colors.white60, size: 14),
                            const SizedBox(width: 4),
                            Expanded(
                                child: Text(adresaVsNaziv,
                                    style: TextStyle(color: V3StyleHelper.whiteAlpha9, fontSize: 14))),
                          ]),
                          if (adresaVsNaziv2 != null && adresaVsNaziv2.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              const Icon(Icons.work_outline, color: Colors.white60, size: 14),
                              const SizedBox(width: 4),
                              Expanded(
                                  child: Text(adresaVsNaziv2,
                                      style: TextStyle(color: V3StyleHelper.whiteAlpha9, fontSize: 14))),
                            ]),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatistikaCard({
    required String tip,
    required V3PutnikMesecnaStatistika stats,
    String? cenaInfo,
    required double ukupanDug,
    required double ukupanVisak,
    required List<V3PutnikDnevnaStavka> dnevneStavke,
  }) {
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(16),
      backgroundColor: V3StyleHelper.whiteAlpha06,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: V3StyleHelper.whiteAlpha13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              stats.mesecNaziv,
              style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _tr('stanjeVoznji'),
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
          if (cenaInfo != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                cenaInfo,
                textAlign: TextAlign.center,
                style: TextStyle(color: V3StyleHelper.whiteAlpha9, fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            _modelNaplataLabel(tip),
            style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _kpiTile(_tr('voznji'), '${stats.ukupnoVoznji}', Colors.greenAccent),
                const SizedBox(width: 12),
                _kpiTile(_tr('otkazano'), '${stats.otkazano}', Colors.redAccent),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(color: V3StyleHelper.whiteAlpha15),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_tr('placeno'), style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 13)),
              Text(
                '${stats.naplacenoIznos.toStringAsFixed(0)} RSD',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_tr('dug'), style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 13)),
              Text(
                '${stats.dugIznos.toStringAsFixed(0)} RSD',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_tr('ukupanDug'), style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 13)),
              Text(
                '${ukupanDug.toStringAsFixed(0)} RSD',
                style: const TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          if (ukupanVisak > 0.009) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_tr('ukupanVisak'), style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 13)),
                Text(
                  '${ukupanVisak.toStringAsFixed(0)} RSD',
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
          if (stats.poslednjaUplata != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_tr('poslednjaUplata'), style: TextStyle(color: V3StyleHelper.whiteAlpha75, fontSize: 13)),
                Text(
                  '${stats.poslednjaUplata!.day.toString().padLeft(2, '0')}.${stats.poslednjaUplata!.month.toString().padLeft(2, '0')}.',
                  style: const TextStyle(color: Colors.blueAccent, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
          // Žiro račun na dohvat ruke dok postoji dug — putnik ne mora da
          // čeka debt-lock da sazna kako da uplati. Tap kopira broj.
          if (ukupanDug > 0.009 || stats.dugIznos > 0.009) ...[
            const SizedBox(height: 10),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  Clipboard.setData(const ClipboardData(text: _giroRacun));
                  V3AppSnackBar.success(context, V3PutnikProfilMessages.giroAccountCopied);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_outlined, color: Colors.amber, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _tr('ziroRacunZaUplatu'),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        _giroRacun,
                        style: TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.copy_rounded, color: Colors.amber, size: 14),
                    ],
                  ),
                ),
              ),
            ),
          ],
          // Mini bar-chart vožnji po danima — vizuelni pregled meseca bez
          // odlaska na detaljnu statistiku.
          if (dnevneStavke.any((d) => d.brojVoznji > 0)) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 100,
              child: _buildVoznjeChart(dnevneStavke),
            ),
          ],
          // 'Otkazano' se ne ponavlja u listi — KPI tile gore prikazuje istu vrednost.
        ],
      ),
    );
  }

  Widget _buildVoznjeChart(List<V3PutnikDnevnaStavka> stavke) {
    final dani = stavke.where((d) => d.brojVoznji > 0).toList();
    final maxVoznji = dani.fold<int>(0, (m, d) => d.brojVoznji > m ? d.brojVoznji : m);
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxVoznji + 0.5,
        barTouchData: BarTouchData(enabled: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 16,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= dani.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '${dani[i].datum.day}',
                    style: const TextStyle(color: Colors.white38, fontSize: 9),
                  ),
                );
              },
            ),
          ),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < dani.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: dani[i].brojVoznji.toDouble(),
                  color: Colors.greenAccent.withValues(alpha: 0.85),
                  width: dani.length > 14 ? 7 : 10,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                ),
              ],
            ),
        ],
      ),
      swapAnimationDuration: const Duration(milliseconds: 300),
      swapAnimationCurve: Curves.easeInOut,
    );
  }

  Widget _kpiTile(String label, String value, Color color) {
    return V3ContainerUtils.styledContainer(
      width: 90,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      backgroundColor: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      child: Column(
        children: [
          Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  String _modelNaplataLabel(String tip) {
    final normalized = tip.toLowerCase();
    if (normalized == 'radnik' || normalized == 'ucenik') {
      return _tr('modelCenaPoDanu');
    }
    return _tr('modelCenaPoVoznji');
  }

  Widget _buildDetaljneStatistikeSection({
    required String? putnikId,
    required String imePrezime,
    required String tipPutnika,
  }) {
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(12),
      backgroundColor: V3StyleHelper.whiteAlpha06,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: V3StyleHelper.whiteAlpha13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _tr('detaljneStatistike'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            _tr('pregledPoMesecima'),
            textAlign: TextAlign.center,
            style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 12),
          ),
          const SizedBox(height: 10),
          V3ButtonUtils.outlinedButton(
            onPressed: (putnikId == null || putnikId.isEmpty)
                ? null
                : () {
                    Navigator.of(context).push(
                      V3SmoothPageRoute<void>(
                        screen: V3PutnikStatistikaScreen(
                          putnikId: putnikId,
                          imePrezime: imePrezime,
                          tipPutnika: tipPutnika,
                        ),
                      ),
                    );
                  },
            text: _tr('otvoriDetaljneStatistike'),
            icon: Icons.analytics_outlined,
            borderColor: Colors.white30,
            foregroundColor: Colors.white,
            borderRadius: BorderRadius.circular(10),
            fontSize: 13,
          ),
        ],
      ),
    );
  }

  Widget _buildRasporedCard({required String nedeljaInfo}) {
    final dani = V3DanHelper.workdayAbbrs.toList(); // pon-pet (radni dani)
    return V3ContainerUtils.styledContainer(
      padding: const EdgeInsets.all(16),
      backgroundColor: V3StyleHelper.whiteAlpha06,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: V3StyleHelper.whiteAlpha13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              nedeljaInfo,
              style: TextStyle(
                color: V3StyleHelper.whiteAlpha75,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              _tr('rasporedTermina'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Header
          Row(
            children: [
              const SizedBox(width: 96),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'BC',
                        style: TextStyle(
                          color: V3StyleHelper.whiteAlpha65,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '(${_tr('belaCrkva')})',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'VS',
                        style: TextStyle(
                          color: V3StyleHelper.whiteAlpha65,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '(${_tr('vrsac')})',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: V3StyleHelper.whiteAlpha1),
          ...dani.map((dan) {
            final infos = _rasporedMap[dan] ?? [];
            final bcInfo = infos.where((i) => i.grad == 'BC').firstOrNull;
            final vsInfo = infos.where((i) => i.grad == 'VS').firstOrNull;
            // Prošli dan u tekućoj sedmici — svi termini su zaključani, pa se
            // "➕ dodaj" ne nudi (ćelija je samo informativna).
            final datumIso = V3DanHelper.datumIsoZaDanAbbrUTekucojSedmici(
              dan,
              anchor: V3DanHelper.schedulingWeekAnchor(),
            );
            final isPast = datumIso.isNotEmpty && datumIso.compareTo(V3BelgradeTime.todayIso()) < 0;
            final isToday = datumIso.isNotEmpty && datumIso == V3BelgradeTime.todayIso();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: isToday
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.lightBlueAccent.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(color: Colors.lightBlueAccent.withValues(alpha: 0.55)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getDanLabel(dan),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  _tr('danas'),
                                  style: TextStyle(
                                    color: Colors.lightBlueAccent.withValues(alpha: 0.85),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Text(
                            _getDanLabel(dan),
                            style: TextStyle(
                                color: isPast ? V3StyleHelper.whiteAlpha45 : Colors.white, fontSize: 13),
                          ),
                  ),
                  Expanded(
                    child: Center(
                      child: _ZahtevCell(
                        info: bcInfo,
                        disabled: isPast,
                        busy: _pendingActionContexts.contains('${_currentPutnikId()}|$dan|BC'),
                        onTap: () => _showTimePicker(context, dan, 'BC', bcInfo),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: _ZahtevCell(
                        info: vsInfo,
                        disabled: isPast,
                        busy: _pendingActionContexts.contains('${_currentPutnikId()}|$dan|VS'),
                        onTap: () => _showTimePicker(context, dan, 'VS', vsInfo),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────
  /// '+381641234567' → '+381 64 123 45 67' (grupe po 2-3 cifre, čitljivije).
  String _formatPhoneDisplay(String phone) {
    final n = V3PhoneUtils.normalize(phone);
    if (!n.startsWith('+381') || n.length < 9) return n.isEmpty ? phone : n;
    final rest = n.substring(4); // cifre posle +381
    final parts = <String>[];
    var i = 0;
    // Prva grupa 2 cifre (mreža), ostalo po 3.
    final firstLen = rest.length <= 8 ? 2 : 3;
    parts.add(rest.substring(0, firstLen));
    i = firstLen;
    while (i < rest.length) {
      parts.add(rest.substring(i, i + 3 > rest.length ? rest.length : i + 3));
      i += 3;
    }
    return '+381 ${parts.join(' ')}';
  }

  String _tipLabel(String tip) {
    switch (tip.toLowerCase()) {
      case 'ucenik':
        return _tr('tipUcenik');
      case 'posiljka':
        return _tr('tipPosiljka');
      case 'dnevni':
        return _tr('tipDnevni');
      case 'radnik':
        return _tr('tipRadnik');
      default:
        return _tr('tipPutnik');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Helper data class
// ─────────────────────────────────────────────────────────────────────
class _ZahtevInfo {
  final String grad;
  final String vreme;
  final String status;
  final bool pokupljen;
  final bool koristiSekundarnu;
  const _ZahtevInfo({
    required this.grad,
    required this.vreme,
    required this.status,
    this.pokupljen = false,
    this.koristiSekundarnu = false,
  });
}

// ─────────────────────────────────────────────────────────────────────
// Small widgets
// ─────────────────────────────────────────────────────────────────────
class _WeatherMiniCell extends StatelessWidget {
  final V3WeatherSnapshot? snapshot;
  final String grad;

  const _WeatherMiniCell({required this.snapshot, required this.grad});

  @override
  Widget build(BuildContext context) {
    final data = snapshot;
    final labelStyle = TextStyle(
      color: V3StyleHelper.whiteAlpha5,
      fontSize: 18,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );

    if (data == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(grad, style: labelStyle),
          const SizedBox(width: 4),
          Text(
            '—',
            style: TextStyle(
              color: V3StyleHelper.whiteAlpha5,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    final temp = '${data.temperatureC.round()}°';
    final rain = data.precipitationProbability != null ? ' · ${data.precipitationProbability}%' : '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(grad, style: labelStyle),
        const SizedBox(width: 4),
        Icon(
          data.iconData,
          size: 18,
          color: data.iconColor,
        ),
        const SizedBox(width: 4),
        Text(
          '$temp$rain',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ZahtevCell extends StatelessWidget {
  final _ZahtevInfo? info;
  final VoidCallback? onTap;
  final bool disabled;

  /// Akcija (sacuvaj/otkazi polazak) za ovaj kontekst je na mrezi — umesto
  /// sadrzaja celije prikazujemo spinner da korisnik vidi da tap radi.
  final bool busy;
  const _ZahtevCell({this.info, this.onTap, this.disabled = false, this.busy = false});

  static const Widget _busyIndicator = SizedBox(
    height: 14,
    width: 14,
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return V3ContainerUtils.styledContainer(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        backgroundColor: V3StyleHelper.whiteAlpha25,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: V3StyleHelper.whiteAlpha5),
        child: const Center(child: _busyIndicator),
      );
    }
    if (info == null) {
      if (disabled) {
        // Prošli dan bez termina — samo crtica, bez "dodaj" poziva na akciju.
        return V3ContainerUtils.styledContainer(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          backgroundColor: V3StyleHelper.whiteAlpha05,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
          child: Text(
            '—',
            textAlign: TextAlign.center,
            style: TextStyle(color: V3StyleHelper.whiteAlpha45, fontSize: 12),
          ),
        );
      }
      return GestureDetector(
        onTap: onTap,
        child: V3ContainerUtils.styledContainer(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          backgroundColor: V3StyleHelper.whiteAlpha25,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: V3StyleHelper.whiteAlpha5),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              Expanded(
                child: Text(
                  _trProfileDialog('dodaj'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final badgeStyle = V3StatusPolicy.badgeForCell(
      status: info!.status,
      pokupljen: info!.pokupljen,
    );
    final statusColor = badgeStyle.color;
    final statusIcon = badgeStyle.icon;
    final vreme = V3BelgradeTime.normalizeToHHmm(info!.vreme);
    final statusPrefix = '$statusIcon ';
    return GestureDetector(
      onTap: onTap,
      child: V3ContainerUtils.styledContainer(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        backgroundColor: statusColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.90),
          width: 1.2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Expanded(
              child: Text(
                '$statusPrefix$vreme',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: V3StyleHelper.whiteAlpha9,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Živi countdown (m:ss) za istek ponude mesta/alternative — tekst se
/// osvežava svake sekunde umesto statičnog "~X min" koji zastareva dok je
/// ekran otvoren. Po isteku zove [onExpired] da se kartica povuče lokalno,
/// bez čekanja na realtime/server.
class _PonudaCountdown extends StatefulWidget {
  const _PonudaCountdown({required this.offeredAt, required this.template, required this.onExpired});

  /// ISO timestamp kad je ponuda napravljena (mesto_ponuda_at /
  /// alternativa_offered_at / updated_at fallback). Važenje je 10 min —
  /// isto kao _preostaloMinutaZaPonudu i server.
  final String? offeredAt;

  /// Template sa %s placeholder-om (npr. 'Ponuda ističe za %s').
  final String template;
  final VoidCallback onExpired;

  @override
  State<_PonudaCountdown> createState() => _PonudaCountdownState();
}

class _PonudaCountdownState extends State<_PonudaCountdown> {
  static const Duration _validity = Duration(minutes: 10);
  Timer? _timer;
  bool _expiredFired = false;

  int _remainingSeconds() {
    final offeredAt = V3BelgradeTime.parseTs(widget.offeredAt);
    if (offeredAt == null) return -1;
    return offeredAt.add(_validity).difference(DateTime.now()).inSeconds;
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remainingSeconds() <= 0 && !_expiredFired) {
        _expiredFired = true;
        widget.onExpired();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = _remainingSeconds().clamp(0, 600);
    final label = '${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}';
    return Text(
      widget.template.replaceAll('%s', label),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: remaining <= 60 ? Colors.orangeAccent : V3StyleHelper.whiteAlpha65,
        fontSize: 11,
        fontWeight: remaining <= 60 ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }
}

// ─── EDIT PROFIL DIALOG ─────────────────────────────────────────────────────
class _EditProfilDialog extends StatefulWidget {
  final Map<String, dynamic> putnikData;
  final ValueChanged<Map<String, dynamic>> onSaved;

  const _EditProfilDialog({required this.putnikData, required this.onSaved});

  @override
  State<_EditProfilDialog> createState() => _EditProfilDialogState();
}

class _EditProfilDialogState extends State<_EditProfilDialog> {
  late final TextEditingController _ime = TextEditingController(
    text: widget.putnikData['ime_prezime']?.toString() ?? '',
  );
  late final TextEditingController _tel1 = TextEditingController(
    text: widget.putnikData['telefon_1']?.toString() ?? '',
  );
  late final TextEditingController _tel2 = TextEditingController(
    text: widget.putnikData['telefon_2']?.toString() ?? '',
  );

  // Stalne adrese putnika (ne override / ne za jednu vožnju).
  V3Adresa? _adresaBc1;
  V3Adresa? _adresaBc2;
  V3Adresa? _adresaVs1;
  V3Adresa? _adresaVs2;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _adresaBc1 = V3AdresaService.getAdresaById(widget.putnikData['adresa_bc_id']?.toString());
    _adresaBc2 = V3AdresaService.getAdresaById(widget.putnikData['adresa_bc_id_2']?.toString());
    _adresaVs1 = V3AdresaService.getAdresaById(widget.putnikData['adresa_vs_id']?.toString());
    _adresaVs2 = V3AdresaService.getAdresaById(widget.putnikData['adresa_vs_id_2']?.toString());
  }

  @override
  void dispose() {
    _ime.dispose();
    _tel1.dispose();
    _tel2.dispose();
    super.dispose();
  }

  V3Adresa? _matchFromList(List<V3Adresa> list, V3Adresa? current) {
    if (current == null) return null;
    for (final a in list) {
      if (a.id == current.id) return a;
    }
    // Adresa više nije u listi (obrisana/drugi grad) — NE vraćati 'current':
    // DropdownButtonFormField assert-uje ako value nije među items.
    // State (_adresaBc1/…) i dalje drži original pa se id čuva pri save-u.
    return null;
  }

  Widget _adresaDropdown({
    required String label,
    required String grad,
    required V3Adresa? value,
    required ValueChanged<V3Adresa?> onChanged,
    required bool allowClear,
  }) {
    final adrese = V3AdresaService.getAdreseZaGrad(grad);
    final resolved = _matchFromList(adrese, value);

    return DropdownButtonFormField<V3Adresa>(
      value: resolved,
      isExpanded: true,
      dropdownColor: V3InputStyle.dropdownMenu,
      style: V3InputUtils.fieldTextStyle,
      decoration: V3InputUtils.dropdownDecoration(
        label: label,
        icon: grad == 'BC' ? Icons.location_city_outlined : Icons.location_on_outlined,
        prefixIconColor: grad == 'BC' ? const Color(0xFF2563EB) : const Color(0xFFEA580C),
        suffixIcon: allowClear && resolved != null
            ? IconButton(
                icon: const Icon(Icons.clear, size: 18, color: V3InputStyle.label),
                onPressed: _saving ? null : () => onChanged(null),
              )
            : null,
      ),
      hint: Text(
        _trProfileDialog('nijeOdabrano'),
        style: const TextStyle(fontSize: 13, color: V3InputStyle.label),
      ),
      items: adrese
          .map(
            (a) => DropdownMenuItem<V3Adresa>(
              value: a,
              child: V3SafeText.userAddress(
                a.naziv,
                style: const TextStyle(fontSize: 13, color: V3InputStyle.text),
              ),
            ),
          )
          .toList(),
      onChanged: _saving ? null : onChanged,
    );
  }

  Widget _adresaSectionHeader({
    required String title,
    required Color accent,
    required IconData icon,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: accent),
          ),
        ],
      ),
    );
  }

  Future<void> _sacuvaj() async {
    final imeVal = _ime.text.trim();
    final tel1Raw = _tel1.text.trim();
    final tel2Raw = _tel2.text.trim();

    if (imeVal.isEmpty) {
      V3AppSnackBar.error(context, _trProfileDialog('imeNeSmeBitiPrazno'));
      return;
    }
    // Validacija PRE normalizacije — normalizeOrNull bez provere je nevalidan
    // unos ('abc' → '', '123' → '123') tiho upisivao u bazu i time pokvario/
    // obrisao broj preko koga se putnik identifikuje pri loginu.
    if (tel1Raw.isNotEmpty && !V3PhoneUtils.isValid(tel1Raw)) {
      V3AppSnackBar.error(context, _trProfileDialog('telefonNijeIspravan'));
      return;
    }
    if (tel2Raw.isNotEmpty && !V3PhoneUtils.isValid(tel2Raw)) {
      V3AppSnackBar.error(context, _trProfileDialog('telefonNijeIspravan'));
      return;
    }
    // Bar jedan telefon mora ostati — telefon je login identitet
    // (v3_auth_find_id_by_phone), brisanje oba = self-lockout bez
    // mogućnosti ponovne prijave.
    if (tel1Raw.isEmpty && tel2Raw.isEmpty) {
      V3AppSnackBar.error(context, _trProfileDialog('barJedanTelefon'));
      return;
    }
    final tel1Val = V3PhoneUtils.normalizeOrNull(tel1Raw);
    final tel2Val = V3PhoneUtils.normalizeOrNull(tel2Raw);
    if (_adresaBc1 == null || _adresaVs1 == null) {
      V3AppSnackBar.error(context, _trProfileDialog('obavezneAdrese'));
      return;
    }

    V3StateUtils.safeSetState(this, () => _saving = true);
    try {
      final updated = Map<String, dynamic>.from(widget.putnikData)
        ..['ime_prezime'] = imeVal
        ..['telefon_1'] = tel1Val
        ..['telefon_2'] = tel2Val
        ..['adresa_bc_id'] = _adresaBc1?.id
        ..['adresa_bc_id_2'] = _adresaBc2?.id
        ..['adresa_vs_id'] = _adresaVs1?.id
        ..['adresa_vs_id_2'] = _adresaVs2?.id;

      final putnik = V3Putnik.fromJson(updated);
      await V3PutnikService.addUpdatePutnik(
        putnik,
        updatedBy: putnik.id,
      ).timeout(const Duration(seconds: 20));

      // Telefon je login identitet — auto-login restore traži auth id po
      // sačuvanom broju u SecureStorage. Ako se broj promenio a sesija ne,
      // sledeći cold start tiho baca putnika na welcome ekran.
      final authId = widget.putnikData['id']?.toString().trim() ?? '';
      final stariTel1 =
          V3PhoneUtils.normalizeOrNull(widget.putnikData['telefon_1']?.toString());
      final stariTel2 =
          V3PhoneUtils.normalizeOrNull(widget.putnikData['telefon_2']?.toString());
      if (authId.isNotEmpty && (tel1Val != stariTel1 || tel2Val != stariTel2)) {
        unawaited(() async {
          final sessionPhone = tel1Val ?? tel2Val;
          if (sessionPhone != null) {
            await V3ClosedAuthService.saveManualSmsPutnikSession(
              normalizedPhone: sessionPhone,
              authId: authId,
            );
          } else {
            await V3ClosedAuthService.clearManualSmsPutnikPhone();
          }
        }());
      }

      if (!mounted) return;
      V3AppSnackBar.success(context, _trProfileDialog('profilSacuvan'));
      widget.onSaved(updated);
      Navigator.pop(context);
    } catch (e) {
      V3AppSnackBar.error(context, '${_trProfileDialog('greska')}: $e');
    } finally {
      V3StateUtils.safeSetState(this, () => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gradient = theme.backgroundGradient;

    return Dialog(
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(gradient: gradient),
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(Icons.edit_outlined, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _trProfileDialog('izmeniProfilTitle'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            _trProfileDialog('azurirajImeTel'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // ── Content ──
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      V3InputUtils.textField(
                        controller: _ime,
                        label: _trProfileDialog('imePrezime'),
                        icon: Icons.person_outline,
                        keyboardType: TextInputType.name,
                      ),
                      const SizedBox(height: 12),
                      V3InputUtils.textField(
                        controller: _tel1,
                        label: _trProfileDialog('telefon1'),
                        icon: Icons.phone_outlined,
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 12),
                      V3InputUtils.textField(
                        controller: _tel2,
                        label: _trProfileDialog('telefon2'),
                        icon: Icons.phone_iphone_outlined,
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 16),
                      _adresaSectionHeader(
                        title: _trProfileDialog('adreseBc'),
                        accent: Colors.lightBlueAccent,
                        icon: Icons.location_city,
                      ),
                      const SizedBox(height: 8),
                      _adresaDropdown(
                        label: _trProfileDialog('bcAdresa1'),
                        grad: 'BC',
                        value: _adresaBc1,
                        allowClear: false,
                        onChanged: (v) => V3StateUtils.safeSetState(this, () => _adresaBc1 = v),
                      ),
                      const SizedBox(height: 8),
                      _adresaDropdown(
                        label: _trProfileDialog('bcAdresa2'),
                        grad: 'BC',
                        value: _adresaBc2,
                        allowClear: true,
                        onChanged: (v) => V3StateUtils.safeSetState(this, () => _adresaBc2 = v),
                      ),
                      const SizedBox(height: 14),
                      _adresaSectionHeader(
                        title: _trProfileDialog('adreseVs'),
                        accent: Colors.orangeAccent,
                        icon: Icons.location_on,
                      ),
                      const SizedBox(height: 8),
                      _adresaDropdown(
                        label: _trProfileDialog('vsAdresa1'),
                        grad: 'VS',
                        value: _adresaVs1,
                        allowClear: false,
                        onChanged: (v) => V3StateUtils.safeSetState(this, () => _adresaVs1 = v),
                      ),
                      const SizedBox(height: 8),
                      _adresaDropdown(
                        label: _trProfileDialog('vsAdresa2'),
                        grad: 'VS',
                        value: _adresaVs2,
                        allowClear: true,
                        onChanged: (v) => V3StateUtils.safeSetState(this, () => _adresaVs2 = v),
                      ),
                      const SizedBox(height: 16),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _saving
                              ? null
                              : () async {
                                  final authId = widget.putnikData['id']?.toString().trim() ?? '';
                                  if (authId.isEmpty) return;
                                  await V3DialogHelper.showDialogBuilder<void>(
                                    context: context,
                                    builder: (ctx) => _ChangePinDialog(v3AuthId: authId),
                                  );
                                },
                          child: Ink(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.lock_reset_outlined,
                                    color: Colors.white.withValues(alpha: 0.9),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _trProfileDialog('promeniPin'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.95),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: Colors.white.withValues(alpha: 0.55),
                                    size: 22,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ── Actions ──
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: V3ButtonUtils.outlinedButton(
                        onPressed: _saving ? null : () => Navigator.pop(context),
                        text: _trProfileDialog('otkazi'),
                        borderColor: Colors.white54,
                        foregroundColor: Colors.white70,
                        fontSize: 14,
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: V3ButtonUtils.primaryButton(
                        onPressed: _saving ? null : _sacuvaj,
                        text: _trProfileDialog('sacuvaj'),
                        icon: Icons.check_rounded,
                        isLoading: _saving,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── CHANGE PIN DIALOG ──────────────────────────────────────────────────────
class _ChangePinDialog extends StatefulWidget {
  final String v3AuthId;

  const _ChangePinDialog({required this.v3AuthId});

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _oldPinController = TextEditingController();
  final _newPinController = TextEditingController();
  final _newPinConfirmController = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _oldPinController.dispose();
    _newPinController.dispose();
    _newPinConfirmController.dispose();
    super.dispose();
  }

  Future<void> _sacuvaj() async {
    final oldPin = _oldPinController.text.trim();
    final newPin = _newPinController.text.trim();
    final newPinConfirm = _newPinConfirmController.text.trim();

    if (!V3ClosedAuthService.isValidPin(oldPin)) {
      setState(() => _error = _trProfileDialog('trenutniPinMora6Cifara'));
      return;
    }
    if (!V3ClosedAuthService.isValidPin(newPin)) {
      setState(() => _error = _trProfileDialog('noviPinMora6Cifara'));
      return;
    }
    if (newPin != newPinConfirm) {
      setState(() => _error = _trProfileDialog('noviPinoviSeNePoklapaju'));
      return;
    }
    if (newPin == oldPin) {
      setState(() => _error = _trProfileDialog('noviPinMoraBitiRazlicit'));
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final result = await V3ClosedAuthService.changePin(
      v3AuthId: widget.v3AuthId,
      oldPin: oldPin,
      newPin: newPin,
    ).timeout(
      const Duration(seconds: 15),
      onTimeout: () => (ok: false, reason: 'timeout'),
    );

    if (!mounted) return;

    if (!result.ok) {
      final message = switch (result.reason) {
        'old_pin_mismatch' => _trProfileDialog('trenutniPinNijeIspravan'),
        'pin_not_set' => _trProfileDialog('nalogNemaPin'),
        _ => _trProfileDialog('greskaPromenaPin'),
      };
      setState(() {
        _saving = false;
        _error = message;
      });
      return;
    }

    V3AppSnackBar.success(context, _trProfileDialog('pinPromenjen'));
    // Samo jedan pop — ranija dva su zatvarala i edit-profil dijalog ispod,
    // čime su se nesačuvane izmene (ime/telefon/adrese) tiho gubile.
    Navigator.of(context, rootNavigator: true).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gradient = theme.backgroundGradient;

    return Dialog(
      backgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(gradient: gradient),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock_reset_outlined, color: Colors.white, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _trProfileDialog('promeniPinTitle'),
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                          Text(
                            _trProfileDialog('unesiPinSubtitle'),
                            style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      V3InputUtils.textField(
                        controller: _oldPinController,
                        label: _trProfileDialog('trenutniPin'),
                        icon: Icons.lock_outline,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        showPaste: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                      ),
                      const SizedBox(height: 12),
                      V3InputUtils.textField(
                        controller: _newPinController,
                        label: _trProfileDialog('noviPin'),
                        icon: Icons.lock_open_outlined,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        showPaste: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                      ),
                      const SizedBox(height: 12),
                      V3InputUtils.textField(
                        controller: _newPinConfirmController,
                        label: _trProfileDialog('ponoviNoviPin'),
                        icon: Icons.lock_open_outlined,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        showPaste: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.12))),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: V3ButtonUtils.outlinedButton(
                        onPressed: _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                        text: _trProfileDialog('otkazi'),
                        borderColor: Colors.white54,
                        foregroundColor: Colors.white70,
                        fontSize: 14,
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: V3ButtonUtils.primaryButton(
                        onPressed: _saving ? null : _sacuvaj,
                        text: _trProfileDialog('sacuvaj'),
                        icon: Icons.check_rounded,
                        isLoading: _saving,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
