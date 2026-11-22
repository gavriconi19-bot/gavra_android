import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../globals.dart';
import '../engine/v3_table_registry.dart';

class V3RealtimeBootstrapRepository {
  static const Duration _requestTimeout = Duration(seconds: 45);
  static const Duration _criticalRequestTimeout = Duration(seconds: 60);

  /// Jedinstvena projekcija za v3_zahtevi (bootstrap + delta + RPC u bazi).
  /// Sadrzi mesto_ponuda* — bez njih cold-start putnik ne vidi ponudjeno mesto.
  static const String zahteviSelectColumns =
      'id, datum, grad, trazeni_polazak_at, status, polazak_at, koristi_sekundarnu, adresa_override_id, alternativa_pre_at, alternativa_posle_at, alternativa_offered_at, mesto_ponuda, mesto_ponuda_at, mesto_ponuda_odbijena, mesto_ponuda_expired_at, created_at, updated_at, created_by, updated_by, scheduled_at';

  /// Slim projekcija — bez broj_voznji/ime/naplatio_ime/poslednja_dopuna
  /// (app ih ne cita). Teske *_json kolone ostaju: cache potrosaci ih citaju.
  static const String finansijeSelectColumns =
      'id, naziv, kategorija, iznos, isplata_iz, mesec, godina, created_at, updated_at, tip, putnik_v3_auth_id, naplaceno_by, nenaplacene_voznje_json, realizovane_voznje_json, otkazane_voznje_json, uplate_json, visak_iznos, preneti_visak_ulaz, preneti_visak_izlaz';

  /// Jedan RPC poziv za celu fazu bootstrap-a ('critical' | 'secondary' | 'all').
  /// REST fallback zadrzan za slucaj da funkcija nije deploy-ovana.
  Future<Map<String, List<dynamic>>> fetchPhase(String phase) async {
    try {
      final data = await supabase
          .rpc('fn_v3_bootstrap', params: {'p_phase': phase})
          .timeout(_criticalRequestTimeout);
      return _coerceRowsMap(data);
    } catch (e) {
      debugPrint('[bootstrap] fn_v3_bootstrap($phase) failed, REST fallback: $e');
      return _fetchPhaseRest(phase);
    }
  }

  /// Delta po watermark-ima — jedan RPC za sve tabele.
  /// Baca exception — pozivalac pada na per-table REST (V3BootstrapLoader).
  Future<Map<String, List<Map<String, dynamic>>>> fetchDelta(
      Map<String, DateTime?> watermarks) async {
    final data = await supabase.rpc(
      'fn_v3_bootstrap_delta',
      params: {
        'p_watermarks': {
          for (final entry in watermarks.entries)
            if (entry.value != null)
              entry.key: entry.value!.toUtc().toIso8601String(),
        },
      },
    ).timeout(_requestTimeout);

    final out = <String, List<Map<String, dynamic>>>{};
    if (data is Map) {
      for (final entry in data.entries) {
        final rows = entry.value;
        if (rows is! List || rows.isEmpty) continue;
        out[entry.key.toString()] = rows
            .whereType<Map<String, dynamic>>()
            .map(Map<String, dynamic>.from)
            .toList(growable: false);
      }
    }
    return out;
  }

  static Map<String, List<dynamic>> _coerceRowsMap(dynamic data) {
    final out = <String, List<dynamic>>{};
    if (data is Map) {
      for (final entry in data.entries) {
        final rows = entry.value;
        out[entry.key.toString()] =
            rows is List ? rows : const <dynamic>[];
      }
    }
    return out;
  }

  /// REST fallback putanja — paralelni select-ovi po tabeli (pre-RPC ponasanje).
  Future<Map<String, List<dynamic>>> _fetchPhaseRest(String phase) async {
    final specs = <String, _TableFetchSpec>{
      'v3_adrese': _TableFetchSpec(
        query: () => supabase.from('v3_adrese').select(),
      ),
      'v3_auth': _TableFetchSpec(
        query: () => supabase.from('v3_auth').select(),
        timeout: _criticalRequestTimeout,
        retries: 3,
        requiredTable: true,
      ),
      'v3_vozila': _TableFetchSpec(
        query: () => supabase.from('v3_vozila').select(),
      ),
      'v3_zahtevi': _TableFetchSpec(
        query: () =>
            supabase.from('v3_zahtevi').select(zahteviSelectColumns),
      ),
      'v3_trenutna_dodela': _TableFetchSpec(
        query: () => supabase.from('v3_trenutna_dodela').select(),
      ),
      'v3_trenutna_dodela_slot': _TableFetchSpec(
        query: () => supabase.from('v3_trenutna_dodela_slot').select(),
      ),
      'v3_operativna_nedelja': _TableFetchSpec(
        query: () => supabase.from('v3_operativna_nedelja').select(),
      ),
      'v3_kapacitet_slots': _TableFetchSpec(
        query: () => supabase.from('v3_kapacitet_slots').select(),
      ),
      'v3_app_settings': _TableFetchSpec(
        query: () => supabase.from('v3_app_settings').select(),
        timeout: _criticalRequestTimeout,
        retries: 3,
        requiredTable: true,
      ),
      'v3_finansije': _TableFetchSpec(
        query: () =>
            supabase.from('v3_finansije').select(finansijeSelectColumns),
        timeout: _criticalRequestTimeout,
        retries: 3,
        requiredTable: true,
      ),
      'v3_gorivo': _TableFetchSpec(
        query: () => supabase.from('v3_gorivo').select(),
      ),
      'v3_krediti': _TableFetchSpec(
        query: () => supabase.from('v3_krediti').select(),
      ),
      'v3_uplata_pazara': _TableFetchSpec(
        query: () => supabase.from('v3_uplata_pazara').select(),
      ),
      'v3_eta_results': _TableFetchSpec(
        query: () => supabase.from('v3_eta_results').select(),
      ),
      'v3_vozac_location': _TableFetchSpec(
        query: () => supabase.from('v3_vozac_location').select(),
      ),
    };

    final Set<String> wanted;
    if (phase == 'all') {
      wanted = specs.keys.toSet();
    } else {
      final configs = phase == 'critical'
          ? V3RealtimeTableRegistry.critical
          : V3RealtimeTableRegistry.secondary;
      wanted = {for (final c in configs) c.name};
    }

    final entries = await Future.wait(
      specs.entries
          .where((e) => wanted.contains(e.key))
          .map((e) async => MapEntry(
                e.key,
                await _fetchTableRows(
                  table: e.key,
                  query: e.value.query,
                  timeout: e.value.timeout,
                  retries: e.value.retries,
                  requiredTable: e.value.requiredTable,
                ),
              )),
    );
    return Map<String, List<dynamic>>.fromEntries(entries);
  }

  Future<List<dynamic>> _fetchTableRows({
    required String table,
    required Future<dynamic> Function() query,
    Duration timeout = _requestTimeout,
    int retries = 1,
    bool requiredTable = false,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final response = await query().timeout(timeout);
        if (response is List) {
          return response.cast<dynamic>();
        }
        return <dynamic>[];
      } catch (e) {
        lastError = e;
      }

      if (attempt < retries) {
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }

    if (requiredTable) {
      if (lastError is TimeoutException) {
        throw TimeoutException('Timeout while loading $table', timeout);
      }
      throw StateError('Failed while loading $table: $lastError');
    }

    return <dynamic>[];
  }
}

class _TableFetchSpec {
  const _TableFetchSpec({
    required this.query,
    this.timeout = V3RealtimeBootstrapRepository._requestTimeout,
    this.retries = 1,
    this.requiredTable = false,
  });

  final Future<dynamic> Function() query;
  final Duration timeout;
  final int retries;
  final bool requiredTable;
}
