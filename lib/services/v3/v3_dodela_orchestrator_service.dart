import 'package:flutter/foundation.dart';

import '../../globals.dart';
import '../../utils/v3_belgrade_time.dart';
import '../../utils/v3_putnik_id_resolver.dart';
import 'v3_trenutna_dodela_service.dart';
import 'v3_trenutna_dodela_slot_service.dart';

class V3DodelaOrchestratorService {
  V3DodelaOrchestratorService._();

  static Future<int> assignTerminDefault({
    required Iterable<Map<String, dynamic>> operativnaRows,
    required String datumIso,
    required String grad,
    required String vreme,
    required String vozacId,
    String? voziloId,
    String? updatedBy,
    required bool Function(Map<String, dynamic> row) includeRow,
  }) async {
    final normVreme = V3BelgradeTime.normalizeToHHmm(vreme);

    // Brza putanja: fn_v3_dodela_termina radi delete + slot upsert +
    // bulk dodelu u 1 pozivu (ranije 3 sekvencijalna REST poziva).
    try {
      final data = await supabase.rpc('fn_v3_dodela_termina', params: {
        'p_datum': datumIso,
        'p_grad': grad,
        'p_vreme': normVreme,
        'p_vozac_id': vozacId,
        'p_vozilo_id': voziloId,
        'p_actor': updatedBy,
      }).timeout(const Duration(seconds: 15));
      if (data is Map && data['ok'] == true) {
        final assigned = data['assigned'];
        return assigned is int ? assigned : (assigned as num?)?.toInt() ?? 0;
      }
      debugPrint('[V3DodelaOrchestrator] dodela_termina RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
    } catch (e) {
      debugPrint('[V3DodelaOrchestrator] dodela_termina RPC fallback: $e');
    }

    final matchedRows = _rowsForSlot(
      operativnaRows: operativnaRows,
      datumIso: datumIso,
      grad: grad,
      vreme: normVreme,
      includeRow: includeRow,
    );

    // Obrisi stare termin dodele za ovaj slot pre upisa novog vozaca
    final terminIds =
        matchedRows.map((r) => r['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList(growable: false);
    await V3TrenutnaDodelaService.deleteByTerminIds(terminIds);

    final slotId = await V3TrenutnaDodelaSlotService.upsertActiveSlotDodela(
      datumIso: datumIso,
      grad: grad,
      vreme: normVreme,
      vozacId: vozacId,
      voziloId: voziloId,
      updatedBy: updatedBy,
    );

    await V3TrenutnaDodelaService.upsertActiveTerminDodele(
      matchedRows
          .map((row) => (
                terminId: row['id']?.toString() ?? '',
                putnikId: V3PutnikIdResolver.fromRow(row),
                vozacId: vozacId,
              ))
          .toList(growable: false),
      updatedBy: updatedBy,
      slotId: slotId,
    );

    return matchedRows.length;
  }

  static Future<int> clearTerminDefault({
    required Iterable<Map<String, dynamic>> operativnaRows,
    required String datumIso,
    required String grad,
    required String vreme,
    required bool Function(Map<String, dynamic> row) includeRow,
  }) async {
    final normVreme = V3BelgradeTime.normalizeToHHmm(vreme);

    // Brza putanja: p_vozac_id NULL = uklanjanje (slot + dodele u 1 pozivu).
    try {
      final data = await supabase.rpc('fn_v3_dodela_termina', params: {
        'p_datum': datumIso,
        'p_grad': grad,
        'p_vreme': normVreme,
        'p_vozac_id': null,
        'p_vozilo_id': null,
        'p_actor': null,
      }).timeout(const Duration(seconds: 15));
      if (data is Map && data['ok'] == true) {
        final cleared = data['cleared'];
        return cleared is int ? cleared : (cleared as num?)?.toInt() ?? 0;
      }
      debugPrint('[V3DodelaOrchestrator] dodela_termina(clear) RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
    } catch (e) {
      debugPrint('[V3DodelaOrchestrator] dodela_termina(clear) RPC fallback: $e');
    }

    await V3TrenutnaDodelaSlotService.deleteBySlot(
      datumIso: datumIso,
      grad: grad,
      vreme: normVreme,
    );

    final matchedRows = _rowsForSlot(
      operativnaRows: operativnaRows,
      datumIso: datumIso,
      grad: grad,
      vreme: normVreme,
      includeRow: includeRow,
    );

    final terminIds =
        matchedRows.map((row) => row['id']?.toString() ?? '').where((id) => id.isNotEmpty).toList(growable: false);

    await V3TrenutnaDodelaService.deleteByTerminIds(terminIds);
    return terminIds.length;
  }

  static List<Map<String, dynamic>> _rowsForSlot({
    required Iterable<Map<String, dynamic>> operativnaRows,
    required String datumIso,
    required String grad,
    required String vreme,
    required bool Function(Map<String, dynamic> row) includeRow,
  }) {
    final normVreme = V3BelgradeTime.normalizeToHHmm(vreme);

    return operativnaRows.where((row) {
      final datum = V3BelgradeTime.parseIsoDatePart(row['datum']);
      final rowGrad = row['grad']?.toString() ?? '';
      final rowVreme = V3BelgradeTime.normalizeToHHmm(row['polazak_at']?.toString());
      if (datum != datumIso || rowGrad != grad || rowVreme != normVreme) return false;
      return includeRow(row);
    }).toList(growable: false);
  }
}
