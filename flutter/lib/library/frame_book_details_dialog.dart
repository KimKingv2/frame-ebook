import 'package:material_ui/material_ui.dart';

import '../core/frame_api_client.dart';
import '../core/frame_api_scope.dart';
import 'frame_book.dart';
import 'frame_library_repository.dart';

const _dialogPanel = Color(0xFF1B1825);
const _dialogText = Color(0xFFF4F0FA);
const _dialogMuted = Color(0xFFAAA2B8);
const _dialogFaint = Color(0xFF797184);
const _dialogAccent = Color(0xFFC5ADFF);
const _dialogLine = Color(0xFF393247);

class FrameBookDetailsDialog extends StatefulWidget {
  const FrameBookDetailsDialog({
    required this.book,
    required this.books,
    super.key,
  });

  final FrameBook book;
  final List<FrameBook> books;

  @override
  State<FrameBookDetailsDialog> createState() => _FrameBookDetailsDialogState();
}

class _FrameBookDetailsDialogState extends State<FrameBookDetailsDialog> {
  late final TextEditingController _title;
  late final TextEditingController _author;
  late final TextEditingController _bangumiQuery;
  late FrameApiClient _api;
  late FrameLibraryRepository _repository;
  bool _servicesReady = false;
  String _shelf = 'books';
  String _linkTargetId = '';
  bool _saving = false;
  bool _searchingBangumi = false;
  bool _applyingBangumi = false;
  bool _searchingLinks = false;
  bool _linkingOldBook = false;
  String _bangumiStatus = '';
  String _linkStatus = '';
  List<Map<String, dynamic>> _bangumiCandidates = [];
  List<Map<String, dynamic>> _linkCandidates = [];

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.book.title);
    _author = TextEditingController(text: widget.book.author);
    final metadata = widget.book.comicMetadata;
    _bangumiQuery = TextEditingController(
      text: (metadata['nameCn'] ??
              metadata['name'] ??
              widget.book.folderTitle ??
              widget.book.title)
          .toString(),
    );
    _shelf = widget.book.isComic ? 'comics' : 'books';
    _linkTargetId = widget.book.id;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_servicesReady) return;
    _api = FrameApiScope.of(context);
    _repository = FrameLibraryRepository(_api);
    _servicesReady = true;
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _bangumiQuery.dispose();
    super.dispose();
  }

  FrameBook get _linkTarget {
    for (final book in widget.books) {
      if (book.id == _linkTargetId) return book;
    }
    return widget.book;
  }

  List<FrameBook> get _volumes {
    final current = widget.book;
    if (current.folderPath.isEmpty) return [current];
    final result = widget.books.where((book) =>
        book.provider == current.provider &&
        book.library == current.library &&
        book.rootPath == current.rootPath &&
        book.folderPath == current.folderPath).toList();
    result.sort((a, b) => a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase()));
    return result.isEmpty ? [current] : result;
  }

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _linkStatus = '書名不可為空。');
      return;
    }
    setState(() {
      _saving = true;
      _linkStatus = '';
    });
    try {
      await _repository.updateMetadata(
        book: widget.book,
        title: _title.text.trim(),
        author: _author.text.trim(),
        shelf: _shelf,
      );
      if (mounted) Navigator.pop(context, 'saved');
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _linkStatus = '保存失敗：$error';
        });
      }
    }
  }

  Future<void> _resetOpf() async {
    setState(() {
      _saving = true;
      _linkStatus = '';
    });
    try {
      await _repository.resetOpfMetadata(widget.book);
      if (mounted) Navigator.pop(context, 'reset');
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _linkStatus = '恢復 EPUB 內部資訊失敗：$error';
        });
      }
    }
  }

  Future<void> _searchBangumi() async {
    final keyword = _bangumiQuery.text.trim();
    if (keyword.isEmpty) {
      setState(() => _bangumiStatus = '請輸入漫畫名稱。');
      return;
    }
    setState(() {
      _searchingBangumi = true;
      _bangumiStatus = '正在搜尋 Bangumi 漫畫資料……';
      _bangumiCandidates = [];
    });
    try {
      final response = await _api.postJson(
        '/api/comics/bangumi/search',
        {'keyword': keyword},
      );
      final rawItems = response['items'];
      final items = rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _bangumiCandidates = items;
        _bangumiStatus = items.isEmpty
            ? '沒有找到候選作品。可以試試日文原名或其他常用名稱。'
            : '找到 ${items.length} 個候選條目。請核對名稱、日期與標籤，再套用正確作品。';
      });
    } catch (error) {
      if (mounted) setState(() => _bangumiStatus = '搜尋失敗：$error');
    } finally {
      if (mounted) setState(() => _searchingBangumi = false);
    }
  }

  Future<void> _applyBangumi(Map<String, dynamic> item) async {
    final subjectId = int.tryParse(item['id']?.toString() ?? '') ?? 0;
    if (subjectId < 1) return;
    setState(() {
      _applyingBangumi = true;
      _bangumiStatus = '正在取得 Bangumi 完整資料，並套用至同資料夾卷冊……';
    });
    try {
      final response = await _api.postJson('/api/comics/bangumi/link', {
        'book': widget.book.descriptor(),
        'subjectId': subjectId,
      });
      final linked = int.tryParse(response['linkedBooks']?.toString() ?? '') ?? 0;
      final subject = response['subject'] is Map
          ? Map<String, dynamic>.from(response['subject'] as Map)
          : <String, dynamic>{};
      if (mounted) {
        setState(() {
          _bangumiStatus =
              '已關聯 ${subject['nameCn'] ?? subject['name'] ?? 'Bangumi 作品'}，共套用至 $linked 個卷冊。';
        });
        Navigator.pop(context, 'bangumi');
      }
    } catch (error) {
      if (mounted) setState(() => _bangumiStatus = '套用失敗：$error');
    } finally {
      if (mounted) setState(() => _applyingBangumi = false);
    }
  }

  Future<void> _findOldBooks() async {
    final target = _linkTarget;
    final query = Uri(queryParameters: {
      'book_id': target.id,
      'provider': target.provider,
      'library': target.library,
      'root_path': target.rootPath,
      'path': target.path,
    }).query;
    setState(() {
      _searchingLinks = true;
      _linkStatus = '正在搜尋可關聯的舊書籍資料……';
      _linkCandidates = [];
    });
    try {
      final response = await _api.getJson('/api/reading/link?$query');
      final rawItems = response['candidates'];
      final items = rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _linkCandidates = items;
        _linkStatus = items.isEmpty
            ? '目前沒有可關聯的舊書籍資料。'
            : '找到 ${items.length} 筆尚未關聯的舊書籍資料。請核對檔名和閱讀記錄後再選擇。';
      });
    } catch (error) {
      if (mounted) setState(() => _linkStatus = '搜尋失敗：$error');
    } finally {
      if (mounted) setState(() => _searchingLinks = false);
    }
  }

  Future<void> _linkOldBook(Map<String, dynamic> candidate) async {
    final oldId = candidate['bookId']?.toString() ?? '';
    if (oldId.isEmpty) return;
    final oldTitle =
        candidate['title']?.toString() ?? candidate['fileName']?.toString() ?? '舊書籍';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _dialogPanel,
        title: const Text('確認關聯舊書籍'),
        content: Text(
          '確定將「$oldTitle」的舊閱讀資料關聯到「${_linkTarget.fileName}」嗎？\n\n閱讀進度、自訂資訊、閱讀統計，以及資料庫中已有的標註都會合併。這項操作完成後不提供自動還原。',
          style: const TextStyle(color: _dialogMuted, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確認關聯'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _linkingOldBook = true;
      _linkStatus = '正在合併舊書籍資料……';
    });
    try {
      final response = await _api.postJson('/api/reading/link', {
        'book': _linkTarget.descriptor(),
        'oldBookId': oldId,
      });
      final moved = response['moved'] is Map
          ? Map<String, dynamic>.from(response['moved'] as Map)
          : <String, dynamic>{};
      final stateCount = moved['readingState'] == true || moved['readingState'] == 1 ? 1 : 0;
      final events = int.tryParse(moved['readingEvents']?.toString() ?? '') ?? 0;
      final annotations = int.tryParse(moved['annotations']?.toString() ?? '') ?? 0;
      if (mounted) {
        setState(() {
          _linkStatus =
              '關聯完成。閱讀狀態 ${stateCount > 0 ? '已合併' : '無'} · 閱讀事件 $events 筆 · 標註 $annotations 筆';
        });
        Navigator.pop(context, 'linked');
      }
    } catch (error) {
      if (mounted) setState(() => _linkStatus = '關聯失敗：$error');
    } finally {
      if (mounted) setState(() => _linkingOldBook = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final comic = book.isComic;
    final bangumi = book.comicMetadata;
    final metadataLines = <String>[
      if (book.language.isNotEmpty) '語言：${book.language}',
      if (book.publisher.isNotEmpty) '出版社：${book.publisher}',
      if (book.publishedAt.isNotEmpty) '出版日期：${book.publishedAt}',
      if (book.identifier.isNotEmpty) '識別碼：${book.identifier}',
      if (book.subjects.isNotEmpty) '主題：${book.subjects.join('、')}',
      if (book.description.isNotEmpty) '簡介：${book.description}',
    ];

    return AlertDialog(
      backgroundColor: _dialogPanel,
      surfaceTintColor: Colors.transparent,
      title: Text(comic ? '漫畫資訊' : '電子書資訊'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _label('書名'),
              TextField(
                controller: _title,
                maxLength: 240,
                decoration: const InputDecoration(hintText: '輸入作品名稱', counterText: ''),
              ),
              const SizedBox(height: 13),
              _label('作者'),
              TextField(
                controller: _author,
                maxLength: 240,
                decoration: const InputDecoration(hintText: '作者未提供', counterText: ''),
              ),
              const SizedBox(height: 13),
              _label('收藏分類'),
              DropdownButtonFormField<String>(
                value: _shelf,
                items: const [
                  DropdownMenuItem(value: 'books', child: Text('電子書')),
                  DropdownMenuItem(value: 'comics', child: Text('漫畫')),
                ],
                onChanged: book.format == 'CBZ'
                    ? null
                    : (value) {
                        if (value != null) setState(() => _shelf = value);
                      },
              ),
              const SizedBox(height: 17),
              _metaRow('格式', book.format),
              _metaRow(
                '內容',
                book.pageCount > 0
                    ? '${book.pageCount}${book.format == 'CBZ' ? ' 頁' : ' 個內容項目'}'
                    : '未提供',
              ),
              _metaRow('檔案', book.fileName),
              _metaRow('大小', _formatBytes(book.size)),
              _metaRow(
                '閱讀進度',
                book.progressPercent > 0
                    ? '${book.progressPercent}% · ${book.progressLabel}'
                    : '尚未開始',
              ),
              if (metadataLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(color: _dialogLine),
                for (final line in metadataLines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(line,
                        style: const TextStyle(color: _dialogMuted, fontSize: 10, height: 1.5)),
                  ),
              ],
              if (book.manualTitle || book.manualAuthor) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _resetOpf,
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('恢復 EPUB 內部資訊'),
                ),
              ],
              if (comic) ...[
                const SizedBox(height: 20),
                const Divider(color: _dialogLine),
                const Text(
                  'BANGUMI 漫畫資料',
                  style: TextStyle(color: _dialogAccent, fontSize: 10, letterSpacing: 1.6),
                ),
                if (bangumi.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '已關聯：${bangumi['nameCn'] ?? bangumi['name'] ?? 'Bangumi 作品'}',
                    style: const TextStyle(color: _dialogText, fontSize: 11),
                  ),
                  if ((bangumi['author'] ?? '').toString().isNotEmpty)
                    Text('作者：${bangumi['author']}',
                        style: const TextStyle(color: _dialogMuted, fontSize: 10)),
                  if ((bangumi['date'] ?? '').toString().isNotEmpty)
                    Text('日期：${bangumi['date']}',
                        style: const TextStyle(color: _dialogMuted, fontSize: 10)),
                  if ((bangumi['score'] ?? 0).toString() != '0')
                    Text(
                      '評分：${bangumi['score']} · ${bangumi['ratingCount'] ?? 0} 人',
                      style: const TextStyle(color: _dialogMuted, fontSize: 10),
                    ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: _bangumiQuery,
                  maxLength: 100,
                  onSubmitted: (_) => _searchBangumi(),
                  decoration: const InputDecoration(
                    hintText: '漫畫名稱、日文原名或別名',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 7),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: _searchingBangumi || _applyingBangumi ? null : _searchBangumi,
                    icon: _searchingBangumi
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search, size: 16),
                    label: const Text('搜尋 Bangumi'),
                  ),
                ),
                if (_bangumiStatus.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(_bangumiStatus,
                      style: const TextStyle(color: _dialogMuted, fontSize: 10, height: 1.5)),
                ],
                for (final item in _bangumiCandidates) _bangumiCandidate(item),
              ],
              const SizedBox(height: 20),
              const Divider(color: _dialogLine),
              const Text(
                '關聯舊書籍資料',
                style: TextStyle(color: _dialogAccent, fontSize: 10, letterSpacing: 1.6),
              ),
              const SizedBox(height: 6),
              const Text(
                '將舊書籍的閱讀進度、自訂資訊、閱讀統計與既有標註合併至目前檔案。',
                style: TextStyle(color: _dialogMuted, fontSize: 10, height: 1.5),
              ),
              if (_volumes.length > 1) ...[
                const SizedBox(height: 10),
                _label('選擇要接收舊資料的卷冊'),
                DropdownButtonFormField<String>(
                  value: _linkTargetId,
                  items: _volumes
                      .map((volume) => DropdownMenuItem(
                            value: volume.id,
                            child: Text(volume.fileName, overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _linkTargetId = value);
                  },
                ),
              ],
              const SizedBox(height: 9),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _searchingLinks || _linkingOldBook ? null : _findOldBooks,
                  icon: _searchingLinks
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.history, size: 16),
                  label: const Text('搜尋舊書籍資料'),
                ),
              ),
              if (_linkStatus.isNotEmpty) ...[
                const SizedBox(height: 7),
                Text(_linkStatus,
                    style: const TextStyle(color: _dialogMuted, fontSize: 10, height: 1.5)),
              ],
              for (final candidate in _linkCandidates) _oldBookCandidate(candidate),
              if (_saving || _applyingBangumi || _linkingOldBook) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(
                  color: _dialogAccent,
                  backgroundColor: _dialogLine,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _applyingBangumi || _linkingOldBook
              ? null
              : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving || _applyingBangumi || _linkingOldBook ? null : _save,
          child: const Text('保存資訊'),
        ),
      ],
    );
  }

  Widget _bangumiCandidate(Map<String, dynamic> item) {
    final facts = <String>[
      if ((item['name'] ?? '').toString().isNotEmpty &&
          (item['nameCn'] ?? '').toString().isNotEmpty &&
          item['name'] != item['nameCn'])
        item['name'].toString(),
      if ((item['categoryLabel'] ?? '').toString().isNotEmpty)
        item['categoryLabel'].toString(),
      if ((item['date'] ?? '').toString().isNotEmpty) item['date'].toString(),
      if ((item['score'] ?? 0).toString() != '0')
        '評分 ${item['score']}${(item['ratingCount'] ?? 0) == 0 ? '' : ' · ${item['ratingCount']} 人'}',
      if (item['tags'] is List)
        (item['tags'] as List).map((tag) => tag.toString()).join('、'),
      if ((item['summary'] ?? '').toString().isNotEmpty)
        item['summary'].toString(),
    ];
    return _candidateTile(
      title: (item['nameCn'] ?? item['name'] ?? 'Bangumi #${item['id']}').toString(),
      details: facts.join(' · '),
      buttonLabel: '套用',
      busy: _applyingBangumi,
      onPressed: () => _applyBangumi(item),
    );
  }

  Widget _oldBookCandidate(Map<String, dynamic> item) {
    final facts = <String>[
      if ((item['fileName'] ?? '').toString().isNotEmpty) item['fileName'].toString(),
      if ((item['progress'] ?? 0).toString() != '0') '進度 ${item['progress']}%',
      if ((item['readingSeconds'] ?? 0).toString() != '0')
        '累計 ${_formatReadingTime(int.tryParse(item['readingSeconds'].toString()) ?? 0)}',
      if ((item['annotationCount'] ?? 0).toString() != '0')
        '標註 ${item['annotationCount']} 筆',
    ];
    return _candidateTile(
      title: (item['title'] ?? item['fileName'] ?? '未命名舊書籍').toString(),
      details: facts.isEmpty ? '保留有閱讀歷史' : facts.join(' · '),
      buttonLabel: '關聯',
      busy: _linkingOldBook,
      onPressed: () => _linkOldBook(item),
    );
  }

  Widget _candidateTile({
    required String title,
    required String details,
    required String buttonLabel,
    required bool busy,
    required VoidCallback onPressed,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF211C2B),
        border: Border.all(color: _dialogLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _dialogText, fontSize: 10, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(details,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _dialogMuted, fontSize: 9, height: 1.5)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: busy ? null : onPressed,
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

  Widget _label(String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(value,
            style: const TextStyle(color: _dialogMuted, fontSize: 10, fontWeight: FontWeight.w600)),
      );

  Widget _metaRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(label, style: const TextStyle(color: _dialogFaint, fontSize: 9)),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(color: _dialogMuted, fontSize: 9)),
            ),
          ],
        ),
      );

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _formatReadingTime(int seconds) {
    if (seconds <= 0) return '沒有閱讀紀錄';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) return '$hours 小時 $minutes 分鐘';
    if (minutes > 0) return '$minutes 分鐘';
    return '$seconds 秒';
  }
}
