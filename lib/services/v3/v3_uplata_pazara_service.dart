import 'package:flutter/foundation.dart';

import '../../globals.dart';
import '../../models/v3_uplata_pazara.dart';
import '../../utils/v3_belgrade_time.dart';

/// Servis za rad sa mesecnom uplatom pazara (`v3_uplata_pazara`).
class V3UplataPazaraService {
  V3UplataPazaraService._();

  static final Map<String, Future<void>> _saveQueueByKey = {};
  static const double _eps = 0.009;

  /// Serijalizuje upise po kljucu (vozac+godina+mesec+dan) da se read-modify-write
  /// ciklusi na istom danu ne preklapaju.
  static Future<T> _enqueue<T>(String saveKey, Future<T> Function() task) async {
    final previous = _saveQueueByKey[saveKey] ?? Future.value();
    final completer = Future<T>.sync(() async {
      await previous;
      return task();
    });

    _saveQueueByKey[saveKey] = completer;
    try {
      return await completer;
    } finally {
      if (identical(_saveQueueByKey[saveKey], completer)) {
        _saveQueueByKey.remove(saveKey);
      }
    }
  }

  static Future<Map<String, dynamic>?> _fetchMonthRow(String vozacId, int mesec, int godina) {
    return supabase
        .from('v3_uplata_pazara')
        .select()
        .eq('vozac_id', vozacId)
        .eq('mesec', mesec)
        .eq('godina', godina)
        .maybeSingle();
  }

  /// Upisuje/ubacuje dnevnu uplatu u mesecni red i vraca azurirani zapis.
  static Future<V3UplataPazara?> _upisiDnevnuUplatu({
    required String vozacId,
    required int mesec,
    required int godina,
    required Map<String, dynamic>? existing,
    required V3DnevnaUplataPazara novaUplata,
  }) async {
    if (existing != null) {
      final uplata = V3UplataPazara.fromJson(existing);
      final updated = uplata.withUplata(novaUplata);
      await supabase.from('v3_uplata_pazara').update({
        'dnevne_uplate_json': updated.dnevneUplate.map((e) => e.toJson()).toList(),
        'updated_at': V3BelgradeTime.nowIsoUtc(),
      }).eq('id', uplata.id);
      return updated;
    }

    final res = await supabase.from('v3_uplata_pazara').insert({
      'vozac_id': vozacId,
      'mesec': mesec,
      'godina': godina,
      'dnevne_uplate_json': [novaUplata.toJson()],
    }).select().maybeSingle();
    return res != null ? V3UplataPazara.fromJson(res) : null;
  }

  /// Ucitava mesecnu evidenciju za vozaca i datum.
  static Future<V3UplataPazara?> getZaVozacaIMesec({
    required String vozacId,
    required DateTime datum,
  }) async {
    final id = vozacId.trim();
    if (id.isEmpty) return null;

    try {
      final res = await _fetchMonthRow(id, datum.month, datum.year);
      if (res == null) return null;
      return V3UplataPazara.fromJson(res);
    } catch (e) {
      debugPrint('[V3UplataPazaraService] getZaVozacaIMesec error: $e');
      return null;
    }
  }

  /// Cuva ili azurira dnevnu uplatu pazara za vozaca i datum.
  /// Vraca azurirani mesecni zapis (za osvezavanje cache-a), ili null.
  static Future<V3UplataPazara?> sacuvajDnevnuUplatu({
    required String vozacId,
    required DateTime datum,
    required double predao,
    required double ukupno,
    bool zahtevanUnos = false,
    bool saberiSaPostojecimPredao = false,
  }) {
    final id = vozacId.trim();
    if (id.isEmpty) return Future.value(null);

    final mesec = datum.month;
    final godina = datum.year;
    final dan = datum.day;
    final saveKey = '$id-$godina-$mesec-$dan';

    return _enqueue(saveKey, () async {
      debugPrint(
          '[V3UplataPazaraService] sacuvajDnevnuUplatu: vozacId=$id, dan=$dan.$mesec.$godina, predao=$predao, ukupno=$ukupno, zahtevanUnos=$zahtevanUnos, saberiSaPostojecimPredao=$saberiSaPostojecimPredao');

      // Brza putanja: fn_v3_pazar_sacuvaj radi merge dnevne stavke na
      // FOR UPDATE redu u 1 pozivu (ranije fetch + write kroz Funnel).
      try {
        final data = await supabase.rpc('fn_v3_pazar_sacuvaj', params: {
          'p_vozac_id': id,
          'p_datum': V3BelgradeTime.toIsoDate(datum),
          'p_predao': predao,
          'p_ukupno': ukupno,
          'p_zahtevan_unos': zahtevanUnos,
          'p_saberi_sa_postojecim': saberiSaPostojecimPredao,
        });
        if (data is Map && data['ok'] == true) {
          final row = data['uplata'];
          debugPrint('[V3UplataPazaraService] sacuvajDnevnuUplatu: uspešno (RPC)');
          return row is Map ? V3UplataPazara.fromJson(Map<String, dynamic>.from(row)) : null;
        }
        debugPrint('[V3UplataPazaraService] pazar_sacuvaj RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
      } catch (e) {
        debugPrint('[V3UplataPazaraService] pazar_sacuvaj RPC fallback: $e');
      }

      try {
        final existing = await _fetchMonthRow(id, mesec, godina);
        final uplata = existing != null ? V3UplataPazara.fromJson(existing) : null;
        final prethodnaZaDan = uplata?.uplataZaDan(dan);
        final efektivniPredao = saberiSaPostojecimPredao ? (prethodnaZaDan?.predao ?? 0) + predao : predao;
        final novaUplata = V3DnevnaUplataPazara(
          dan: dan,
          predao: efektivniPredao,
          ukupno: ukupno,
          razlika: efektivniPredao - ukupno,
          zahtevanUnos: zahtevanUnos,
        );

        debugPrint('[V3UplataPazaraService] ${existing != null ? 'ažuriram' : 'kreiram'} zapis');
        final updated = await _upisiDnevnuUplatu(
          vozacId: id,
          mesec: mesec,
          godina: godina,
          existing: existing,
          novaUplata: novaUplata,
        );
        debugPrint('[V3UplataPazaraService] sacuvajDnevnuUplatu: uspešno');
        return updated;
      } catch (e) {
        debugPrint('[V3UplataPazaraService] sacuvajDnevnuUplatu error: $e');
        rethrow;
      }
    });
  }

  /// Sinhronizuje zahtev za unos pazara za jedan dan. Za razliku od
  /// [sacuvajDnevnuUplatu] ne upisuje predaju vec samo odrzava `ukupno` i
  /// `zahtevan_unos` zastavu — i to na SVEZEM stanju iz baze (unutar reda), pa
  /// ne moze pregaziti upravo sacuvanu predaju vozaca.
  ///
  /// Pravila merge-a:
  ///  - `predao` se uvek zadrzava iz baze
  ///  - `zahtevanUnos` se postavlja samo ako nema zapisa ili je `ukupno`
  ///    porastao u odnosu na sveze stanje (reblokada nakon naknadne naplate);
  ///    nikad se ne vraca na `true` nad zavrsenim unosom bez rasta iznosa
  ///  - `ukupno` se azurira u oba smera (ispravke/storna)
  ///
  /// Vraca svezi mesecni zapis i da li je doslo do reblokade zavrsenog unosa
  /// (`bilaPredaja` — za "naknadna naplata" indikator u popupu).
  static Future<({V3UplataPazara? uplata, bool bilaPredaja})> syncZahtevanUnos({
    required String vozacId,
    required DateTime datum,
    required double ukupno,
  }) {
    final id = vozacId.trim();
    if (id.isEmpty) return Future.value((uplata: null, bilaPredaja: false));

    final mesec = datum.month;
    final godina = datum.year;
    final dan = datum.day;
    final saveKey = '$id-$godina-$mesec-$dan';

    return _enqueue(saveKey, () async {
      // Brza putanja: fn_v3_pazar_sync_zahtev radi merge na FOR UPDATE
      // redu u 1 pozivu; bila_predaja dolazi iz baze.
      try {
        final data = await supabase.rpc('fn_v3_pazar_sync_zahtev', params: {
          'p_vozac_id': id,
          'p_datum': V3BelgradeTime.toIsoDate(datum),
          'p_ukupno': ukupno,
        });
        if (data is Map && data['ok'] == true) {
          final row = data['uplata'];
          return (
            uplata: row is Map ? V3UplataPazara.fromJson(Map<String, dynamic>.from(row)) : null,
            bilaPredaja: data['bila_predaja'] == true,
          );
        }
        debugPrint('[V3UplataPazaraService] pazar_sync_zahtev RPC razlog: ${data is Map ? data['reason'] : data} — REST fallback');
      } catch (e) {
        debugPrint('[V3UplataPazaraService] pazar_sync_zahtev RPC fallback: $e');
      }

      try {
        final existing = await _fetchMonthRow(id, mesec, godina);
        final uplataPostojeca = existing != null ? V3UplataPazara.fromJson(existing) : null;
        final prethodna = uplataPostojeca?.uplataZaDan(dan);

        // Nema zapisa i nema pazara — nema sta da se zahteva.
        if (prethodna == null && ukupno <= 0) {
          return (uplata: uplataPostojeca, bilaPredaja: false);
        }

        final efektivniPredao = prethodna?.predao ?? 0.0;
        final porastao = prethodna == null || (ukupno - prethodna.ukupno) > _eps;
        final noviZahtevanUnos = (prethodna?.zahtevanUnos ?? false) || porastao;
        final bilaPredaja = prethodna != null && prethodna.zahtevanUnos == false && noviZahtevanUnos;

        // Nista se nije promenilo — bez suvisnog upisa.
        if (prethodna != null &&
            prethodna.zahtevanUnos == noviZahtevanUnos &&
            (ukupno - prethodna.ukupno).abs() <= _eps) {
          return (uplata: uplataPostojeca, bilaPredaja: false);
        }

        final novaUplata = V3DnevnaUplataPazara(
          dan: dan,
          predao: efektivniPredao,
          ukupno: ukupno,
          razlika: efektivniPredao - ukupno,
          zahtevanUnos: noviZahtevanUnos,
        );

        debugPrint(
            '[V3UplataPazaraService] syncZahtevanUnos: vozacId=$id, dan=$dan.$mesec.$godina, ukupno=$ukupno, predao=$efektivniPredao, zahtevanUnos=$noviZahtevanUnos, bilaPredaja=$bilaPredaja');
        final updated = await _upisiDnevnuUplatu(
          vozacId: id,
          mesec: mesec,
          godina: godina,
          existing: existing,
          novaUplata: novaUplata,
        );
        return (uplata: updated ?? uplataPostojeca, bilaPredaja: bilaPredaja);
      } catch (e) {
        debugPrint('[V3UplataPazaraService] syncZahtevanUnos error: $e');
        rethrow;
      }
    });
  }

  /// Vraca iznos predaje za konkretan dan.
  static Future<double?> getPredaoZaDan({
    required String vozacId,
    required DateTime datum,
  }) async {
    final uplata = await getZaVozacaIMesec(vozacId: vozacId, datum: datum);
    final dnevna = uplata?.uplataZaDan(datum.day);
    if (dnevna == null) return null;
    return dnevna.predao;
  }
}
