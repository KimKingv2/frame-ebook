import 'package:material_ui/material_ui.dart';

import 'frame_book.dart';

const _bg = Color(0xFF12101A);
const _panel = Color(0xFF1B1825);
const _ink = Color(0xFFF4F0FA);
const _muted = Color(0xFFAAA2B8);
const _faint = Color(0xFF81788F);
const _accent = Color(0xFFC5ADFF);
const _line = Color(0x55393247);

/// Read-only metadata rendered in place of the bookshelf.
/// No API dependency, dialog, editable field, or nested route is used.
class FrameBookDetailsScreen extends StatelessWidget {
  const FrameBookDetailsScreen({
    required this.book,
    required this.onBack,
    super.key,
  });

  final FrameBook book;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final title = book.title.isNotEmpty ? book.title : book.fileName;
    final comic = book.isComic;
    final basic = <Widget>[
      _info('作者', _orFallback(book.author)),
      _info('格式', _orFallback(book.format)),
      _info('檔案名稱', _orFallback(book.fileName)),
      _info('檔案大小', _formatBytes(book.size)),
      _info(
        comic ? '頁數' : '內容項目',
        book.pageCount > 0
            ? book.pageCount.toString() + (comic ? ' 頁' : ' 項')
            : '未提供',
      ),
      _info('收藏分類', book.shelf == 'comics' ? '漫畫' : '電子書'),
      _info(
        '閱讀進度',
        book.progressPercent > 0
            ? '${book.progressPercent}% · ${book.progressLabel}'
            : '尚未開始',
      ),
      if (book.path.isNotEmpty) _info('檔案路徑', book.path),
    ];

    final metadata = <Widget>[
      if (book.language.isNotEmpty) _info('語言', book.language),
      if (book.publisher.isNotEmpty) _info('出版社', book.publisher),
      if (book.publishedAt.isNotEmpty) _info('出版日期', book.publishedAt),
      if (book.identifier.isNotEmpty) _info('識別碼', book.identifier),
      if (book.subjects.isNotEmpty) _info('主題', book.subjects.join('、')),
      if (book.description.isNotEmpty)
        _info('作品簡介', book.description, multiline: true),
    ];
    final comicMetadata = _comicMetadataItems(book.comicMetadata);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回書架',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text('作品元資料'),
        backgroundColor: _bg,
        foregroundColor: _ink,
        elevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        comic ? 'COMIC METADATA' : 'EBOOK METADATA',
                        style: const TextStyle(
                          color: _accent,
                          fontSize: 9,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SelectableText(
                        title,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 22,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        book.author.isEmpty ? '作者未提供' : book.author,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _section('檔案與閱讀資訊', basic),
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _section('作品元資料', metadata),
                ],
                if (comicMetadata.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _section('Bangumi 漫畫資料', comicMetadata),
                ],
                if (metadata.isEmpty && comicMetadata.isEmpty) ...[
                  const SizedBox(height: 14),
                  _section('作品元資料', const [
                    Text(
                      '這本作品目前沒有額外的出版或作品描述資料。上方已列出書架索引中可取得的基本資訊。',
                      style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static List<Widget> _comicMetadataItems(Map<String, dynamic> data) {
    if (data.isEmpty) return const [];
    final items = <Widget>[];
    final nameCn = data['nameCn']?.toString() ?? '';
    final name = data['name']?.toString() ?? '';
    if (nameCn.isNotEmpty) items.add(_info('中文名稱', nameCn));
    if (name.isNotEmpty && name != nameCn) {
      items.add(_info('原始名稱', name));
    }
    _addText(items, '作者', data['author']);
    _addText(items, '發行日期', data['date']);
    _addText(items, '作品類型', data['categoryLabel']);
    _addText(items, 'Bangumi ID', data['id']);

    final score = data['score'];
    if (score != null && score.toString().isNotEmpty && score.toString() != '0') {
      items.add(_info('評分', score.toString()));
    }
    final ratingCount = data['ratingCount'];
    if (ratingCount != null &&
        ratingCount.toString().isNotEmpty &&
        ratingCount.toString() != '0') {
      items.add(_info('評分人數', ratingCount.toString()));
    }
    final tags = data['tags'];
    if (tags is List && tags.isNotEmpty) {
      final values = tags.map((tag) {
        if (tag is Map) {
          return (tag['name'] ?? tag['label'] ?? '').toString();
        }
        return tag.toString();
      }).where((value) => value.isNotEmpty).toList();
      if (values.isNotEmpty) items.add(_info('標籤', values.join('、')));
    }
    _addText(items, '作品簡介', data['summary'], multiline: true);
    return items;
  }

  static void _addText(
    List<Widget> items,
    String label,
    dynamic value, {
    bool multiline = false,
  }) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text != 'null') {
      items.add(_info(label, text, multiline: multiline));
    }
  }

  static Widget _section(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _accent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 11),
          ...children,
        ],
      ),
    );
  }

  static Widget _info(String label, String value, {bool multiline = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(color: _faint, fontSize: 10, height: 1.6),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                color: _muted,
                fontSize: 11,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _orFallback(String value) => value.isEmpty ? '未提供' : value;

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '未提供';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
