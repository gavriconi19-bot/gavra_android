import '../../globals.dart';

class V3TrenutnaDodelaService {
  V3TrenutnaDodelaService._();

  static const String tableName = 'v3_trenutna_dodela';
  static const String _colTerminId = 'termin_id';
  static const String _colPutnikId = 'putnik_v3_auth_id';
  static const String colVozacId = 'vozac_v3_auth_id';
  static const String _colUpdatedBy = 'updated_by';
  static const String colSlotId = 'slot_id';

  /// termin_id -> vozac_v3_auth_id iz realtime keša (bez mrežnog poziva).
  /// Keš je isti izvor koji realtime drži svežim — ekrani ga čitaju na
  /// svaki render/revision tick, pa REST read ovde nije potreban.
  static Map<String, String> vozacByTerminIdFromCache(
    Map<String, Map<String, dynamic>> cache, {
    String? putnikId,
    String? vozacId,
  }) {
    final trimmedPutnikId = (putnikId ?? '').trim();
    final trimmedVozacId = (vozacId ?? '').trim();

    final result = <String, String>{};
    for (final mapped in cache.values) {
      final terminId = mapped[_colTerminId]?.toString().trim() ?? '';
      final assignedVozacId = mapped[colVozacId]?.toString().trim() ?? '';
      if (terminId.isEmpty || assignedVozacId.isEmpty) continue;
      if (trimmedPutnikId.isNotEmpty &&
          (mapped[_colPutnikId]?.toString().trim() ?? '') != trimmedPutnikId) {
        continue;
      }
      if (trimmedVozacId.isNotEmpty && assignedVozacId != trimmedVozacId) {
        continue;
      }

      result[terminId] = assignedVozacId;
    }

    return result;
  }

  static Set<String> activeTerminIdsFromCache(
    Map<String, Map<String, dynamic>> cache, {
    String? putnikId,
    String? vozacId,
  }) {
    return vozacByTerminIdFromCache(
      cache,
      putnikId: putnikId,
      vozacId: vozacId,
    ).keys.toSet();
  }

  static Future<void> upsertActiveTerminDodela({
    required String terminId,
    required String putnikId,
    required String vozacId,
    String? updatedBy,
    String? slotId,
  }) async {
    final payload = <String, dynamic>{
      _colTerminId: terminId.trim(),
      _colPutnikId: putnikId.trim(),
      colVozacId: vozacId.trim(),
      if ((updatedBy ?? '').trim().isNotEmpty) _colUpdatedBy: updatedBy!.trim(),
      if ((slotId ?? '').trim().isNotEmpty) colSlotId: slotId!.trim(),
    };

    await supabase.from(tableName).upsert(payload, onConflict: _colTerminId);
  }

  static Future<void> upsertActiveTerminDodele(
    Iterable<({String terminId, String putnikId, String vozacId})> assignments, {
    String? updatedBy,
    String? slotId,
  }) async {
    final actor = (updatedBy ?? '').trim();
    final slotIdNorm = (slotId ?? '').trim();
    final payload = <Map<String, dynamic>>[];

    for (final assignment in assignments) {
      final terminId = assignment.terminId.trim();
      final putnikId = assignment.putnikId.trim();
      final vozacId = assignment.vozacId.trim();
      if (terminId.isEmpty || putnikId.isEmpty || vozacId.isEmpty) continue;

      payload.add(<String, dynamic>{
        _colTerminId: terminId,
        _colPutnikId: putnikId,
        colVozacId: vozacId,
        if (actor.isNotEmpty) _colUpdatedBy: actor,
        if (slotIdNorm.isNotEmpty) colSlotId: slotIdNorm,
      });
    }

    if (payload.isEmpty) return;
    await supabase.from(tableName).upsert(payload, onConflict: _colTerminId);
  }

  static Future<void> deleteByTerminId(String terminId) async {
    final id = terminId.trim();
    if (id.isEmpty) return;
    await supabase.from(tableName).delete().eq(_colTerminId, id);
  }

  static Future<void> deleteByTerminIds(Iterable<String> terminIds) async {
    final ids = terminIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return;
    if (ids.length == 1) {
      await deleteByTerminId(ids.first);
      return;
    }
    await supabase.from(tableName).delete().inFilter(_colTerminId, ids);
  }

  static Future<void> deleteBySlotId(String slotId) async {
    final id = slotId.trim();
    if (id.isEmpty) return;
    await supabase.from(tableName).delete().eq(colSlotId, id);
  }

  static Future<void> deleteByVozacId(String vozacId) async {
    final id = vozacId.trim();
    if (id.isEmpty) return;
    await supabase.from(tableName).delete().eq(colVozacId, id);
  }
}
