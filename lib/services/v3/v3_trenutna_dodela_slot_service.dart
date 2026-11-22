import '../../globals.dart';
import '../../utils/v3_belgrade_time.dart';

class V3TrenutnaDodelaSlotService {
  V3TrenutnaDodelaSlotService._();

  static const String tableName = 'v3_trenutna_dodela_slot';
  static const String colDatum = 'datum';
  static const String colGrad = 'grad';
  static const String colVreme = 'vreme';
  static const String colVozacId = 'vozac_v3_auth_id';
  static const String colVoziloId = 'vozilo_id';
  static const String colUpdatedBy = 'updated_by';

  /// Delegira na deljeni `V3BelgradeTime.parseIsoDatePart` (JEDAN IZVOR ISTINE za
  /// normalizaciju ISO datuma na `yyyy-MM-dd`, ranije duplirano ovde kao manje
  /// robustna kopija bez podrške za timezone offset).
  static String _normalizeDatumIso(String? raw) => V3BelgradeTime.parseIsoDatePart(raw);

  static String _normalizeGrad(String? raw) => (raw ?? '').trim().toUpperCase();

  static String _normalizeVreme(String? raw) => V3BelgradeTime.normalizeToHHmm(raw);

  static String slotKey({
    required String datumIso,
    required String grad,
    required String vreme,
  }) {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    return '$datum|$gradNorm|$vremeNorm';
  }

  /// 'datum|GRAD|HH:mm' -> vrednost [valueColumn] iz realtime keša (bez
  /// mrežnog poziva). Keš je isti izvor koji realtime drži svežim — ekrani
  /// ga čitaju na svaki render/revision tick, pa REST read nije potreban.
  /// Kod duplih slot ključeva pobeđuje red sa najnovijim updated_at
  /// (bivši REST read je order-ovao desc pa uzimao prvi pogodak).
  static Map<String, String> _assignmentBySlotKeyFromCache(
    Map<String, Map<String, dynamic>> cache, {
    required String valueColumn,
    String? datumIso,
    String? vozacId,
  }) {
    final trimmedDatum = _normalizeDatumIso(datumIso);
    final trimmedVozacId = (vozacId ?? '').trim();

    final result = <String, String>{};
    final bestUpdatedAt = <String, DateTime>{};
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    for (final mapped in cache.values) {
      final datum = _normalizeDatumIso(mapped[colDatum]?.toString());
      final grad = _normalizeGrad(mapped[colGrad]?.toString());
      final vreme = _normalizeVreme(mapped[colVreme]?.toString());
      final value = (mapped[valueColumn]?.toString() ?? '').trim();
      if (datum.isEmpty || grad.isEmpty || vreme.isEmpty || value.isEmpty) {
        continue;
      }
      if (trimmedDatum.isNotEmpty && datum != trimmedDatum) continue;
      if (trimmedVozacId.isNotEmpty &&
          (mapped[colVozacId]?.toString().trim() ?? '') != trimmedVozacId) {
        continue;
      }

      final key = '$datum|$grad|$vreme';
      final updatedAt = DateTime.tryParse(
              mapped['updated_at']?.toString() ?? '') ??
          epoch;
      final best = bestUpdatedAt[key];
      if (best != null && !updatedAt.isAfter(best)) continue;
      bestUpdatedAt[key] = updatedAt;
      result[key] = value;
    }

    return result;
  }

  static Map<String, String> vozacBySlotKeyFromCache(
    Map<String, Map<String, dynamic>> cache, {
    String? datumIso,
    String? vozacId,
  }) =>
      _assignmentBySlotKeyFromCache(
        cache,
        valueColumn: colVozacId,
        datumIso: datumIso,
        vozacId: vozacId,
      );

  static Map<String, String> voziloBySlotKeyFromCache(
    Map<String, Map<String, dynamic>> cache, {
    String? datumIso,
  }) =>
      _assignmentBySlotKeyFromCache(
        cache,
        valueColumn: colVoziloId,
        datumIso: datumIso,
      );

  static Future<String?> upsertActiveSlotDodela({
    required String datumIso,
    required String grad,
    required String vreme,
    required String vozacId,
    String? voziloId,
    String? updatedBy,
  }) async {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    final vozac = vozacId.trim();
    final vozilo = (voziloId ?? '').trim();

    if (datum.isEmpty || gradNorm.isEmpty || vremeNorm.isEmpty || vozac.isEmpty) return null;

    final payload = <String, dynamic>{
      colDatum: datum,
      colGrad: gradNorm,
      colVreme: vremeNorm,
      colVozacId: vozac,
      colVoziloId: vozilo.isEmpty ? null : vozilo,
      if ((updatedBy ?? '').trim().isNotEmpty) colUpdatedBy: updatedBy!.trim(),
    };

    final result = await supabase
        .from(tableName)
        .upsert(payload, onConflict: '$colDatum,$colGrad,$colVreme')
        .select('id')
        .single();
    return result['id']?.toString();
  }

  static Future<void> syncPassengerCoordinates(
    List<Map<String, dynamic>> passengers,
  ) async {
    if (passengers.isEmpty) return;

    for (final p in passengers) {
      final terminId = (p['termin_id'] ?? '').toString().trim();
      final lat = p['lat'];
      final lng = p['lng'];
      if (terminId.isEmpty || lat == null || lng == null) continue;

      final latNum = double.tryParse(lat.toString());
      final lngNum = double.tryParse(lng.toString());
      if (latNum == null || lngNum == null) continue;

      await supabase.from('v3_trenutna_dodela').update({
        'adresa_gps_lat': latNum,
        'adresa_gps_lng': lngNum,
      }).eq('termin_id', terminId);
    }
  }

  static Future<void> deleteBySlot({
    required String datumIso,
    required String grad,
    required String vreme,
  }) async {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    if (datum.isEmpty || gradNorm.isEmpty || vremeNorm.isEmpty) return;

    await supabase.from(tableName).delete().eq(colDatum, datum).eq(colGrad, gradNorm).eq(colVreme, vremeNorm);
  }

  static Future<void> deleteSlot({
    required String datumIso,
    required String grad,
    required String vreme,
    String? vozacId,
  }) async {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    if (datum.isEmpty || gradNorm.isEmpty || vremeNorm.isEmpty) return;

    dynamic query = supabase.from(tableName).delete().eq(colDatum, datum).eq(colGrad, gradNorm).eq(colVreme, vremeNorm);
    final vozacNorm = (vozacId ?? '').trim();
    if (vozacNorm.isNotEmpty) {
      query = query.eq(colVozacId, vozacNorm);
    }
    await query;
  }

  static Future<String?> activateSlot({
    required String datumIso,
    required String grad,
    required String vreme,
    required String vozacId,
    String? voziloId,
    String? updatedBy,
  }) async {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    final vozac = vozacId.trim();
    final vozilo = (voziloId ?? '').trim();
    if (datum.isEmpty || gradNorm.isEmpty || vremeNorm.isEmpty || vozac.isEmpty) return null;

    final existing = await supabase
        .from(tableName)
        .select('id')
        .eq(colDatum, datum)
        .eq(colGrad, gradNorm)
        .eq(colVreme, vremeNorm)
        .maybeSingle();

    if (existing != null) {
      final id = existing['id']?.toString();
      // Multi-driver: ne prepisuj vozac_v3_auth_id na deljenom slotu.
      if ((updatedBy ?? '').trim().isNotEmpty && id != null && id.isNotEmpty) {
        await supabase.from(tableName).update({colUpdatedBy: updatedBy!.trim()}).eq('id', id);
      }
      return id;
    }

    final result = await supabase
        .from(tableName)
        .insert(<String, dynamic>{
          colDatum: datum,
          colGrad: gradNorm,
          colVreme: vremeNorm,
          colVozacId: vozac,
          colVoziloId: vozilo.isEmpty ? null : vozilo,
          if ((updatedBy ?? '').trim().isNotEmpty) colUpdatedBy: updatedBy!.trim(),
        })
        .select('id')
        .single();
    return result['id']?.toString();
  }

  static Future<String?> fetchSlotId({
    required String datumIso,
    required String grad,
    required String vreme,
    required String vozacId,
  }) async {
    final datum = _normalizeDatumIso(datumIso);
    final gradNorm = _normalizeGrad(grad);
    final vremeNorm = _normalizeVreme(vreme);
    if (datum.isEmpty || gradNorm.isEmpty || vremeNorm.isEmpty) return null;

    // Slot je po (datum,grad,vreme) — vozacId se ne koristi (multi-driver shared).
    final rows = await supabase
        .from(tableName)
        .select('id')
        .eq(colDatum, datum)
        .eq(colGrad, gradNorm)
        .eq(colVreme, vremeNorm)
        .limit(1);
    if (rows.isEmpty) return null;
    return rows.first['id']?.toString();
  }

  static Future<void> deleteAllSlotsForVozac({
    required String vozacId,
  }) async {
    final vozac = vozacId.trim();
    if (vozac.isEmpty) return;

    await supabase.from(tableName).delete().eq(colVozacId, vozac);
  }

  /// Slot redovi dodeljeni vozaču iz realtime keša — isti shape kao bivši
  /// REST read ({datum, grad, vreme, vozilo_id?}).
  static List<Map<String, String>> slotRowsForVozacFromCache(
    Map<String, Map<String, dynamic>> cache, {
    required String vozacId,
  }) {
    final vozac = vozacId.trim();
    if (vozac.isEmpty) return <Map<String, String>>[];

    final result = <Map<String, String>>[];
    for (final mapped in cache.values) {
      if ((mapped[colVozacId]?.toString() ?? '').trim() != vozac) continue;
      final datum = _normalizeDatumIso(mapped[colDatum]?.toString());
      final grad = _normalizeGrad(mapped[colGrad]?.toString());
      final vreme = _normalizeVreme(mapped[colVreme]?.toString());
      if (datum.isEmpty || grad.isEmpty || vreme.isEmpty) continue;

      final voziloId = (mapped[colVoziloId]?.toString() ?? '').trim();
      result.add(<String, String>{
        colDatum: datum,
        colGrad: grad,
        colVreme: vreme,
        if (voziloId.isNotEmpty) colVoziloId: voziloId,
      });
    }

    return result;
  }
}
