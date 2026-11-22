import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../globals.dart';
import '../../models/v3_zahtev.dart';
import '../../utils/v3_belgrade_time.dart';
import '../../utils/v3_status_policy.dart';
import '../../utils/v3_uuid_utils.dart';
import '../realtime/v3_master_realtime_manager.dart';
import 'repositories/v3_operativna_nedelja_repository.dart';
import 'v3_operativna_nedelja_service.dart';
import 'v3_vozac_service.dart';
import 'zahtevi/v3_zahtev_domain_service.dart';
import 'zahtevi/v3_zahtev_repository.dart';
import 'zahtevi/v3_zahtev_types.dart';

/// Service for V3 passenger travel requests (`v3_zahtevi`).
class V3ZahtevService {
  V3ZahtevService._();

  static final V3ZahtevRepository _repository = V3ZahtevRepository();
  static final V3OperativnaNedeljaRepository _operativnaRepository = V3OperativnaNedeljaRepository();
  static final V3ZahtevDomainService _domain = V3ZahtevDomainService(_repository);
  static final Map<String, Future<void>> _cancelQueueByKey = {};

  static Future<T> _runInCancellationQueue<T>(String key, Future<T> Function() action) async {
    final previous = _cancelQueueByKey[key];
    final future = Future<T>.sync(() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      return action();
    });

    final queuedFuture = future.then((_) {}, onError: (_) {});
    _cancelQueueByKey[key] = queuedFuture;

    try {
      return await future;
    } finally {
      if (identical(_cancelQueueByKey[key], queuedFuture)) {
        _cancelQueueByKey.remove(key);
      }
    }
  }

  static String _datumKey(DateTime datum) => V3BelgradeTime.parseIsoDatePart(datum.toIso8601String());

  static DateTime _parseTs(String? value) {
    if (value == null || value.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return V3BelgradeTime.parseTs(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  static List<Map<String, dynamic>> _vidljiviRedoviPoKontekstu({
    required String putnikId,
    required DateTime datum,
    required String grad,
  }) {
    final datumIso = _datumKey(datum);
    final targetGrad = grad.trim().toUpperCase();
    final rows = V3MasterRealtimeManager.instance.zahteviCache.values.where((row) {
      final rowDatum = V3BelgradeTime.parseIsoDatePart(row['datum'] as String? ?? '');
      final rowGrad = (row['grad']?.toString() ?? '').trim().toUpperCase();
      return (row['created_by']?.toString() ?? '') == putnikId &&
          rowDatum == datumIso &&
          rowGrad == targetGrad &&
          V3StatusPolicy.isVisibleForDisplay(
            status: row['status']?.toString(),
          );
    }).toList();

    rows.sort((a, b) {
      final bTs = _parseTs(b['updated_at']?.toString()).isAfter(_parseTs(b['created_at']?.toString()))
          ? _parseTs(b['updated_at']?.toString())
          : _parseTs(b['created_at']?.toString());
      final aTs = _parseTs(a['updated_at']?.toString()).isAfter(_parseTs(a['created_at']?.toString()))
          ? _parseTs(a['updated_at']?.toString())
          : _parseTs(a['created_at']?.toString());
      return bTs.compareTo(aTs);
    });

    return rows;
  }

  static void _assertDatumUTekucojNedelji(DateTime datum) {
    if (!V3DanHelper.isInSchedulingWorkweek(datum)) {
      throw Exception('Zakazivanje je dozvoljeno samo u tekućoj sedmici.');
    }
  }

  static V3Zahtev? getZahtevById(String id) {
    final data = V3MasterRealtimeManager.instance.zahteviCache[id];
    return data != null ? V3Zahtev.fromJson(data) : null;
  }

  static Future<V3Zahtev> createZahtev(V3Zahtev zahtev, {String? createdBy}) async {
    try {
      _assertDatumUTekucojNedelji(zahtev.datum);

      final data = zahtev.toJson();
      final createdByUuid = V3UuidUtils.normalizeUuid(createdBy);
      if (createdByUuid != null) data['created_by'] = createdByUuid;
      if (!data.containsKey('created_at')) {
        data['created_at'] = V3BelgradeTime.nowIsoUtc();
      }
      final row = await _repository.create(data);

      V3MasterRealtimeManager.instance.v3UpsertToCache('v3_zahtevi', row);
      return V3Zahtev.fromJson(row);
    } catch (e) {
      debugPrint('[V3ZahtevService] Error: $e');
      rethrow;
    }
  }

  static void _upsertRpcOperativnaRows(Map<dynamic, dynamic> data) {
    final rows = data['operativna'];
    if (rows is List) {
      for (final row in rows) {
        if (row is Map) {
          V3MasterRealtimeManager.instance.v3UpsertToCache(
            'v3_operativna_nedelja',
            Map<String, dynamic>.from(row),
          );
        }
      }
    }
    final sve = data['operativna_sve'];
    if (sve is List) {
      for (final row in sve) {
        if (row is Map) {
          V3MasterRealtimeManager.instance.v3UpsertToCache(
            'v3_operativna_nedelja',
            Map<String, dynamic>.from(row),
          );
        }
      }
    }
  }

  static Future<void> sacuvajPolazakPutnikaPoKontekstu({
    required String putnikId,
    required DateTime datum,
    required String grad,
    required String novoVreme,
    bool koristiSekundarnu = false,
    String? updatedBy,
  }) async {
    final datumIso = _datumKey(datum);
    final targetGrad = grad.trim().toUpperCase();
    final actorUuid = V3UuidUtils.normalizeUuid(updatedBy);

    // Brza putanja: fn_v3_putnik_polazak radi ceo tok u 1 pozivu (~0.3s)
    // — ranije je bilo 3-7 sekvencijalnih REST poziva (updateStatus +
    // updateTrazeniPolazakAt + sync operativne), svaki ~300-500ms kroz
    // Funnel. Legacy REST putanja ispod ostaje kao fallback.
    try {
      final data = await supabase.rpc('fn_v3_putnik_polazak', params: {
        'p_putnik_id': putnikId,
        'p_datum': datumIso,
        'p_grad': targetGrad,
        'p_vreme': novoVreme,
        'p_koristi_sekundarnu': koristiSekundarnu,
        'p_actor': actorUuid,
      });
      if (data is Map && data['ok'] == true) {
        final zahtev = data['zahtev'];
        if (zahtev is Map) {
          V3MasterRealtimeManager.instance.v3UpsertToCache(
            'v3_zahtevi',
            Map<String, dynamic>.from(zahtev),
          );
        }
        _upsertRpcOperativnaRows(data);
        return;
      }
      debugPrint('[V3ZahtevService] putnik_polazak RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
    } catch (e) {
      debugPrint('[V3ZahtevService] putnik_polazak RPC fallback: $e');
    }

    final aktivni = _vidljiviRedoviPoKontekstu(putnikId: putnikId, datum: datum, grad: grad);
    if (aktivni.isNotEmpty) {
      final row = aktivni.first;
      final rowKey = (row['id']?.toString() ?? '').trim();
      if (rowKey.isNotEmpty) {
        final status = row['status']?.toString();
        if (V3StatusPolicy.isOfferLike(status)) {
          await updateStatus(rowKey, 'obrada', updatedBy: updatedBy);
        }
        await updateTrazeniPolazakAt(
          rowKey,
          novoVreme,
          koristiSekundarnu: koristiSekundarnu,
          updatedBy: updatedBy,
        );
        return;
      }
    }

    final zahtev = V3Zahtev(
      id: const Uuid().v4(),
      putnikId: putnikId,
      datum: datum,
      grad: grad,
      trazeniPolazakAt: novoVreme,
      status: 'obrada',
      koristiSekundarnu: koristiSekundarnu,
    );
    await createZahtev(zahtev, createdBy: updatedBy);
  }

  static Future<void> otkaziPolazakPutnikaPoKontekstu({
    required String putnikId,
    required DateTime datum,
    required String grad,
    String? otkazaoPutnikId,
  }) async {
    final datumIso = _datumKey(datum);
    final targetGrad = grad.trim().toUpperCase();
    final queueKey = 'putnik_ctx|$putnikId|$datumIso|$targetGrad';

    await _runInCancellationQueue<void>(queueKey, () async {
      final updBy = V3UuidUtils.normalizeUuid(otkazaoPutnikId);

      // Brza putanja: fn_v3_putnik_otkazi radi ceo tok u 1 pozivu —
      // zahtev -> 'otkazano', trigger ponistava operativne redove i
      // dodele. Ranije: 6-9 sekvencijalnih REST poziva.
      try {
        final data = await supabase.rpc('fn_v3_putnik_otkazi', params: {
          'p_putnik_id': putnikId,
          'p_datum': datumIso,
          'p_grad': targetGrad,
          'p_actor': updBy,
        });
        if (data is Map && data['ok'] == true) {
          final zahtev = data['zahtev'];
          if (zahtev is Map) {
            V3MasterRealtimeManager.instance.v3UpsertToCache(
              'v3_zahtevi',
              Map<String, dynamic>.from(zahtev),
            );
          }
          _upsertRpcOperativnaRows(data);
          return;
        }
        if (data is Map && data['reason'] == 'nothing_to_cancel') {
          debugPrint('[V3ZahtevService] Preskačem otkazivanje — nema aktivnih redova za '
              'putnikId=$putnikId, datum=$datumIso, grad=$targetGrad.');
          return;
        }
        debugPrint('[V3ZahtevService] putnik_otkazi RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
      } catch (e) {
        debugPrint('[V3ZahtevService] putnik_otkazi RPC fallback: $e');
      }

      final aktivni = _vidljiviRedoviPoKontekstu(putnikId: putnikId, datum: datum, grad: grad);
      if (aktivni.isNotEmpty) {
        final row = aktivni.first;
        final rowKey = (row['id']?.toString() ?? '').trim();
        if (rowKey.isNotEmpty) {
          final updated = await _repository.updateRawMaybeSingle(
            rowKey,
            {
              'status': 'otkazano',
              if (updBy != null) 'updated_by': updBy,
            },
          );
          if (updated != null) {
            V3MasterRealtimeManager.instance.v3UpsertToCache('v3_zahtevi', updated);
          }
        }
      }

      // Trigger transfer_to_operativna_nedelja ponistava aktivne operativne
      // redove pri 'otkazano'; ovaj update je catch-all za redove bez
      // zahteva (legacy) ili stanje koje trigger nije pokrio.
      final updatedOperativni = await _operativnaRepository.updateByPutnikDatumGradAktivniReturningList(
        putnikId: putnikId,
        datumIso: datumIso,
        grad: targetGrad,
        payload: {
          if (otkazaoPutnikId != null) 'otkazano_by': otkazaoPutnikId,
          'otkazano_at': V3BelgradeTime.nowIsoUtc(),
          if (updBy != null) 'updated_by': updBy,
        },
      );

      for (final row in updatedOperativni) {
        if (row is Map<String, dynamic>) {
          V3MasterRealtimeManager.instance.v3UpsertToCache('v3_operativna_nedelja', row);
        }
      }
    });
  }

  static Future<void> updateStatus(String id, String newStatus, {String? updatedBy}) async {
    try {
      final updByUuid = V3UuidUtils.normalizeUuid(updatedBy, fallback: V3VozacService.currentVozac?.id);
      final status = V3ZahtevStatus.values.firstWhere(
        (value) => value.name == newStatus,
        orElse: () => V3ZahtevStatus.obrada,
      );
      final row = await _domain.setStatus(id: id, status: status, updatedBy: updByUuid);

      V3MasterRealtimeManager.instance.v3UpsertToCache('v3_zahtevi', row);
    } catch (e) {
      debugPrint('[V3ZahtevService] Status update error: $e');
      rethrow;
    }
  }

  static Future<void> otkaziZahtev(String id,
      {String? otkazaoVozacId, String? otkazaoPutnikId, String? operativnaId, String? putnikId}) async {
    try {
      final safeVozacId = (otkazaoVozacId ?? '').trim();
      final safePutnikOtkazaoId = (otkazaoPutnikId ?? '').trim();
      final hasVozacActor = safeVozacId.isNotEmpty;
      final hasPutnikActor = safePutnikOtkazaoId.isNotEmpty;

      if (hasVozacActor == hasPutnikActor) {
        throw Exception('Obavezno je navesti tačno jednog aktera otkazivanja');
      }

      final otkazanoAt = V3BelgradeTime.nowIsoUtc();
      final queueKey = hasPutnikActor
          ? 'putnik_req|${id.trim()}|${(operativnaId ?? '').trim()}'
          : 'vozac_req|${(operativnaId ?? '').trim()}';

      await _runInCancellationQueue<void>(queueKey, () async {
        if (hasVozacActor) {
          // Vozač otkazuje — piše samo u v3_operativna_nedelja (jedini izvor istine za vozača)
          final String? updBy = V3UuidUtils.normalizeUuid(safeVozacId);
          if (operativnaId == null || operativnaId.isEmpty) {
            throw Exception('operativnaId je obavezan za otkazivanje');
          }

          // Jedan poziv: filter otkazano_at IS NULL spaja "već otkazano"
          // proveru i upis — trigger fn_v3_operativna_sync_dodela brise
          // dodelu, finansije/ponude idu kroz svoje triggere.
          final row = await supabase
              .from('v3_operativna_nedelja')
              .update({
                'otkazano_by': safeVozacId,
                'otkazano_at': otkazanoAt,
                if (updBy != null) 'updated_by': updBy,
              })
              .eq('id', operativnaId)
              .isFilter('otkazano_at', null)
              .select()
              .maybeSingle();
          if (row == null) {
            debugPrint('[V3ZahtevService] Preskačem otkazivanje — operativnaId=$operativnaId je već otkazana ili ne postoji.');
            return;
          }
          V3MasterRealtimeManager.instance.v3UpsertToCache('v3_operativna_nedelja', row);
        } else {
          // Putnik otkazuje — piše u v3_zahtevi; trigger transfer_to_operativna_
          // nedelja ponistava aktivne operativne redove tog konteksta (ukljucujuci
          // prosledjeni operativnaId) i dodele.
          final safeZahtevId = id.trim();
          if (safeZahtevId.isEmpty) {
            throw Exception('id zahteva je obavezan kada putnik otkazuje');
          }

          final String? updBy = V3UuidUtils.normalizeUuid(safePutnikOtkazaoId);
          final row = await supabase
              .from('v3_zahtevi')
              .update({
                'status': 'otkazano',
                if (updBy != null) 'updated_by': updBy,
              })
              .eq('id', safeZahtevId)
              .neq('status', 'otkazano')
              .select()
              .maybeSingle();
          if (row == null) {
            debugPrint('[V3ZahtevService] Preskačem otkazivanje — zahtev id=$safeZahtevId je već otkazan ili ne postoji.');
            return;
          }
          V3MasterRealtimeManager.instance.v3UpsertToCache('v3_zahtevi', row);
        }
      });
    } catch (e) {
      debugPrint('[V3ZahtevService] Otkazi error: $e');
      rethrow;
    }
  }

  static Future<void> oznaciPokupljen({String? pokupljenBy, String? operativnaId}) async {
    try {
      final payload = {
        if (pokupljenBy != null) 'pokupljen_by': pokupljenBy,
        'pokupljen_at': V3BelgradeTime.nowIsoUtc(),
      };
      if (operativnaId != null && operativnaId.isNotEmpty) {
        final row = await _operativnaRepository.updateByIdReturningSingle(operativnaId, payload);
        V3MasterRealtimeManager.instance.v3UpsertToCache('v3_operativna_nedelja', row);
      } else {
        throw Exception('operativnaId je obavezan za pokupljanje');
      }
    } catch (e) {
      debugPrint('[V3ZahtevService] Pokupljen error: $e');
      rethrow;
    }
  }

  static Future<void> updateTrazeniPolazakAt(
    String id,
    String novoVreme, {
    bool? koristiSekundarnu,
    String? updatedBy,
  }) async {
    try {
      final nowIso = V3BelgradeTime.nowIsoUtc();
      await _domain.resetToObrada(
        id: id,
        novoVreme: novoVreme,
        koristiSekundarnu: koristiSekundarnu,
        updatedBy: V3UuidUtils.normalizeUuid(updatedBy),
        createdAtIso: nowIso,
      );
    } catch (e) {
      debugPrint('[V3ZahtevService] TrazeniPolazakAt update error: $e');
      rethrow;
    }
  }
}
