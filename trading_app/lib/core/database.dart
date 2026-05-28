import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/strategy.dart';

class AppDatabase {
  static Database? _db;

  static Future<void> init() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await databaseFactory.getDatabasesPath();
    final path = join(dir, 'trading.db');
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 22,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE strategies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        type TEXT NOT NULL,
        symbol TEXT,
        market TEXT,
        capital REAL,
        active INTEGER DEFAULT 1,
        t_value REAL,
        v1_value REAL,
        cycle_no INTEGER,
        week_no INTEGER,
        cum_deposit REAL,
        created_at TEXT,
        divisions INTEGER DEFAULT 40,
        star_base INTEGER DEFAULT 20,
        star_coeff INTEGER DEFAULT 2,
        vr_mode TEXT DEFAULT NULL,
        calc_capital REAL DEFAULT NULL,
        vr_band REAL DEFAULT NULL,
        vr_deposit REAL DEFAULT NULL,
        vr_withdrawal REAL DEFAULT NULL,
        vr_pool_pct REAL DEFAULT NULL,
        vr_g INTEGER DEFAULT NULL,
        vr_qty_per_step INTEGER DEFAULT NULL,
        v1_salsa_tp_pct REAL DEFAULT NULL,
        v1_salsa_sl_pct REAL DEFAULT NULL,
        cycle_period INTEGER DEFAULT 4,
        deleted_at TEXT DEFAULT NULL,
        vr_ref_dow INTEGER DEFAULT NULL,
        end_capital REAL DEFAULT NULL,
        server_synced INTEGER DEFAULT 0,
        sort_order INTEGER DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE trade_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        date TEXT NOT NULL,
        event TEXT,
        action TEXT,
        quantity REAL,
        price REAL,
        pnl_pct REAL,
        created_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE portfolio_stocks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        ticker TEXT NOT NULL,
        name TEXT,
        weight REAL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE pending_sells (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ticker TEXT NOT NULL,
        name TEXT,
        market TEXT,
        quantity REAL DEFAULT 0,
        avg_price REAL DEFAULT 0,
        scheduled_at TEXT NOT NULL,
        status TEXT DEFAULT 'pending',
        source_strategy_id TEXT,
        created_at TEXT,
        error_msg TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE ticker_names (
        ticker TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE qt_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        session_type TEXT NOT NULL,
        total_capital REAL NOT NULL,
        market TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TEXT NOT NULL,
        stopped_at TEXT,
        pnl_pct REAL DEFAULT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE qt_order_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        strategy_id TEXT NOT NULL,
        ticker TEXT NOT NULL,
        name TEXT NOT NULL,
        weight REAL NOT NULL,
        allocation_amount REAL NOT NULL,
        planned_qty INTEGER NOT NULL,
        planned_price REAL NOT NULL,
        actual_qty INTEGER DEFAULT 0,
        actual_price REAL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'Scheduled',
        side TEXT NOT NULL DEFAULT 'BUY',
        created_at TEXT NOT NULL,
        updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE strategy_order_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_db_id INTEGER NOT NULL,
        strategy_id TEXT NOT NULL,
        date TEXT NOT NULL,
        side TEXT NOT NULL,
        day TEXT DEFAULT '',
        label TEXT DEFAULT '',
        planned_qty INTEGER DEFAULT 0,
        planned_price REAL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'Scheduled',
        created_at TEXT NOT NULL,
        UNIQUE(strategy_db_id, date, side, day, label)
      )
    ''');
    await db.execute('''
      CREATE TABLE vr_cycle_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        strategy_id TEXT NOT NULL,
        cycle_no INTEGER NOT NULL,
        recorded_at TEXT NOT NULL,
        v_value REAL NOT NULL DEFAULT 0,
        shares REAL NOT NULL DEFAULT 0,
        price_per_share REAL NOT NULL DEFAULT 0,
        pool REAL NOT NULL DEFAULT 0,
        total_invested REAL NOT NULL DEFAULT 0,
        notes TEXT
      )
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS pending_sells (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ticker TEXT NOT NULL,
          name TEXT,
          market TEXT,
          quantity REAL DEFAULT 0,
          avg_price REAL DEFAULT 0,
          scheduled_at TEXT NOT NULL,
          status TEXT DEFAULT 'pending',
          source_strategy_id TEXT,
          created_at TEXT
        )
      ''');
    }
    if (oldV < 3) {
      await db.execute('ALTER TABLE strategies ADD COLUMN divisions INTEGER DEFAULT 40');
      await db.execute('ALTER TABLE strategies ADD COLUMN star_base INTEGER DEFAULT 20');
      await db.execute('ALTER TABLE strategies ADD COLUMN star_coeff INTEGER DEFAULT 2');
    }
    if (oldV < 4) {
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_mode TEXT DEFAULT NULL');
    }
    if (oldV < 5) {
      await db.execute('ALTER TABLE strategies ADD COLUMN calc_capital REAL DEFAULT NULL');
    }
    if (oldV < 6) {
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_band REAL DEFAULT NULL');
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_deposit REAL DEFAULT NULL');
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_withdrawal REAL DEFAULT NULL');
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_pool_pct REAL DEFAULT NULL');
    }
    if (oldV < 7) {
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_g INTEGER DEFAULT NULL');
      await db.execute('ALTER TABLE strategies ADD COLUMN vr_qty_per_step INTEGER DEFAULT NULL');
    }
    if (oldV < 8) {
      await db.execute('ALTER TABLE strategies ADD COLUMN v1_salsa_tp_pct REAL DEFAULT NULL');
      await db.execute('ALTER TABLE strategies ADD COLUMN v1_salsa_sl_pct REAL DEFAULT NULL');
    }
    if (oldV < 9) {
      await db.execute('ALTER TABLE strategies ADD COLUMN cycle_period INTEGER DEFAULT 4');
    }
    if (oldV < 10) {
      await db.execute('ALTER TABLE strategies ADD COLUMN deleted_at TEXT DEFAULT NULL');
    }
    if (oldV < 11) {
      try {
        await db.execute('ALTER TABLE strategies ADD COLUMN vr_mode TEXT DEFAULT NULL');
      } catch (_) {}
    }
    if (oldV < 12) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }
    if (oldV < 13) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ticker_names (
          ticker TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          updated_at TEXT
        )
      ''');
    }
    if (oldV < 16) await _upgradeToV16(db);
    if (oldV < 17) await _upgradeToV17(db);
    if (oldV < 18) await _upgradeToV18(db);
    if (oldV < 19) {
      await db.execute(
          'ALTER TABLE strategies ADD COLUMN server_synced INTEGER DEFAULT 0');
    }
    if (oldV < 21) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS vr_cycle_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            strategy_id TEXT NOT NULL,
            cycle_no INTEGER NOT NULL,
            recorded_at TEXT NOT NULL,
            v_value REAL NOT NULL DEFAULT 0,
            shares REAL NOT NULL DEFAULT 0,
            price_per_share REAL NOT NULL DEFAULT 0,
            pool REAL NOT NULL DEFAULT 0,
            total_invested REAL NOT NULL DEFAULT 0,
            notes TEXT
          )
        ''');
      } catch (_) {}
    }
    if (oldV < 20) {
      try {
        await db.execute('ALTER TABLE pending_sells ADD COLUMN error_msg TEXT');
      } catch (_) {}
    }
    if (oldV < 22) {
      try {
        await db.execute('ALTER TABLE strategies ADD COLUMN sort_order INTEGER DEFAULT 0');
      } catch (_) {}
    }
    if (oldV < 14) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS qt_sessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          strategy_id TEXT NOT NULL,
          session_type TEXT NOT NULL,
          total_capital REAL NOT NULL,
          market TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'active',
          created_at TEXT NOT NULL,
          stopped_at TEXT,
          pnl_pct REAL DEFAULT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS qt_order_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          strategy_id TEXT NOT NULL,
          ticker TEXT NOT NULL,
          name TEXT NOT NULL,
          weight REAL NOT NULL,
          allocation_amount REAL NOT NULL,
          planned_qty INTEGER NOT NULL,
          planned_price REAL NOT NULL,
          actual_qty INTEGER DEFAULT 0,
          actual_price REAL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'Scheduled',
          side TEXT NOT NULL DEFAULT 'BUY',
          created_at TEXT NOT NULL,
          updated_at TEXT
        )
      ''');
    }
  }

  // ── 전략 CRUD ──────────────────────────────────────────────
  static Future<List<Strategy>> getStrategies() async {
    final d = await db;
    final rows = await d.query('strategies',
        where: 'deleted_at IS NULL',
        orderBy: 'sort_order ASC, created_at DESC');
    return rows.map(Strategy.fromMap).toList();
  }

  /// 전략 순서 일괄 저장 — orderedIds 순서대로 sort_order 0,1,2,...
  static Future<void> updateStrategySortOrders(List<String> orderedIds) async {
    final d = await db;
    await d.transaction((txn) async {
      for (int i = 0; i < orderedIds.length; i++) {
        await txn.update(
          'strategies',
          {'sort_order': i},
          where: 'strategy_id = ?',
          whereArgs: [orderedIds[i]],
        );
      }
    });
  }

  static Future<List<Strategy>> getDeletedStrategies() async {
    final d = await db;
    final rows = await d.query('strategies',
        where: 'deleted_at IS NOT NULL', orderBy: 'deleted_at DESC');
    return rows.map(Strategy.fromMap).toList();
  }

  static Future<int> insertStrategy(Strategy s) async {
    final d = await db;
    return d.insert('strategies', s.toMap());
  }

  static Future<void> updateStrategy(Strategy s) async {
    final d = await db;
    await d.update('strategies', s.toMap(), where: 'id = ?', whereArgs: [s.id]);
  }

  static Future<void> softDeleteStrategy(int id,
      {double? endCapital, String? strategyId}) async {
    final d = await db;
    final data = <String, dynamic>{
      'deleted_at': DateTime.now().toIso8601String(),
    };
    if (endCapital != null) data['end_capital'] = endCapital;
    await d.update('strategies', data, where: 'id = ?', whereArgs: [id]);
    // Rename logs so future strategies with the same name start clean
    if (strategyId != null) {
      final tombstone = '${strategyId}__del__$id';
      await d.execute(
          'UPDATE trade_log SET strategy_id = ? WHERE strategy_id = ?',
          [tombstone, strategyId]);
      await d.execute(
          'UPDATE qt_sessions SET strategy_id = ? WHERE strategy_id = ?',
          [tombstone, strategyId]);
      await d.execute(
          'UPDATE qt_order_items SET strategy_id = ? WHERE strategy_id = ?',
          [tombstone, strategyId]);
    }
  }

  static Future<void> deleteStrategy(int id) async {
    final d = await db;
    await d.delete('strategies', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> renameStrategy(int id, String oldId, String newId) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('strategies', {'strategy_id': newId},
          where: 'id = ?', whereArgs: [id]);
      await txn.execute(
          'UPDATE trade_log SET strategy_id = ? WHERE strategy_id = ?',
          [newId, oldId]);
      await txn.execute(
          'UPDATE portfolio_stocks SET strategy_id = ? WHERE strategy_id = ?',
          [newId, oldId]);
      await txn.execute(
          'UPDATE pending_sells SET source_strategy_id = ? WHERE source_strategy_id = ?',
          [newId, oldId]);
      await txn.execute(
          'UPDATE qt_sessions SET strategy_id = ? WHERE strategy_id = ?',
          [newId, oldId]);
      await txn.execute(
          'UPDATE qt_order_items SET strategy_id = ? WHERE strategy_id = ?',
          [newId, oldId]);
    });
  }

  static Future<void> toggleActive(Strategy s) async {
    final d = await db;
    await d.update(
      'strategies',
      {'active': s.active ? 0 : 1},
      where: 'id = ?',
      whereArgs: [s.id],
    );
  }

  static Future<void> markAllServerSynced() async {
    final d = await db;
    await d.execute(
      'UPDATE strategies SET server_synced = 1 WHERE deleted_at IS NULL AND server_synced = 0',
    );
  }

  // ── 매매일지 ───────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getTradeLog(
      String strategyId, {String? sinceDate, String? untilDate}) async {
    final d = await db;
    final wheres = ['strategy_id = ?'];
    final args = <dynamic>[strategyId];
    if (sinceDate != null) { wheres.add('date >= ?'); args.add(sinceDate); }
    if (untilDate != null) { wheres.add('date <= ?'); args.add(untilDate); }
    return d.query('trade_log',
        where: wheres.join(' AND '), whereArgs: args, orderBy: 'date DESC');
  }

  static Future<void> insertLog(Map<String, dynamic> log) async {
    final d = await db;
    await d.insert('trade_log', log);
  }

  static Future<void> deleteLog(int id) async {
    final d = await db;
    await d.delete('trade_log', where: 'id = ?', whereArgs: [id]);
  }

  // ── 포트폴리오 종목 ────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getPortfolioStocks(String strategyId) async {
    final d = await db;
    return d.query('portfolio_stocks', where: 'strategy_id = ?', whereArgs: [strategyId]);
  }

  static Future<void> savePortfolioStock(String strategyId, String ticker, String name, double weight) async {
    final d = await db;
    final existing = await d.query(
      'portfolio_stocks',
      where: 'strategy_id = ? AND ticker = ?',
      whereArgs: [strategyId, ticker],
    );
    if (existing.isEmpty) {
      await d.insert('portfolio_stocks', {
        'strategy_id': strategyId,
        'ticker': ticker,
        'name': name,
        'weight': weight,
      });
    } else {
      await d.update(
        'portfolio_stocks',
        {'weight': weight, 'name': name},
        where: 'strategy_id = ? AND ticker = ?',
        whereArgs: [strategyId, ticker],
      );
    }
  }

  static Future<void> deletePortfolioStock(String strategyId, String ticker) async {
    final d = await db;
    await d.delete(
      'portfolio_stocks',
      where: 'strategy_id = ? AND ticker = ?',
      whereArgs: [strategyId, ticker],
    );
  }

  static Future<void> clearPortfolioStocks(String strategyId) async {
    final d = await db;
    await d.delete('portfolio_stocks', where: 'strategy_id = ?', whereArgs: [strategyId]);
  }

  // ── 매도 예약 ──────────────────────────────────────────────
  static Future<List<Map<String, dynamic>>> getPendingSells() async {
    final d = await db;
    return d.query('pending_sells',
        where: "status = 'pending'", orderBy: 'scheduled_at ASC');
  }

  static Future<int> insertPendingSell(Map<String, dynamic> sell) async {
    final d = await db;
    return d.insert('pending_sells', sell);
  }

  static Future<void> updatePendingSell(int id, Map<String, dynamic> values) async {
    final d = await db;
    await d.update('pending_sells', values, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deletePendingSell(int id) async {
    final d = await db;
    await d.delete('pending_sells', where: 'id = ?', whereArgs: [id]);
  }

  // ── 앱 설정 ────────────────────────────────────────────────
  static Future<String?> getSetting(String key) async {
    final d = await db;
    final rows = await d.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isNotEmpty ? rows.first['value'] as String? : null;
  }

  static Future<void> setSetting(String key, String value) async {
    final d = await db;
    await d.execute(
      'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  static Future<Map<String, String>> getAllSettings() async {
    final d = await db;
    final rows = await d.query('settings');
    return {for (final r in rows) r['key'] as String: r['value'] as String};
  }

  // ── QT 세션 ───────────────────────────────────────────────────
  static Future<int> insertQtSession(Map<String, dynamic> s) async {
    final d = await db;
    return d.insert('qt_sessions', s);
  }

  static Future<Map<String, dynamic>?> getQtSession(int id) async {
    final d = await db;
    final rows = await d.query('qt_sessions', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;
  }

  static Future<List<Map<String, dynamic>>> getQtSessionsByStrategy(String strategyId) async {
    final d = await db;
    final rows = await d.query('qt_sessions',
        where: 'strategy_id = ?', whereArgs: [strategyId], orderBy: 'created_at DESC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<Map<String, dynamic>?> getLatestQtSession(String strategyId) async {
    final d = await db;
    final rows = await d.query('qt_sessions',
        where: 'strategy_id = ?', whereArgs: [strategyId],
        orderBy: 'created_at DESC', limit: 1);
    return rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;
  }

  static Future<void> updateQtSession(int id, Map<String, dynamic> values) async {
    final d = await db;
    await d.update('qt_sessions', values, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> stopQtSession(int id) async {
    await updateQtSession(id, {
      'status': 'stopped',
      'stopped_at': DateTime.now().toIso8601String(),
    });
  }

  // ── QT 주문 항목 ──────────────────────────────────────────────
  static Future<void> insertQtOrderItem(Map<String, dynamic> item) async {
    final d = await db;
    await d.insert('qt_order_items', item);
  }

  static Future<List<Map<String, dynamic>>> getQtOrderItems(int sessionId) async {
    final d = await db;
    final rows = await d.query('qt_order_items',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'id ASC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<List<Map<String, dynamic>>> getScheduledQtItems() async {
    final d = await db;
    final rows = await d.query('qt_order_items', where: "status = 'Scheduled'");
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<void> updateQtOrderItem(int id, Map<String, dynamic> values) async {
    final d = await db;
    await d.update('qt_order_items', values, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> _upgradeToV16(Database db) async {
    try { await db.execute('ALTER TABLE qt_sessions ADD COLUMN pnl_pct REAL DEFAULT NULL'); } catch (_) {}
  }

  static Future<void> _upgradeToV17(Database db) async {
    try { await db.execute('ALTER TABLE strategies ADD COLUMN vr_ref_dow INTEGER DEFAULT NULL'); } catch (_) {}
  }

  static Future<void> _upgradeToV18(Database db) async {
    try { await db.execute('ALTER TABLE strategies ADD COLUMN end_capital REAL DEFAULT NULL'); } catch (_) {}
    try {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS strategy_order_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          strategy_db_id INTEGER NOT NULL,
          strategy_id TEXT NOT NULL,
          date TEXT NOT NULL,
          side TEXT NOT NULL,
          day TEXT DEFAULT '',
          label TEXT DEFAULT '',
          planned_qty INTEGER DEFAULT 0,
          planned_price REAL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'Scheduled',
          created_at TEXT NOT NULL,
          UNIQUE(strategy_db_id, date, side, day, label)
        )
      ''');
    } catch (_) {}
  }

  // ── 주문 기록 로그 ──────────────────────────────────────────────
  static Future<void> upsertOrderLog(Map<String, dynamic> item) async {
    final d = await db;
    await d.execute('''
      INSERT OR REPLACE INTO strategy_order_log
        (strategy_db_id, strategy_id, date, side, day, label, planned_qty, planned_price, status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', [
      item['strategy_db_id'],
      item['strategy_id'],
      item['date'],
      item['side'],
      item['day'] ?? '',
      item['label'] ?? '',
      item['planned_qty'] ?? 0,
      item['planned_price'] ?? 0.0,
      item['status'] ?? 'Scheduled',
      item['created_at'],
    ]);
  }

  static Future<List<Map<String, dynamic>>> getOrderLogs(
      int strategyDbId, {String? date}) async {
    final d = await db;
    if (date != null) {
      final rows = await d.query('strategy_order_log',
          where: 'strategy_db_id = ? AND date = ?',
          whereArgs: [strategyDbId, date],
          orderBy: 'side ASC, id ASC');
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    final rows = await d.query('strategy_order_log',
        where: 'strategy_db_id = ?', whereArgs: [strategyDbId],
        orderBy: 'date DESC, side ASC, id ASC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<List<String>> getOrderLogDates(int strategyDbId) async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT DISTINCT date FROM strategy_order_log WHERE strategy_db_id = ? ORDER BY date ASC',
      [strategyDbId],
    );
    return rows.map((r) => r['date'] as String).toList();
  }

  static Future<List<Map<String, dynamic>>> getScheduledOrderLogs(int strategyDbId) async {
    final d = await db;
    final rows = await d.query('strategy_order_log',
        where: "strategy_db_id = ? AND status = 'Scheduled'",
        whereArgs: [strategyDbId]);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<void> updateOrderLogStatus(int id, String status) async {
    final d = await db;
    await d.update('strategy_order_log', {'status': status},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteScheduledOrderLogsForDate(
      int strategyDbId, String date) async {
    final d = await db;
    await d.delete('strategy_order_log',
        where: "strategy_db_id = ? AND date = ? AND status = 'Scheduled'",
        whereArgs: [strategyDbId, date]);
  }

  static Future<void> bulkDeleteStrategies(List<int> ids) async {
    if (ids.isEmpty) return;
    final d = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await d.delete('strategies', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  // ── 종목명 캐시 ────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> getLastTradeLogByAction(
      String strategyId, String action) async {
    final d = await db;
    final rows = await d.query(
      'trade_log',
      where: 'strategy_id = ? AND action = ?',
      whereArgs: [strategyId, action],
      orderBy: 'date DESC, id DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;
  }

  // ── VR 사이클 기록 ────────────────────────────────────────────────
  static Future<int> insertVrCycleRecord(Map<String, dynamic> rec) async {
    final d = await db;
    return d.insert('vr_cycle_records', rec);
  }

  static Future<List<Map<String, dynamic>>> getVrCycleRecords(String strategyId) async {
    final d = await db;
    final rows = await d.query('vr_cycle_records',
        where: 'strategy_id = ?', whereArgs: [strategyId],
        orderBy: 'cycle_no ASC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static Future<void> deleteVrCycleRecord(int id) async {
    final d = await db;
    await d.delete('vr_cycle_records', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> updateVrCycleRecord(int id, Map<String, dynamic> values) async {
    final d = await db;
    await d.update('vr_cycle_records', values, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> cacheTickerNames(Map<String, String> names) async {
    if (names.isEmpty) return;
    final d = await db;
    final now = DateTime.now().toIso8601String();
    await d.transaction((txn) async {
      for (final e in names.entries) {
        if (e.key.isEmpty || e.value.isEmpty) continue;
        await txn.execute(
          'INSERT OR REPLACE INTO ticker_names (ticker, name, updated_at) VALUES (?, ?, ?)',
          [e.key, e.value, now],
        );
      }
    });
  }

  static Future<Map<String, String>> getTickerNames() async {
    final d = await db;
    final rows = await d.query('ticker_names');
    return {for (final r in rows) r['ticker'] as String: r['name'] as String};
  }
}
