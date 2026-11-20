import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../core/frame_api_client.dart';
import 'frame_stats_export_service.dart';

class FrameReadingStatsScreen extends StatefulWidget {
  const FrameReadingStatsScreen({required this.api, super.key});
  final FrameApiClient api;

  @override
  State<FrameReadingStatsScreen> createState() => _FrameReadingStatsScreenState();
}

class _FrameReadingStatsScreenState extends State<FrameReadingStatsScreen> {
  final FrameStatsExportService _exportService = FrameStatsExportService();
  static const bg = Color(0xFF12101A);
  static const panel = Color(0xFF1B1825);
  static const soft = Color(0xFF211C2B);
  static const accent = Color(0xFFC5ADFF);
  static const muted = Color(0xFFAAA2B8);
  static const line = Color(0xFF393247);
  static const goals = [10, 15, 20, 30, 45, 60, 90, 120];

  String period = 'month';
  DateTime calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  Map<String, dynamic> data = {};
  Map<String, int> days = {};
  Map<String, int> allDays = {};
  int goalMinutes = 30;
  bool loading = true;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  String keyOf(DateTime d) =>
      d.year.toString().padLeft(4, '0') + '-' +
      d.month.toString().padLeft(2, '0') + '-' +
      d.day.toString().padLeft(2, '0');

  int number(dynamic v) {
    if (v is int) return v;
    if (v is num && v.isFinite) return v.round();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  Map<String, int> dayMap(dynamic rows) {
    final result = <String, int>{};
    if (rows is List) {
      for (final row in rows.whereType<Map>()) {
        final key = row['dayKey']?.toString() ?? '';
        if (key.isNotEmpty) result[key] = number(row['seconds']);
      }
    }
    return result;
  }

  (DateTime, DateTime) range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (period) {
      case 'week':
        return (today.subtract(Duration(days: today.weekday - 1)), today);
      case 'year':
        return (DateTime(today.year, 1, 1), today);
      case 'all':
        return (DateTime(2000, 1, 1), today);
      default:
        return (DateTime(today.year, today.month, 1), today);
    }
  }

  Future<Map<String, dynamic>> fetchStats(DateTime from, DateTime to,
      {bool events = false}) {
    final query = Uri(queryParameters: {
      'from': keyOf(from),
      'to': keyOf(to),
      if (events) 'include_events': '1',
    }).query;
    return widget.api.getJson('/api/reading/stats?' + query);
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() {
      busy = true;
      loading = data.isEmpty;
      error = null;
    });
    try {
      final session = await widget.api.getJson('/api/auth/session');
      if (session['authenticated'] != true || session['accessEnabled'] != true) {
        throw const FrameApiException(message: 'Cloudflare Access 尚未確認登入狀態。');
      }
      final prefs = await widget.api.getJson('/api/reading/preferences');
      final pref = prefs['preferences'];
      final goal = pref is Map ? number(pref['goalMinutes'] ?? 30) : 30;
      final r = range();
      final stats = await fetchStats(r.$1, r.$2);
      if (!mounted) return;
      setState(() {
        goalMinutes = goal.clamp(5, 240).toInt();
        data = stats;
        days = dayMap(stats['days']);
        allDays = dayMap(stats['allDays']);
        loading = false;
        busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        busy = false;
        error = e.toString();
      });
    }
  }

  Future<void> changeGoal(int? value) async {
    if (value == null || value == goalMinutes) return;
    setState(() => goalMinutes = value);
    try {
      final result = await widget.api.postJson('/api/reading/preferences', {
        'key': 'goalMinutes',
        'value': value,
      });
      if (result['ok'] != true) throw const FrameApiException(message: '每日目標保存失敗。');
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '每日目標保存失敗：' + e.toString());
    }
  }

  String duration(int value) {
    final s = value < 0 ? 0 : value;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '$h 小時 $m 分鐘';
    if (s >= 60) return '$m 分鐘';
    return s > 0 ? '$s 秒' : '0 分鐘';
  }

  String shortDuration(int value) {
    final s = value < 0 ? 0 : value;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    if (h > 0) return '$h 小時';
    if (s >= 60) return '$m 分';
    return s > 0 ? '$s 秒' : '0 分';
  }

  String timestamp(dynamic value) {
    final n = number(value);
    return n <= 0 ? '' : DateTime.fromMillisecondsSinceEpoch(n).toIso8601String();
  }

  String csvCell(String value) => '"' + value.replaceAll('"', '""') + '"';

  Future<void> export(String kind) async {
    final r = range();
    try {
      final stats = await fetchStats(r.$1, r.$2, events: true);
      final events = stats['events'] is List
          ? (stats['events'] as List).whereType<Map>().toList()
          : <Map>[];
      String output;
      if (kind == 'JSON') {
        output = const JsonEncoder.withIndent('  ').convert({
          'period': period,
          'from': keyOf(r.$1),
          'to': keyOf(r.$2),
          'totalSeconds': number(stats['totalSeconds']),
          'booksOpened': number(stats['booksOpened']),
          'days': stats['days'] ?? [],
          'allDays': stats['allDays'] ?? [],
          'topBooks': stats['topBooks'] ?? [],
          'timeBands': stats['timeBands'] ?? [],
          'events': events,
        });
      } else {
        final rows = <List<String>>[
          ['日期', '書名', '格式', '閱讀秒數', '開始時間', '結束時間'],
        ];
        for (final item in events) {
          rows.add([
            item['dayKey']?.toString() ?? '',
            item['bookTitle']?.toString() ?? '',
            item['format']?.toString() ?? '',
            number(item['seconds']).toString(),
            timestamp(item['startedAt']),
            timestamp(item['endedAt']),
          ]);
        }
        output = '\uFEFF' + rows.map((row) => row.map(csvCell).join(',')).join('\r\n');
      }
      final extension = kind == 'JSON' ? 'json' : 'csv';
      final fileName =
          'frame-ebook-reading-${keyOf(r.$1)}-${keyOf(r.$2)}.$extension';
      final saved = await _exportService.save(
        bytes: Uint8List.fromList(utf8.encode(output)),
        fileName: fileName,
        mimeType: kind == 'JSON' ? 'application/json' : 'text/csv',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(saved
                ? '雲端 $kind 已保存：$fileName'
                : '已取消 $kind 匯出，沒有保存檔案。'),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '匯出失敗：' + e.toString());
    }
  }

  List<Map<String, dynamic>> trendItems() {
    final r = range();
    final result = <Map<String, dynamic>>[];
    if (period == 'week' || period == 'month') {
      final count = r.$2.difference(r.$1).inDays + 1;
      for (var i = 0; i < count; i++) {
        final d = r.$1.add(Duration(days: i));
        final label = period == 'week'
            ? ['一', '二', '三', '四', '五', '六', '日'][i]
            : d.day.toString();
        result.add({'label': label, 'seconds': days[keyOf(d)] ?? 0});
      }
    } else if (period == 'year') {
      for (var m = 1; m <= 12; m++) {
        var total = 0;
        final prefix = DateTime.now().year.toString().padLeft(4, '0') +
            '-' + m.toString().padLeft(2, '0') + '-';
        for (final entry in days.entries) {
          if (entry.key.startsWith(prefix)) total += entry.value;
        }
        result.add({'label': '$m 月', 'seconds': total});
      }
    } else {
      final monthly = <String, int>{};
      for (final entry in days.entries) {
        if (entry.key.length >= 7) {
          final k = entry.key.substring(0, 7);
          monthly[k] = (monthly[k] ?? 0) + entry.value;
        }
      }
      final keys = monthly.keys.toList()..sort();
      final start = keys.length > 12 ? keys.length - 12 : 0;
      for (final k in keys.skip(start)) {
        result.add({'label': k.substring(5, 7) + ' 月', 'seconds': monthly[k] ?? 0});
      }
    }
    return result;
  }

  (int, int, int) streak() {
    final active = allDays.entries
        .where((e) => e.value >= 60)
        .map((e) => e.key)
        .toList()
      ..sort();
    final set = active.toSet();
    final now = DateTime.now();
    var cursor = DateTime(now.year, now.month, now.day);
    if (!set.contains(keyOf(cursor))) cursor = cursor.subtract(const Duration(days: 1));
    var current = 0;
    while (set.contains(keyOf(cursor))) {
      current++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    var best = 0;
    var run = 0;
    int? previous;
    for (final k in active) {
      final d = DateTime.tryParse(k);
      if (d == null) continue;
      final ordinal = DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay;
      run = previous != null && ordinal - previous == 1 ? run + 1 : 1;
      if (run > best) best = run;
      previous = ordinal;
    }
    return (current, best, active.length);
  }

  int monthTotal() {
    var total = 0;
    final count = DateTime(calendarMonth.year, calendarMonth.month + 1, 0).day;
    for (var i = 1; i <= count; i++) {
      total += allDays[keyOf(DateTime(calendarMonth.year, calendarMonth.month, i))] ?? 0;
    }
    return total;
  }

  List<Map<String, dynamic>> recentSessions() {
    final raw = data['recentEvents'];
    if (raw is! List) return const [];
    final ordered = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      ..sort((a, b) => number(a['startedAt']).compareTo(number(b['startedAt'])));
    final result = <Map<String, dynamic>>[];
    for (final item in ordered) {
      if (result.isNotEmpty) {
        final previous = result.last;
        final gap = number(item['startedAt']) - number(previous['endedAt']);
        if (previous['bookId'] == item['bookId'] &&
            previous['dayKey'] == item['dayKey'] && gap >= 0 && gap <= 45000) {
          previous['seconds'] = number(previous['seconds']) + number(item['seconds']);
          if (number(item['endedAt']) > number(previous['endedAt'])) {
            previous['endedAt'] = item['endedAt'];
          }
          continue;
        }
      }
      result.add({...item, 'seconds': number(item['seconds'])});
    }
    result.sort((a, b) => number(b['endedAt']).compareTo(number(a['endedAt'])));
    return result.take(6).toList();
  }

  Widget panelBox(Widget child) => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: panel,
          border: Border.all(color: line.withOpacity(0.8)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      );

  Widget sectionTitle(String kicker, String title) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(kicker, style: const TextStyle(color: Color(0xFF8F7BB7), fontSize: 9, letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 17, fontWeight: FontWeight.w600)),
        ],
      );

  Widget metric(String value, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: const TextStyle(color: accent, fontSize: 25, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: muted, fontSize: 9)),
          ],
        ),
      );

  Widget summaryCard(String label, String value, String note, {bool featured = false}) =>
      Container(
        width: 220,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: featured ? soft : panel,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: line.withOpacity(0.8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(), style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
            const SizedBox(height: 9),
            Text(value, style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            Text(note, style: const TextStyle(color: muted, fontSize: 10)),
          ],
        ),
      );

  Widget goalPanel() {
    final today = allDays[keyOf(DateTime.now())] ?? 0;
    final percent = (today / (goalMinutes * 60) * 100).round().clamp(0, 100);
    final reached = allDays.values.where((v) => v >= goalMinutes * 60).length;
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('DAILY READING GOAL', '今天的閱讀目標'),
        const SizedBox(height: 18),
        Row(children: [
          SizedBox(
            width: 88,
            height: 88,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(child: CircularProgressIndicator(
                value: percent / 100,
                strokeWidth: 8,
                backgroundColor: const Color(0xFF302A3D),
                valueColor: const AlwaysStoppedAnimation(accent),
              )),
              Text('$percent%', style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 20, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 15),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(duration(today), style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 17, fontWeight: FontWeight.w600)),
              Text('每日目標 $goalMinutes 分鐘', style: const TextStyle(color: muted, fontSize: 10)),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: goals.contains(goalMinutes) ? goalMinutes : 30,
                decoration: const InputDecoration(
                  labelText: '調整每日目標',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                ),
                items: goals.map((v) => DropdownMenuItem(value: v, child: Text('$v 分鐘'))).toList(),
                onChanged: changeGoal,
              ),
            ],
          )),
        ]),
        const SizedBox(height: 12),
        Text(percent >= 100 ? '今日目標已達成。' : '再讀 ' + duration((goalMinutes * 60 - today).clamp(0, 1 << 30)) + ' 即可達成目標。',
          style: const TextStyle(color: muted, fontSize: 10, height: 1.5)),
        Text('$reached 天達標', style: const TextStyle(color: accent, fontSize: 10)),
      ],
    ));
  }

  Widget streakPanel() {
    final s = streak();
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('YOUR READING RHYTHM', '閱讀習慣'),
        const SizedBox(height: 22),
        Row(children: [
          metric(s.$1.toString(), '目前連續閱讀（天）'),
          metric(s.$2.toString(), '最長連續閱讀（天）'),
          metric(s.$3.toString(), '累計閱讀日（天）'),
        ]),
        const SizedBox(height: 15),
        Text(s.$1 > 0 ? '連續閱讀第 ' + s.$1.toString() + ' 天，保持舒服的節奏。' : '今天讀滿 1 分鐘，就能點亮今天的閱讀足跡。',
          style: const TextStyle(color: muted, fontSize: 10)),
      ],
    ));
  }

  Widget calendarPanel() {
    final offset = DateTime(calendarMonth.year, calendarMonth.month, 1).weekday - 1;
    final count = DateTime(calendarMonth.year, calendarMonth.month + 1, 0).day;
    final now = DateTime.now();
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: sectionTitle('READING CALENDAR', '閱讀日曆')),
          IconButton(
            tooltip: '上一個月',
            onPressed: () => setState(() => calendarMonth = DateTime(calendarMonth.year, calendarMonth.month - 1)),
            icon: const Icon(Icons.chevron_left),
          ),
          Text(calendarMonth.year.toString() + ' 年 ' + calendarMonth.month.toString() + ' 月',
            style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 11)),
          IconButton(
            tooltip: '下一個月',
            onPressed: calendarMonth.year == now.year && calendarMonth.month == now.month
                ? null
                : () => setState(() => calendarMonth = DateTime(calendarMonth.year, calendarMonth.month + 1)),
            icon: const Icon(Icons.chevron_right),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: ['一','二','三','四','五','六','日'].map((v) => Expanded(
          child: Center(child: Text(v, style: const TextStyle(color: muted, fontSize: 9))),
        )).toList()),
        const SizedBox(height: 7),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: offset + count,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
            childAspectRatio: 1.55,
          ),
          itemBuilder: (context, index) {
            if (index < offset) return const SizedBox.shrink();
            final day = index - offset + 1;
            final d = DateTime(calendarMonth.year, calendarMonth.month, day);
            final key = keyOf(d);
            final seconds = allDays[key] ?? 0;
            final level = seconds < 60 ? 0 : seconds < 900 ? 1 : seconds < 1800 ? 2 : seconds < 3600 ? 3 : 4;
            const colors = [
              Color(0xFF252130), Color(0xFF493969), Color(0xFF634A91),
              Color(0xFF8064B7), Color(0xFFB49AE8),
            ];
            final today = key == keyOf(now);
            return Tooltip(
              message: key + ' · ' + duration(seconds),
              child: Container(
                decoration: BoxDecoration(
                  color: colors[level],
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: today ? accent : Colors.transparent, width: today ? 1.5 : 0),
                ),
                child: Center(child: Text(day.toString(), style: TextStyle(
                  color: level >= 3 ? const Color(0xFF16131F) : const Color(0xFFD9D2E5),
                  fontSize: 10,
                  fontWeight: today ? FontWeight.w700 : FontWeight.w400,
                ))),
              ),
            );
          },
        ),
        const SizedBox(height: 9),
        Align(alignment: Alignment.centerRight,
          child: Text('本月 ' + duration(monthTotal()), style: const TextStyle(color: muted, fontSize: 10))),
      ],
    ));
  }

  Widget trendPanel() {
    final items = trendItems();
    final maxValue = items.fold<int>(1, (a, e) => number(e['seconds']) > a ? number(e['seconds']) : a);
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('READING TREND', '閱讀趨勢'),
        const SizedBox(height: 15),
        SizedBox(height: 175, child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (items.length <= 12 || i % 5 == 0)
                      Text(shortDuration(number(items[i]['seconds'])), maxLines: 1,
                        style: const TextStyle(color: muted, fontSize: 7))
                    else
                      const SizedBox(height: 9),
                    const SizedBox(height: 4),
                    Expanded(child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: (number(items[i]['seconds']) / maxValue).clamp(0.015, 1.0).toDouble(),
                        widthFactor: 0.72,
                        alignment: Alignment.bottomCenter,
                        child: Container(decoration: BoxDecoration(
                          color: const Color(0xFF9875EC),
                          borderRadius: BorderRadius.circular(4),
                        )),
                      ),
                    )),
                    const SizedBox(height: 5),
                    Text(items[i]['label'].toString(), maxLines: 1,
                      style: const TextStyle(color: muted, fontSize: 7)),
                  ],
                ),
              )),
          ],
        )),
      ],
    ));
  }

  Widget topBooksPanel() {
    final raw = data['topBooks'];
    final books = raw is List ? raw.whereType<Map>().take(5).toList() : <Map>[];
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('MOST READ', '最常閱讀'),
        const SizedBox(height: 13),
        if (books.isEmpty)
          const Text('目前還沒有閱讀紀錄。', style: TextStyle(color: muted, fontSize: 10))
        else
          for (var i = 0; i < books.length; i++)
            Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
              Text((i + 1).toString().padLeft(2, '0'),
                style: const TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Expanded(child: Text(books[i]['title']?.toString() ?? '未命名書籍',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 10))),
              const SizedBox(width: 8),
              Text(duration(number(books[i]['seconds'])), style: const TextStyle(color: muted, fontSize: 9)),
            ])),
      ],
    ));
  }

  Widget timeBandsPanel() {
    final raw = data['timeBands'];
    final values = raw is List ? raw.map(number).toList() : [0, 0, 0, 0];
    while (values.length < 4) { values.add(0); }
    const labels = ['清晨／上午', '白天', '傍晚／夜間', '深夜'];
    final maxValue = values.fold<int>(1, (a, b) => a > b ? a : b);
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('TIME OF DAY', '閱讀時段'),
        const SizedBox(height: 15),
        for (var i = 0; i < 4; i++)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(children: [
            Row(children: [
              Expanded(child: Text(labels[i], style: const TextStyle(color: muted, fontSize: 9))),
              Text(shortDuration(values[i]), style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 9)),
            ]),
            const SizedBox(height: 5),
            ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(
              value: values[i] / maxValue,
              minHeight: 7,
              backgroundColor: const Color(0xFF302A3D),
              valueColor: const AlwaysStoppedAnimation(accent),
            )),
          ])),
      ],
    ));
  }

  Widget recentPanel() {
    final sessions = recentSessions();
    return panelBox(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        sectionTitle('RECENT SESSIONS', '最近閱讀'),
        const SizedBox(height: 13),
        if (sessions.isEmpty)
          const Text('完成第一次閱讀後，這裡就會留下紀錄。', style: TextStyle(color: muted, fontSize: 10))
        else
          for (final item in sessions)
            Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item['bookTitle']?.toString() ?? '未命名書籍', maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFF4F0FA), fontSize: 10, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text((item['dayKey'] ?? '').toString() + ' · ' + (item['format'] ?? 'EPUB').toString(),
                  style: const TextStyle(color: muted, fontSize: 8)),
              ])),
              Text(shortDuration(number(item['seconds'])), style: const TextStyle(color: accent, fontSize: 9)),
            ])),
      ],
    ));
  }

  Widget errorBanner() {
    if (error == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(color: const Color(0xFF301F2A), borderRadius: BorderRadius.circular(9)),
      child: Row(children: [
        const Icon(Icons.error_outline, color: Color(0xFFFFB7B7), size: 17),
        const SizedBox(width: 8),
        Expanded(child: Text(error!, style: const TextStyle(color: Color(0xFFFFB7B7), fontSize: 10))),
        IconButton(
          tooltip: '關閉',
          onPressed: () => setState(() => error = null),
          icon: const Icon(Icons.close, color: Color(0xFFFFB7B7), size: 15),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = range();
    final total = number(data['totalSeconds']);
    final dayCount = days.values.where((v) => v >= 60).length;
    final allKeys = allDays.keys.toList()..sort();
    final first = period == 'all' && allKeys.isNotEmpty
        ? (DateTime.tryParse(allKeys.first) ?? r.$1)
        : r.$1;
    final nDays = r.$2.difference(first).inDays + 1;
    final average = nDays <= 0 ? 0 : (total / nDays / 60).round();
    const periodNames = {'week': '本週', 'month': '本月', 'year': '今年', 'all': '累計'};

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: panel,
        title: const Text('閱讀時光'),
        actions: [
          IconButton(
            tooltip: '重新載入',
            onPressed: busy ? null : refresh,
            icon: busy
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: accent))
          : RefreshIndicator(
              color: accent,
              onRefresh: refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(15, 17, 15, 30),
                children: [
                  Center(child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('READ · REFLECT · REPEAT',
                        style: TextStyle(color: Color(0xFF8F7BB7), fontSize: 9, letterSpacing: 2)),
                      const SizedBox(height: 5),
                      const Text('把閱讀的時間，慢慢累積成自己的節奏。',
                        style: TextStyle(color: Color(0xFFF4F0FA), fontSize: 21, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 14),
                      errorBanner(),
                      if (error != null) const SizedBox(height: 10),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'week', label: Text('本週')),
                          ButtonSegment(value: 'month', label: Text('本月')),
                          ButtonSegment(value: 'year', label: Text('今年')),
                          ButtonSegment(value: 'all', label: Text('累計')),
                        ],
                        selected: {period},
                        onSelectionChanged: (selection) {
                          if (selection.isEmpty) return;
                          setState(() => period = selection.first);
                          refresh();
                        },
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: Text(
                          periodNames[period]! + ' · ' + keyOf(r.$1) + ' 至 ' + keyOf(r.$2) + ' · 雲端 D1',
                          style: const TextStyle(color: muted, fontSize: 9))),
                        IconButton(tooltip: '匯出 JSON', onPressed: busy ? null : () => export('JSON'), icon: const Icon(Icons.data_object, size: 18)),
                        IconButton(tooltip: '匯出 CSV', onPressed: busy ? null : () => export('CSV'), icon: const Icon(Icons.table_view, size: 18)),
                      ]),
                      const SizedBox(height: 8),
                      Wrap(spacing: 9, runSpacing: 9, children: [
                        summaryCard('Total Reading Time', duration(total), '目前期間累積閱讀時間', featured: true),
                        summaryCard('Reading Days', '$dayCount 天', '每日累積滿 1 分鐘'),
                        summaryCard('Daily Average', '$average 分鐘', '以自然日計算'),
                        summaryCard('Books Opened', number(data['booksOpened']).toString() + ' 本', '本期間有閱讀紀錄'),
                      ]),
                      const SizedBox(height: 13),
                      LayoutBuilder(builder: (context, c) {
                        final width = c.maxWidth >= 720 ? (c.maxWidth - 12) / 2 : c.maxWidth;
                        return Wrap(spacing: 12, runSpacing: 12, children: [
                          SizedBox(width: width, child: goalPanel()),
                          SizedBox(width: width, child: streakPanel()),
                        ]);
                      }),
                      const SizedBox(height: 13),
                      calendarPanel(),
                      const SizedBox(height: 13),
                      trendPanel(),
                      const SizedBox(height: 13),
                      LayoutBuilder(builder: (context, c) {
                        final width = c.maxWidth >= 720 ? (c.maxWidth - 12) / 2 : c.maxWidth;
                        return Wrap(spacing: 12, runSpacing: 12, children: [
                          SizedBox(width: width, child: topBooksPanel()),
                          SizedBox(width: width, child: timeBandsPanel()),
                        ]);
                      }),
                      const SizedBox(height: 13),
                      recentPanel(),
                      const SizedBox(height: 14),
                      panelBox(Row(children: [
                        const Icon(Icons.cloud_done_outlined, color: accent),
                        const SizedBox(width: 9),
                        const Expanded(child: Text(
                          '雲端閱讀資料依 Cloudflare Access 身分隔離，透過 D1 跨裝置同步。',
                          style: TextStyle(color: muted, fontSize: 9, height: 1.5))),
                        TextButton(onPressed: busy ? null : refresh, child: const Text('重新整理')),
                      ])),
                    ]),
                  )),
                ],
              ),
            ),
    );
  }
}
