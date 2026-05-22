import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ── 시장 시간 ────────────────────────────────────────────────
class MarketClock {
  static bool get isKrOpen {
    final kst = DateTime.now().toUtc().add(const Duration(hours: 9));
    if (kst.weekday >= 6) return false;
    final m = kst.hour * 60 + kst.minute;
    return m >= 540 && m < 930; // 09:00 ~ 15:30
  }

  // 미국 서머타임(EDT) 여부: 3월 둘째 일요일 ~ 11월 첫째 일요일
  static bool get _isEdt {
    final utc = DateTime.now().toUtc();
    final y = utc.year;
    int marchDay = 8;
    while (DateTime(y, 3, marchDay).weekday != DateTime.sunday) { marchDay++; }
    int novDay = 1;
    while (DateTime(y, 11, novDay).weekday != DateTime.sunday) { novDay++; }
    final dstStart = DateTime.utc(y, 3, marchDay, 7, 0); // 2:00 AM EST = 7:00 UTC
    final dstEnd   = DateTime.utc(y, 11, novDay,  6, 0); // 2:00 AM EDT = 6:00 UTC
    return utc.isAfter(dstStart) && utc.isBefore(dstEnd);
  }

  static bool get isUsOpen {
    final offset = _isEdt ? 4 : 5;
    final et = DateTime.now().toUtc().subtract(Duration(hours: offset));
    if (et.weekday >= 6) return false;
    final m = et.hour * 60 + et.minute;
    return m >= 570 && m < 960; // 09:30 ~ 16:00
  }

  static String nextKrOpen() {
    if (isKrOpen) return '장 운영중';
    final kst = DateTime.now().toUtc().add(const Duration(hours: 9));
    final todayOpen = DateTime(kst.year, kst.month, kst.day, 9, 0);
    if (kst.isBefore(todayOpen) && kst.weekday < 6) return '오늘 09:00 개장';
    for (int i = 1; i <= 7; i++) {
      final next = kst.add(Duration(days: i));
      if (next.weekday < 6) {
        return '${DateFormat('MM/dd').format(next)} 09:00 개장';
      }
    }
    return '-';
  }

  static String nextUsOpen() {
    if (isUsOpen) return '장 운영중';
    final offset = _isEdt ? 4 : 5;
    final tz = _isEdt ? 'EDT' : 'EST';
    final et = DateTime.now().toUtc().subtract(Duration(hours: offset));
    final todayOpen = DateTime(et.year, et.month, et.day, 9, 30);
    if (et.isBefore(todayOpen) && et.weekday < 6) return '오늘 09:30 개장 ($tz)';
    for (int i = 1; i <= 7; i++) {
      final next = et.add(Duration(days: i));
      if (next.weekday < 6) {
        return '${DateFormat('MM/dd').format(next)} 09:30 개장 ($tz)';
      }
    }
    return '-';
  }

  static int elapsedDays(DateTime from) =>
      DateTime.now().difference(from).inDays;

  // orderedAt(KST 문자열)이 오늘 뉴욕 날짜와 같으면 true
  // KST = UTC+9, EDT = UTC-4 (KST → NY: -13h), EST = UTC-5 (KST → NY: -14h)
  static bool isUsOrderFromToday(String orderedAtKst) {
    final orderKst = DateTime.tryParse(orderedAtKst.replaceFirst(' ', 'T'));
    if (orderKst == null) return true; // 파싱 실패 시 허용
    final utcOffset = _isEdt ? 4 : 5;
    // 서버 문자열은 KST(UTC+9) 기준, timezone 정보 없음
    // NY 변환: KST - 9h → UTC, UTC - utcOffset → NY
    final orderNy = orderKst.subtract(Duration(hours: 9 + utcOffset));
    final nyNow = DateTime.now().toUtc().subtract(Duration(hours: utcOffset));
    return orderNy.year == nyNow.year &&
           orderNy.month == nyNow.month &&
           orderNy.day == nyNow.day;
  }
}

// ── 계산 함수 ────────────────────────────────────────────────
class Calc {
  static double pnlPct(double avg, double current) {
    if (avg <= 0) return 0;
    return (current - avg) / avg * 100;
  }

  static double equalWeight(int count) =>
      count <= 0 ? 0 : 100.0 / count;

  static double targetShares(double capital, double weight, double price) {
    if (price <= 0) return 0;
    return (capital * weight / 100) / price;
  }
}

// ── 포맷 함수 ────────────────────────────────────────────────
class Fmt {
  static final _krw = NumberFormat('#,###');
  static final _date = DateFormat('yy.MM.dd');
  static final _datetime = DateFormat('yy.MM.dd HH:mm');

  static String krw(double v) => '${_krw.format(v.toInt())} 원';
  static String usd(double v) => '\$ ${v.toStringAsFixed(2)}';
  static String pct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
  static String date(DateTime dt) => _date.format(dt);
  static String datetime(DateTime dt) => _datetime.format(dt);
  static String num(double v) => _krw.format(v.toInt());
  static String shares(double v) =>
      v % 1 == 0 ? '${v.toInt()}주' : '${v.toStringAsFixed(2)}주';
}

// ── 매도 예약 일시 선택 시트 ─────────────────────────────────────
class ScheduleSheet extends StatefulWidget {
  const ScheduleSheet();
  @override
  State<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<ScheduleSheet> {
  late DateTime _scheduled;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _scheduled = DateTime(now.year, now.month, now.day + 1, 9, 0);
  }

  String get _displayStr {
    final d = _scheduled;
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFF30363D), borderRadius: BorderRadius.circular(2))),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('매도 예약 일시 설정',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ),
        const Divider(color: Color(0xFF30363D), height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Row(children: [
                const Icon(Icons.schedule, size: 16, color: Color(0xFF58A6FF)),
                const SizedBox(width: 10),
                Text(_displayStr,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: Color(0xFF58A6FF))),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 14),
                label: const Text('날짜 선택'),
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _scheduled,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    builder: (ctx, child) => Theme(data: ThemeData.dark(), child: child!),
                  );
                  if (d != null && mounted) {
                    setState(() {
                      _scheduled = DateTime(
                          d.year, d.month, d.day, _scheduled.hour, _scheduled.minute);
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8B949E),
                  side: const BorderSide(color: Color(0xFF30363D)),
                ),
              )),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                icon: const Icon(Icons.access_time, size: 14),
                label: const Text('시간 선택'),
                onPressed: () async {
                  final t = await showTimePicker(
                    context: context,
                    initialTime:
                        TimeOfDay(hour: _scheduled.hour, minute: _scheduled.minute),
                    builder: (ctx, child) => Theme(data: ThemeData.dark(), child: child!),
                  );
                  if (t != null && mounted) {
                    setState(() {
                      _scheduled = DateTime(_scheduled.year, _scheduled.month,
                          _scheduled.day, t.hour, t.minute);
                    });
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8B949E),
                  side: const BorderSide(color: Color(0xFF30363D)),
                ),
              )),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF30363D)),
                foregroundColor: const Color(0xFF8B949E),
              ),
              child: const Text('취소'),
            )),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: () => Navigator.pop(context, _scheduled),
              child: const Text('확인'),
            )),
          ]),
        ),
      ]),
    );
  }
}
