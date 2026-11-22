import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Perzistira v3 realtime keševe na disk.
///
/// Cold start onda ide: učitaj keš sa diska → render UI odmah →
/// fn_v3_bootstrap_delta po updated_at watermark-ima dovuce samo izmene.
/// Full bootstrap (3+MB) potreban je samo na prvom pokretanju ili kad je
/// keš zastareo (> _fullResyncStaleThreshold u master manageru).
class V3CachePersistence {
  V3CachePersistence._internal();
  static final V3CachePersistence instance = V3CachePersistence._internal();

  static const String _fileName = 'v3_realtime_cache.json';

  Future<File?> _cacheFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/$_fileName');
    } catch (e) {
      debugPrint('[V3CachePersistence] cache file path error: $e');
      return null;
    }
  }

  /// Učitava perzistiran keš. Vraca null kad fajla nema ili je korumpiran.
  Future<V3PersistedCache?> load() async {
    try {
      final file = await _cacheFile();
      if (file == null || !await file.exists()) return null;
      final raw = await file.readAsString();
      return await compute(_decodePersistedCache, raw);
    } catch (e) {
      debugPrint('[V3CachePersistence] load error: $e');
      return null;
    }
  }

  Future<void> save(
      Map<String, Map<String, Map<String, dynamic>>> tables) async {
    try {
      final file = await _cacheFile();
      if (file == null) return;
      final raw = await compute(_encodePersistedCache, <String, dynamic>{
        'saved_at': DateTime.now().toUtc().toIso8601String(),
        'tables': tables,
      });
      await file.writeAsString(raw, flush: true);
    } catch (e) {
      debugPrint('[V3CachePersistence] save error: $e');
    }
  }
}

class V3PersistedCache {
  final DateTime? savedAt;
  final Map<String, Map<String, Map<String, dynamic>>> tables;

  const V3PersistedCache({required this.savedAt, required this.tables});
}

V3PersistedCache? _decodePersistedCache(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return null;

  final savedAt = DateTime.tryParse(decoded['saved_at']?.toString() ?? '');
  final tables = <String, Map<String, Map<String, dynamic>>>{};

  final srcTables = decoded['tables'];
  if (srcTables is Map) {
    for (final entry in srcTables.entries) {
      final rows = entry.value;
      if (rows is! Map) continue;
      tables[entry.key.toString()] = <String, Map<String, dynamic>>{
        for (final rowEntry in rows.entries)
          if (rowEntry.value is Map)
            rowEntry.key.toString():
                Map<String, dynamic>.from(rowEntry.value as Map),
      };
    }
  }

  return V3PersistedCache(savedAt: savedAt, tables: tables);
}

String _encodePersistedCache(Map<String, dynamic> payload) =>
    jsonEncode(payload);
