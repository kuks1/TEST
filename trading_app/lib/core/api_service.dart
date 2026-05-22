import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiService {
  static Map<String, String> get _headers => {
    'Authorization': 'Bearer ${Config.apiKey}',
    'Content-Type': 'application/json',
  };

  static Future<Map<String, dynamic>> getAccount() async {
    final res = await http
        .get(Uri.parse('${Config.baseUrl}/api/account'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception('계좌 조회 실패 (${res.statusCode})');
  }

  static Future<Map<String, dynamic>> getQuote(String ticker, String market) async {
    final uri = Uri.parse('${Config.baseUrl}/api/quote?ticker=$ticker&market=$market');
    final res = await http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception('시세 조회 실패');
  }

  static Future<Map<String, dynamic>> getOrders(
    String market, {
    String? startDate,
    String? endDate,
  }) async {
    final params = {'market': market};
    if (startDate != null) params['start_date'] = startDate;
    if (endDate != null) params['end_date'] = endDate;
    final uri = Uri.parse('${Config.baseUrl}/api/orders').replace(queryParameters: params);
    final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception('주문 조회 실패 (${res.statusCode})');
  }

  static Future<void> cancelOrder(String orderId, String market) async {
    final uri = Uri.parse('${Config.baseUrl}/api/orders/$orderId?market=$market');
    final res = await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('주문 취소 실패 (${res.statusCode})');
  }

  static Future<void> modifyOrder(String orderId, String market, double price, int quantity) async {
    final res = await http.put(
      Uri.parse('${Config.baseUrl}/api/orders/$orderId'),
      headers: _headers,
      body: json.encode({'market': market, 'price': price, 'quantity': quantity}),
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception('주문 정정 실패 (${res.statusCode})');
  }

  static Future<Map<String, dynamic>> placeOrder({
    required String market,
    required String ticker,
    required String side,
    required int quantity,
    double price = 0,
    String ordDvsn = '01',
    String exchange = 'NASD',
  }) async {
    final res = await http
        .post(
          Uri.parse('${Config.baseUrl}/api/order'),
          headers: _headers,
          body: json.encode({
            'market': market,
            'ticker': ticker,
            'side': side,
            'quantity': quantity,
            'price': price,
            'ord_dvsn': ordDvsn,
            'exchange': exchange,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 200) return json.decode(res.body);
    final err = json.decode(res.body);
    throw Exception(err['error'] ?? '주문 실패 (${res.statusCode})');
  }

  static Future<Map<String, dynamic>> rebalance(String strategyId) async {
    final res = await http
        .post(
          Uri.parse('${Config.baseUrl}/api/rebalance'),
          headers: _headers,
          body: json.encode({'strategy_id': strategyId}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 200) return json.decode(res.body);
    try {
      final err = json.decode(res.body);
      throw Exception(err['error'] ?? err['message'] ?? '실행 실패 (${res.statusCode})');
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('실행 실패 (${res.statusCode})');
    }
  }

  static Future<Map<String, dynamic>> executeStrategy(
      String strategyId, {bool dryRun = false}) async {
    final res = await http
        .post(
          Uri.parse('${Config.baseUrl}/api/execute'),
          headers: _headers,
          body: json.encode({'strategy_id': strategyId, 'dry_run': dryRun}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 200) return json.decode(res.body);
    final err = json.decode(res.body);
    throw Exception(err['error'] ?? '실행 실패 (${res.statusCode})');
  }

  static Future<Map<String, dynamic>> getStrategies() async {
    final res = await http
        .get(Uri.parse('${Config.baseUrl}/api/strategies'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception('전략 조회 실패 (${res.statusCode})');
  }

  static Future<void> syncStrategies(
      List<Map<String, dynamic>> strategies) async {
    final res = await http
        .post(
          Uri.parse('${Config.baseUrl}/api/strategies'),
          headers: _headers,
          body: json.encode({'strategies': strategies}),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('동기화 실패 (${res.statusCode})');
  }

  static Future<Map<String, dynamic>> getAccounts() async {
    final res = await http
        .get(Uri.parse('${Config.baseUrl}/api/accounts'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return json.decode(res.body);
    throw Exception('계좌 조회 실패 (${res.statusCode})');
  }

  static Future<void> updateAccounts(List<Map<String, dynamic>> accounts) async {
    final res = await http
        .put(
          Uri.parse('${Config.baseUrl}/api/accounts'),
          headers: _headers,
          body: json.encode({'accounts': accounts}),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      final err = json.decode(res.body);
      throw Exception(err['error'] ?? '계좌 업데이트 실패 (${res.statusCode})');
    }
  }

  static Future<List<dynamic>> getLogs({String? strategyId, int limit = 50}) async {
    final params = {'limit': limit.toString()};
    if (strategyId != null) params['strategy_id'] = strategyId;
    final uri = Uri.parse('${Config.baseUrl}/api/logs').replace(queryParameters: params);
    final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
    if (res.statusCode == 200) return (json.decode(res.body)['logs'] as List? ?? []);
    throw Exception('로그 조회 실패 (${res.statusCode})');
  }
}
