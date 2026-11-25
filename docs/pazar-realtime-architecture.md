# Pazar Realtime Arhitektura (V3)

Ovaj dokument opisuje kako je organizovan tok za obavezni unos pazara i gde su granice odgovornosti između realtime manager-a i UI sloja.

## Cilj

- Jedan centralni izvor realtime događaja.
- Poslovna logika van widget-a.
- UI sloj samo prikazuje popup kada dobije event.
- **Jedan izvor istine za trigger: 16:30 po beogradskom vremenu** (`_pazarDailyTriggerHour/_pazarDailyTriggerMinute`).

## Komponente

- `lib/services/realtime/v3_master_realtime_manager.dart`
  - Drži cache i realtime revizije tabela.
  - Pokreće i zaustavlja pazar monitoring (`startPazarMonitoring`, `stopPazarMonitoring`).
  - Izračunava da li je potreban unos pazara.
  - Emituje `V3PazarPromptEvent` preko `pazarPromptStream`.

- `lib/services/v3/v3_uplata_pazara_service.dart`
  - `sacuvajDnevnuUplatu` — upis predaje iz popupa (aditivno na sveže stanje).
  - `syncZahtevanUnos` — merge zahteva na svežem stanju iz baze; nikad ne briše
    `predao` i ne vraća `zahtevan_unos` na `true` nad završenim unosom bez
    stvarnog rasta `ukupno` iznosa.
  - Upisi su serijalizovani po danu (`_saveQueueByKey`).

- `lib/services/v3/v3_finansije_service.dart`
  - `getPazarPoVozacuPoDanima(vozacId)` — pazar po danima (jedan prolaz kroz
    finansije cache); datum naplate se računa u beogradskoj zoni (`_danNaplateIso`).

- `lib/widgets/v3_pazar_listener.dart`
  - Pretplaćuje se na `pazarPromptStream`.
  - Prikazuje `V3VozacPazarPopup`.
  - Ne sadrži poslovna pravila za proveru pazara.

## Tok događaja

1. `V3PazarListener` poziva `startPazarMonitoring()`.
2. `V3MasterRealtimeManager` sluša revizije:
   - `v3_uplata_pazara`
   - `v3_finansije`
   i periodični timer (1 min).
3. Manager skuplja kandidate za sync: **svi dani kada je vozač naplatio pazar**
   (iz finansija) + **svi dani sa postojećim uplata zapisima** — bez lookback
   ograničenja, pa backfill pokriva i dane kada aplikacija nije bila pokrenuta.
4. Za svaki dan (baza je autoritativna, memoizovano po mesecu):
   - nema zapisa + prošlo **16:30** + pazar > 0 → `syncZahtevanUnos` kreira zahtev,
   - `ukupno` se promenio u bilo kom smeru → `syncZahtevanUnos` osveži zapis;
     rast nad završenim unosom → reblokada (`zahtevan_unos` nazad na `true` i
     `naknadnaNaplataDetektovana` flag za popup).
5. Najstariji pending dan se **verifikuje svežim čitanjem iz baze** neposredno
   pre emitovanja eventa (zaštita od trke sa upravo završenim unosom).
6. UI prima event i otvara blokirajući popup.
7. Popup pri čuvanju upisuje `zahtevanUnos=false` sa
   `saberiSaPostojecimPredao=true` i osvežava `uplataPazaraCache` — dupli popup
   zbog zastarelog cache-a nije moguć.

## Važna pravila

- `V3MasterRealtimeManager` ne sme da koristi `BuildContext`, `Navigator` ili `showDialog`.
- Obavezni unos važi samo za `uloga='vozac'` — admin/dispečer se preskaču u
  `_checkPazarForCurrentDriver` (ni sync `zahtevan_unos` zapisa, ni popup).
- `V3PazarListener` ne sme da sadrži poslovnu logiku za izračun pravila.
- Za više listener-a koristi se subscriber count u manager-u da monitoring ne stane prerano.
- Upisi u `v3_uplata_pazara` idu isključivo kroz `V3UplataPazaraService` (queue + merge semantika).

## Ako se menja ponašanje

Kod budućih izmena:

- menjati pravila u manager-u,
- zadržati event kontrakt (`V3PazarPromptEvent`) stabilnim,
- UI menjati samo za prikaz i UX popup-a.
