import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../globals.dart';
import '../repositories/v3_realtime_bootstrap_repository.dart';
import 'v3_table_registry.dart';

class V3BootstrapLoader {
  V3BootstrapLoader({
    required V3RealtimeBootstrapRepository repository,
    SupabaseClient? client,
  })  : _repository = repository,
        _client = client ?? supabase;

  final V3RealtimeBootstrapRepository _repository;
  final SupabaseClient _client;

  /// Vraca {table_name: rows} samo za tabele prisutne u odgovoru
  /// (parcijalni rezultat NE sme da brise kesove ostalih tabela).
  Future<Map<String, List<dynamic>>> loadCritical() =>
      _repository.fetchPhase('critical');

  Future<Map<String, List<dynamic>>> loadSecondary() =>
      _repository.fetchPhase('secondary');

  Future<Map<String, List<dynamic>>> loadFull() =>
      _repository.fetchPhase('all');

  Future<List<Map<String, dynamic>>> loadDelta({
    required String table,
    required DateTime since,
  }) async {
    dynamic response;
    final iso = since.toUtc().toIso8601String();

    switch (table) {
      case 'v3_adrese':
      case 'v3_vozila':
      case 'v3_kapacitet_slots':
      case 'v3_uplata_pazara':
        response = await _client.from(table).select().gte('updated_at', iso);
        break;
      case 'v3_finansije':
        response = await _client
            .from(table)
            .select(V3RealtimeBootstrapRepository.finansijeSelectColumns)
            .gte('updated_at', iso);
        break;
      case 'v3_krediti':
        response = await _client.from(table).select().gte('updated_at', iso);
        break;
      case 'v3_racuni':
      case 'v3_gorivo':
      case 'v3_app_settings':
      case 'v3_trenutna_dodela':
      case 'v3_trenutna_dodela_slot':
      case 'v3_vozac_location':
        response = await _client.from(table).select().gte('updated_at', iso);
        break;
      case 'v3_auth':
        response = await _client.from('v3_auth').select().gte('updated_at', iso);
        break;
      case 'v3_zahtevi':
        response = await _client
            .from('v3_zahtevi')
            .select(V3RealtimeBootstrapRepository.zahteviSelectColumns)
            .gte('updated_at', iso);
        break;
      case 'v3_operativna_nedelja':
        response = await _client.from(table).select().gte('updated_at', iso);
        break;
      case 'v3_eta_results':
        response = await _client.from(table).select().gte('computed_at', iso);
        break;
      default:
        return <Map<String, dynamic>>[];
    }

    if (response is! List) return <Map<String, dynamic>>[];

    return response.whereType<Map<String, dynamic>>().map(Map<String, dynamic>.from).toList(growable: false);
  }

  Future<Map<String, List<Map<String, dynamic>>>> loadDeltaAll(Map<String, DateTime?> watermarks) async {
    // Jedan RPC za sve tabele — preko Funnel-a je per-request latencija
    // ~150-700ms, pa je ovo najjeftinija delta putanja.
    try {
      final viaRpc = await _repository.fetchDelta(watermarks);
      return viaRpc;
    } catch (e) {
      debugPrint('[bootstrap] fn_v3_bootstrap_delta failed, REST fallback: $e');
    }

    final tables = V3RealtimeTableRegistry.defaults.toList(growable: false);

    if (tables.isEmpty) return {};

    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final results = await Future.wait(
      tables.map((t) => loadDelta(table: t.name, since: watermarks[t.name] ?? epoch)),
    );

    final out = <String, List<Map<String, dynamic>>>{};
    for (var i = 0; i < tables.length; i++) {
      if (results[i].isNotEmpty) {
        out[tables[i].name] = results[i];
      }
    }
    return out;
  }
}
