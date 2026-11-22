import 'package:flutter_test/flutter_test.dart';
import 'package:gavra_android/services/realtime/v3_master_realtime_manager.dart';
import 'package:gavra_android/services/v3/v3_finansije_service.dart';

Map<String, dynamic> _naplataRow({
  required String id,
  required String putnikId,
  required int godina,
  required int mesec,
  List<Map<String, dynamic>> nenaplacene = const [],
  List<Map<String, dynamic>> realizovane = const [],
  List<Map<String, dynamic>> uplate = const [],
  double visak = 0,
  double prenetiUlaz = 0,
  double prenetiIzlaz = 0,
}) {
  return <String, dynamic>{
    'id': id,
    'tip': 'prihod',
    'kategorija': 'operativna_naplata',
    'putnik_v3_auth_id': putnikId,
    'godina': godina,
    'mesec': mesec,
    'nenaplacene_voznje_json': nenaplacene,
    'realizovane_voznje_json': realizovane,
    'uplate_json': uplate,
    'visak_iznos': visak,
    'preneti_visak_ulaz': prenetiUlaz,
    'preneti_visak_izlaz': prenetiIzlaz,
    'created_at': '2026-01-01T00:00:00Z',
  };
}

Map<String, dynamic> _stavka(String opId, String datum, double cena) => <String, dynamic>{
      'operativna_id': opId,
      'datum': datum,
      'cena': cena,
    };

void main() {
  late V3MasterRealtimeManager rm;

  setUp(() {
    rm = V3MasterRealtimeManager.instance;
    rm.getCache('v3_finansije').clear();
    rm.putniciCache.clear();
    rm.authCache.clear();
    rm.vozaciCache.clear();
    rm.operativnaNedeljaCache.clear();
  });

  void seedPutnik(String id, {String tip = 'dnevni', double cena = 100}) {
    rm.putniciCache[id] = <String, dynamic>{
      'id': id,
      'ime_prezime': 'Pera Peric',
      'tip_putnika': tip,
      'cena_po_danu': tip == 'dnevni' ? 0.0 : cena,
      'cena_po_pokupljenju': tip == 'dnevni' ? cena : 0.0,
    };
  }

  group('getDugovi', () {
    test('vraca dug iz nenaplacenih stavki', () {
      seedPutnik('p1');
      rm.getCache('v3_finansije')['f1'] = _naplataRow(
        id: 'f1',
        putnikId: 'p1',
        godina: 2026,
        mesec: 11,
        nenaplacene: [
          _stavka('o1', '2026-11-03', 100),
          _stavka('o2', '2026-11-05', 150),
        ],
      );

      final dugovi = V3FinansijeService.getDugovi();

      expect(dugovi, hasLength(1));
      final dug = dugovi.single;
      expect(dug.putnikId, 'p1');
      expect(dug.imePrezime, 'Pera Peric');
      expect(dug.godina, 2026);
      expect(dug.mesec, 11);
      expect(dug.iznos, 250);
      expect(dug.brojVoznji, 2);
      expect(dug.ukupnaObaveza, 250);
    });

    test('preneti visak pokriva ceo dug -> nema duga', () {
      seedPutnik('p1');
      rm.getCache('v3_finansije')
        ..['f-oct'] = _naplataRow(
          id: 'f-oct',
          putnikId: 'p1',
          godina: 2026,
          mesec: 10,
          visak: 300,
        )
        ..['f-nov'] = _naplataRow(
          id: 'f-nov',
          putnikId: 'p1',
          godina: 2026,
          mesec: 11,
          nenaplacene: [_stavka('o1', '2026-11-03', 200)],
        );

      expect(V3FinansijeService.getDugovi(), isEmpty);
    });

    test('preneti visak delimicno pokriva dug', () {
      seedPutnik('p1');
      rm.getCache('v3_finansije')
        ..['f-oct'] = _naplataRow(
          id: 'f-oct',
          putnikId: 'p1',
          godina: 2026,
          mesec: 10,
          visak: 80,
        )
        ..['f-nov'] = _naplataRow(
          id: 'f-nov',
          putnikId: 'p1',
          godina: 2026,
          mesec: 11,
          nenaplacene: [_stavka('o1', '2026-11-03', 200)],
        );

      final dugovi = V3FinansijeService.getDugovi();

      expect(dugovi, hasLength(1));
      expect(dugovi.single.iznos, 120);
    });

    test('decembarski red dekodira ispravnu godinu i mesec', () {
      seedPutnik('p1');
      rm.getCache('v3_finansije')['f-dec'] = _naplataRow(
        id: 'f-dec',
        putnikId: 'p1',
        godina: 2025,
        mesec: 12,
        nenaplacene: [_stavka('o1', '2025-12-15', 100)],
      );

      final dugovi = V3FinansijeService.getDugovi();

      expect(dugovi, hasLength(1));
      expect(dugovi.single.godina, 2025);
      expect(dugovi.single.mesec, 12);
      expect(dugovi.single.datum, DateTime(2025, 12, 1));
    });

    test('dug ostaje i kad je putnik obrisan iz keša', () {
      rm.getCache('v3_finansije')['f1'] = _naplataRow(
        id: 'f1',
        putnikId: 'ghost',
        godina: 2026,
        mesec: 9,
        nenaplacene: [_stavka('o1', '2026-09-10', 100)],
      );

      final dugovi = V3FinansijeService.getDugovi();

      expect(dugovi, hasLength(1));
      expect(dugovi.single.putnikId, 'ghost');
      expect(dugovi.single.imePrezime, 'Nepoznato');
      expect(dugovi.single.tipPutnika, 'dnevni');
    });

    test('radnik (po-danu) broji jedinstvene dane, ne stavke', () {
      seedPutnik('p1', tip: 'radnik', cena: 300);
      rm.getCache('v3_finansije')['f1'] = _naplataRow(
        id: 'f1',
        putnikId: 'p1',
        godina: 2026,
        mesec: 11,
        nenaplacene: [
          _stavka('o1', '2026-11-03', 300),
          _stavka('o2', '2026-11-03', 300),
          _stavka('o3', '2026-11-04', 300),
        ],
      );

      final dugovi = V3FinansijeService.getDugovi();

      expect(dugovi, hasLength(1));
      expect(dugovi.single.iznos, 900);
      expect(dugovi.single.brojVoznji, 2);
      expect(dugovi.single.tipPutnika, 'radnik');
      expect(dugovi.single.cena, 300);
    });
  });
}
