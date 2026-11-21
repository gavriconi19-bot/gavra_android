import 'package:flutter/material.dart';

import '../globals.dart';
import '../l10n/app_translations.dart';
import '../services/realtime/v3_master_realtime_manager.dart';
import '../services/v3_locale_manager.dart';
import '../theme.dart';
import '../utils/v3_belgrade_time.dart';
import '../utils/v3_container_utils.dart';
import '../utils/v3_status_policy.dart';
import '../utils/v3_style_helper.dart';

class _StatTr {
  static final Map<String, Map<String, String>> _t = AppTranslations.ns('statistikaScreen');

  static String tr(String key) {
    final code = V3LocaleManager().currentLocale.languageCode;
    return _t[key]?[code] ?? _t[key]?['sr'] ?? key;
  }
}

enum _Grupisanje { dan, nedelja, mesec, godina }

/// Admin ekran sa statistikama. Prva metrika: broj prevezenih putnika
/// (red u v3_operativna_nedelja sa postavljenim `pokupljen_at`),
/// grupisan po danima, nedeljama, mesecima ili godinama.
/// Otkazani redovi (otkazano_at) se posebno prikazuju i ne računaju se.
class V3StatistikaScreen extends StatefulWidget {
  const V3StatistikaScreen({super.key});

  @override
  State<V3StatistikaScreen> createState() => _V3StatistikaScreenState();
}

class _DanStat {
  _DanStat({required this.datum});

  final DateTime datum;
  int prevezeni = 0;
  int otkazani = 0;
  int bc = 0;
  int vs = 0;
}

class _GroupStat {
  _GroupStat({required this.label, required this.sortKey});

  final String label;
  final DateTime sortKey;
  bool isCurrent = false;
  int prevezeni = 0;
  int otkazani = 0;
  int bc = 0;
  int vs = 0;
}

class _V3StatistikaScreenState extends State<V3StatistikaScreen> {
  static const List<int> _periodOpcije = <int>[7, 30, 90, 0]; // 0 = svi datumi

  int _periodDana = 30;
  String _grad = 'SVI';
  _Grupisanje _grupisanje = _Grupisanje.dan;

  List<_DanStat> _computeDayStats() {
    final today = V3BelgradeTime.today();
    final from = _periodDana > 0 ? today.subtract(Duration(days: _periodDana - 1)) : null;

    final poDanu = <String, _DanStat>{};
    for (final row in V3MasterRealtimeManager.instance.operativnaNedeljaCache.values) {
      final datumIso = V3BelgradeTime.parseIsoDatePart(row['datum']?.toString());
      if (datumIso.isEmpty) continue;
      final datum = V3BelgradeTime.parseDatum(datumIso);
      if (datum == null) continue;
      if (from != null && datum.isBefore(from)) continue;
      if (datum.isAfter(today)) continue; // budući termini nisu statistika

      final grad = (row['grad']?.toString() ?? '').trim().toUpperCase();
      if (_grad != 'SVI' && grad != _grad) continue;

      final stat = poDanu.putIfAbsent(datumIso, () => _DanStat(datum: datum));
      if (V3StatusPolicy.isTimestampSet(row['otkazano_at'])) {
        stat.otkazani++;
        continue;
      }
      if (V3StatusPolicy.isTimestampSet(row['pokupljen_at'])) {
        stat.prevezeni++;
        if (grad == 'BC') {
          stat.bc++;
        } else if (grad == 'VS') {
          stat.vs++;
        }
      }
    }

    return poDanu.values.toList()..sort((a, b) => b.datum.compareTo(a.datum));
  }

  static String _formatRange(DateTime start, DateTime end) {
    String f(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.';
    return '${f(start)}–${f(end)}${end.year}';
  }

  ({String key, String label, DateTime sortKey}) _groupFor(DateTime datum) {
    switch (_grupisanje) {
      case _Grupisanje.dan:
        return (
          key: V3BelgradeTime.toIsoDate(datum),
          label: '${V3DanHelper.trAbbr(V3DanHelper.fullName(datum))} ${V3BelgradeTime.formatDatumPuni(datum)}',
          sortKey: datum,
        );
      case _Grupisanje.nedelja:
        final start = datum.subtract(Duration(days: datum.weekday - DateTime.monday));
        final end = start.add(const Duration(days: DateTime.friday - DateTime.monday));
        return (
          key: V3BelgradeTime.toIsoDate(start),
          label: _formatRange(start, end),
          sortKey: start,
        );
      case _Grupisanje.mesec:
        return (
          key: '${datum.year.toString().padLeft(4, '0')}-${datum.month.toString().padLeft(2, '0')}',
          label: '${V3BelgradeTime.mesecNaziv(datum.month)} ${datum.year}',
          sortKey: DateTime(datum.year, datum.month),
        );
      case _Grupisanje.godina:
        return (
          key: '${datum.year}',
          label: '${datum.year}',
          sortKey: DateTime(datum.year),
        );
    }
  }

  bool _isCurrentGroup(DateTime datum, DateTime today) {
    switch (_grupisanje) {
      case _Grupisanje.dan:
        return datum == today;
      case _Grupisanje.nedelja:
        final start = today.subtract(Duration(days: today.weekday - DateTime.monday));
        final datumStart = datum.subtract(Duration(days: datum.weekday - DateTime.monday));
        return datumStart == start;
      case _Grupisanje.mesec:
        return datum.year == today.year && datum.month == today.month;
      case _Grupisanje.godina:
        return datum.year == today.year;
    }
  }

  List<_GroupStat> _groupStats(List<_DanStat> dani) {
    final today = V3BelgradeTime.today();
    final map = <String, _GroupStat>{};
    for (final d in dani) {
      final g = _groupFor(d.datum);
      final stat = map.putIfAbsent(g.key, () => _GroupStat(label: g.label, sortKey: g.sortKey));
      stat.prevezeni += d.prevezeni;
      stat.otkazani += d.otkazani;
      stat.bc += d.bc;
      stat.vs += d.vs;
      if (_isCurrentGroup(d.datum, today)) stat.isCurrent = true;
    }
    return map.values.toList()..sort((a, b) => b.sortKey.compareTo(a.sortKey));
  }

  String get _prosekKey => switch (_grupisanje) {
        _Grupisanje.dan => 'prosekPoDanu',
        _Grupisanje.nedelja => 'prosekPoNedelji',
        _Grupisanje.mesec => 'prosekPoMesecu',
        _Grupisanje.godina => 'prosekPoGodini',
      };

  String get _rekordKey => switch (_grupisanje) {
        _Grupisanje.dan => 'rekordDan',
        _Grupisanje.nedelja => 'rekordNedelja',
        _Grupisanje.mesec => 'rekordMesec',
        _Grupisanje.godina => 'rekordGodina',
      };

  String get _listaKey => switch (_grupisanje) {
        _Grupisanje.dan => 'prevezeniPoDanima',
        _Grupisanje.nedelja => 'prevezeniPoNedeljama',
        _Grupisanje.mesec => 'prevezeniPoMesecima',
        _Grupisanje.godina => 'prevezeniPoGodinama',
      };

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream:
          V3MasterRealtimeManager.instance.tablesRevisionStream(const <String>['v3_operativna_nedelja']),
      builder: (context, _) {
        final grupe = _groupStats(_computeDayStats());
        final ukupno = grupe.fold<int>(0, (s, g) => s + g.prevezeni);
        final prosek = grupe.isEmpty ? 0.0 : ukupno / grupe.length;
        var maxPrevezeni = 0;
        _GroupStat? rekord;
        for (final g in grupe) {
          if (g.prevezeni > maxPrevezeni) {
            maxPrevezeni = g.prevezeni;
            rekord = g;
          }
        }

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            automaticallyImplyLeading: false,
            centerTitle: true,
            title: Text(
              _StatTr.tr('naslov'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: Colors.white),
            ),
          ),
          body: V3ContainerUtils.backgroundContainer(
            gradient: Theme.of(context).backgroundGradient,
            child: SafeArea(
              child: Column(
                children: [
                  // ─── KPI kartice ───
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _KpiCard(
                          label: _StatTr.tr('ukupnoPrevezeno'),
                          value: '$ukupno',
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 8),
                        _KpiCard(
                          label: _StatTr.tr(_prosekKey),
                          value: prosek.toStringAsFixed(1),
                          color: Colors.blueAccent,
                        ),
                        const SizedBox(width: 8),
                        _KpiCard(
                          label: _StatTr.tr(_rekordKey),
                          value: '$maxPrevezeni',
                          sub: rekord?.label,
                          color: Colors.orangeAccent,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ─── Filteri: grupisanje, period, grad ───
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final g in _Grupisanje.values)
                              _FilterChip(
                                label: _StatTr.tr(g.name),
                                selected: _grupisanje == g,
                                onTap: () => setState(() => _grupisanje = g),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final d in _periodOpcije)
                              _FilterChip(
                                label: d == 0 ? _StatTr.tr('sve') : _StatTr.tr('d$d'),
                                selected: _periodDana == d,
                                onTap: () => setState(() => _periodDana = d),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _FilterChip(
                              label: _StatTr.tr('sviGradovi'),
                              selected: _grad == 'SVI',
                              onTap: () => setState(() => _grad = 'SVI'),
                            ),
                            _FilterChip(
                              label: 'BC',
                              selected: _grad == 'BC',
                              onTap: () => setState(() => _grad = 'BC'),
                            ),
                            _FilterChip(
                              label: 'VS',
                              selected: _grad == 'VS',
                              onTap: () => setState(() => _grad = 'VS'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // ─── Zaglavlje liste ───
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _StatTr.tr(_listaKey),
                            style: TextStyle(
                              color: V3StyleHelper.whiteAlpha75,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),

                  // ─── Lista grupa ───
                  Expanded(
                    child: grupe.isEmpty
                        ? Center(
                            child: Text(
                              _StatTr.tr('nemaPodataka'),
                              style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              0,
                              12,
                              12 + MediaQuery.of(context).padding.bottom,
                            ),
                            itemCount: grupe.length,
                            itemBuilder: (context, i) => _GroupRow(
                              stat: grupe[i],
                              maxPrevezeni: maxPrevezeni,
                              currentLabel: _StatTr.tr(_grupisanje == _Grupisanje.dan ? 'danas' : 'tekuce'),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    required this.color,
    this.sub,
  });

  final String label;
  final String value;
  final Color color;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: V3ContainerUtils.styledContainer(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        backgroundColor: V3StyleHelper.whiteAlpha06,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: V3StyleHelper.whiteAlpha13),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(color: V3StyleHelper.whiteAlpha65, fontSize: 11, fontWeight: FontWeight.w600),
            ),
            if (sub != null)
              Text(
                sub!,
                textAlign: TextAlign.center,
                style: TextStyle(color: V3StyleHelper.whiteAlpha5, fontSize: 10),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.blueAccent.withValues(alpha: 0.3) : V3StyleHelper.whiteAlpha06,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? Colors.blueAccent : V3StyleHelper.whiteAlpha13,
            width: selected ? 1.4 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : V3StyleHelper.whiteAlpha75,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.stat,
    required this.maxPrevezeni,
    required this.currentLabel,
  });

  final _GroupStat stat;
  final int maxPrevezeni;
  final String currentLabel;

  @override
  Widget build(BuildContext context) {
    final fraction = maxPrevezeni > 0 ? stat.prevezeni / maxPrevezeni : 0.0;

    return V3ContainerUtils.styledContainer(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      backgroundColor: V3StyleHelper.whiteAlpha06,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: V3StyleHelper.whiteAlpha13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            stat.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (stat.isCurrent) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.green.withValues(alpha: 0.6)),
                            ),
                            child: Text(
                              currentLabel,
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'BC ${stat.bc} · VS ${stat.vs} · ${_StatTr.tr('otkazanoKr')} ${stat.otkazani}',
                      style: TextStyle(color: V3StyleHelper.whiteAlpha5, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Text(
                '${stat.prevezeni}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Container(
              height: 6,
              color: Colors.white.withValues(alpha: 0.08),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.greenAccent.withValues(alpha: 0.9), Colors.tealAccent],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
