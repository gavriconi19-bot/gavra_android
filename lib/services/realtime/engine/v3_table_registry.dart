enum V3RealtimeHook {
  rebuildAssignedCache,
  applyGlobalAppSettings,
}

class V3RealtimeTableConfig {
  const V3RealtimeTableConfig({
    required this.name,
    this.dependsOn = const <String>[],
    this.hooks = const <V3RealtimeHook>[],
  });

  final String name;
  final List<String> dependsOn;
  final List<V3RealtimeHook> hooks;
}

class V3RealtimeTableRegistry {
  /// Kritične tabele — potrebne ekranima pri prvom renderu.
  /// Cold start bootstrap (fn_v3_bootstrap 'critical') ceka samo ove;
  /// initV3() se zavrsava kad su one + realtime subscribe gotovi.
  static const List<V3RealtimeTableConfig> critical = <V3RealtimeTableConfig>[
    V3RealtimeTableConfig(name: 'v3_adrese'),
    V3RealtimeTableConfig(name: 'v3_auth'),
    V3RealtimeTableConfig(name: 'v3_vozila'),
    V3RealtimeTableConfig(name: 'v3_zahtevi'),
    V3RealtimeTableConfig(name: 'v3_trenutna_dodela'),
    V3RealtimeTableConfig(name: 'v3_trenutna_dodela_slot'),
    V3RealtimeTableConfig(
      name: 'v3_operativna_nedelja',
      hooks: <V3RealtimeHook>[V3RealtimeHook.rebuildAssignedCache],
    ),
    V3RealtimeTableConfig(name: 'v3_kapacitet_slots'),
    V3RealtimeTableConfig(
      name: 'v3_app_settings',
      hooks: <V3RealtimeHook>[V3RealtimeHook.applyGlobalAppSettings],
    ),
  ];

  /// Sekundarne tabele — teze i/ili nisu potrebne za prvi render.
  /// Stizu u pozadini posle kritične faze (fn_v3_bootstrap 'secondary').
  static const List<V3RealtimeTableConfig> secondary = <V3RealtimeTableConfig>[
    V3RealtimeTableConfig(name: 'v3_finansije'),
    V3RealtimeTableConfig(name: 'v3_gorivo'),
    V3RealtimeTableConfig(name: 'v3_krediti'),
    V3RealtimeTableConfig(name: 'v3_uplata_pazara'),
    V3RealtimeTableConfig(name: 'v3_eta_results'),
    V3RealtimeTableConfig(name: 'v3_vozac_location'),
  ];

  /// Sve realtime-pracene tabele (subscribe + delta resync).
  /// v3_racuni namerno izostavljena — nista ne cita racuniCache.
  static const List<V3RealtimeTableConfig> defaults = <V3RealtimeTableConfig>[
    ...critical,
    ...secondary,
  ];

  static final Map<String, V3RealtimeTableConfig> byName = <String, V3RealtimeTableConfig>{
    for (final table in defaults) table.name: table,
  };
}
