import 'package:material_ui/material_ui.dart';

import 'frame_book.dart';
import 'frame_library_repository.dart';

const _bg = Color(0xFF12101A);
const _panel = Color(0xFF1B1825);
const _raised = Color(0xFF211D2D);
const _ink = Color(0xFFF4F0FA);
const _muted = Color(0xFFAAA2B8);
const _faint = Color(0xFF81788F);
const _accent = Color(0xFFC5ADFF);
const _line = Color(0x55393247);

class FrameBookDetailsScreen extends StatefulWidget {
  const FrameBookDetailsScreen({
    required this.book,
    required this.cover,
    required this.relatedBooks,
    required this.repository,
    required this.onBack,
    required this.onRead,
    required this.onBookChanged,
    super.key,
  });

  final FrameBook book;
  final Widget cover;
  final List<FrameBook> relatedBooks;
  final FrameLibraryRepository repository;
  final VoidCallback onBack;
  final VoidCallback onRead;
  final Future<void> Function(String bookId) onBookChanged;

  @override
  State<FrameBookDetailsScreen> createState() => _FrameBookDetailsScreenState();
}

class _FrameBookDetailsScreenState extends State<FrameBookDetailsScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _authorController;
  late final TextEditingController _bangumiController;
  String _shelf = 'books';
  String? _selectedLinkTargetId;
  String _status = '';
  String _bangumiStatus = '';
  String _legacyStatus = '';
  List<Map<String, dynamic>> _bangumiResults = const [];
  List<Map<String, dynamic>> _legacyCandidates = const [];
  bool _saving = false;
  bool _searchingBangumi = false;
  bool _applyingBangumi = false;
  bool _searchingLegacy = false;
  String? _linkingOldBookId;

  FrameBook get _linkTarget {
    final id = _selectedLinkTargetId;
    for (final book in widget.relatedBooks) {
      if (book.id == id) return book;
    }
    return widget.book;
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _authorController = TextEditingController();
    _bangumiController = TextEditingController();
    _syncFromBook();
  }

  @override
  void didUpdateWidget(covariant FrameBookDetailsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.book, widget.book)) _syncFromBook();
  }

  void _syncFromBook() {
    final book = widget.book;
    _titleController.text = book.title.isNotEmpty ? book.title : book.fileName;
    _authorController.text = book.author;
    _shelf = book.shelf == 'comics' || book.library == 'comics'
        ? 'comics'
        : 'books';
    _bangumiController.text = book.comicMetadata['nameCn']?.toString() ??
        book.comicMetadata['name']?.toString() ??
        book.folderTitle;
    _selectedLinkTargetId = book.id;
    _bangumiResults = const [];
    _legacyCandidates = const [];
    _bangumiStatus = '';
    _legacyStatus = '';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _authorController.dispose();
    _bangumiController.dispose();
    super.dispose();
  }

  Future<void> _saveMetadata() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _status = '作品名稱不可留空。');
      return;
    }
    setState(() {
      _saving = true;
      _status = '正在保存作品資訊……';
    });
    try {
      await widget.repository.updateMetadata(
        book: widget.book,
        title: title,
        author: _authorController.text.trim(),
        shelf: _shelf,
      );
      await widget.onBookChanged(widget.book.id);
      if (mounted) setState(() => _status = '作品資訊已保存。');
    } catch (error) {
      if (mounted) setState(() => _status = '保存失敗：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restoreOpfMetadata() async {
    setState(() {
      _saving = true;
      _status = '正在恢復 EPUB 內部書名與作者……';
    });
    try {
      await widget.repository.resetOpfMetadata(widget.book);
      await widget.onBookChanged(widget.book.id);
      if (mounted) setState(() => _status = '已恢復使用 EPUB 內部書名與作者。');
    } catch (error) {
      if (mounted) setState(() => _status = '恢復失敗：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _searchBangumi() async {
    final keyword = _bangumiController.text.trim();
    if (keyword.isEmpty) {
      setState(() => _bangumiStatus = '請先輸入漫畫名稱。');
      return;
    }
    setState(() {
      _searchingBangumi = true;
      _bangumiStatus = '正在搜尋 Bangumi 漫畫資料……';
      _bangumiResults = const [];
    });
    try {
      final items = await widget.repository.searchBangumi(keyword);
      if (!mounted) return;
      setState(() {
        _bangumiResults = items;
        _bangumiStatus = items.isEmpty
            ? '沒有找到候選作品。可以試試日文原名或其他常用名稱。'
            : '找到 ${items.length} 個候選條目，請核對作品名稱、日期與標籤。';
      });
    } catch (error) {
      if (mounted) setState(() => _bangumiStatus = '搜尋失敗：$error');
    } finally {
      if (mounted) setState(() => _searchingBangumi = false);
    }
  }

  Future<void> _applyBangumi(Map<String, dynamic> item) async {
    final subjectId = int.tryParse(item['id']?.toString() ?? '') ?? 0;
    if (subjectId <= 0) return;
    setState(() {
      _applyingBangumi = true;
      _bangumiStatus = '正在取得完整資料並套用到同資料夾卷冊……';
    });
    try {
      final result = await widget.repository.linkBangumi(widget.book, subjectId);
      await widget.onBookChanged(widget.book.id);
      final subject = result['subject'];
      final name = subject is Map
          ? (subject['nameCn'] ?? subject['name'] ?? 'Bangumi 作品').toString()
          : 'Bangumi 作品';
      final count = int.tryParse(result['linkedBooks']?.toString() ?? '') ?? 0;
      if (mounted) {
        setState(() => _bangumiStatus = '已關聯 $name，共套用至 $count 個卷冊。');
      }
    } catch (error) {
      if (mounted) setState(() => _bangumiStatus = '套用失敗：$error');
    } finally {
      if (mounted) setState(() => _applyingBangumi = false);
    }
  }

  Future<void> _searchLegacyData() async {
    setState(() {
      _searchingLegacy = true;
      _legacyStatus = '正在搜尋可關聯的舊書籍資料……';
      _legacyCandidates = const [];
    });
    try {
      final candidates =
          await widget.repository.loadLegacyLinkCandidates(_linkTarget);
      if (!mounted) return;
      setState(() {
        _legacyCandidates = candidates;
        _legacyStatus = candidates.isEmpty
            ? '目前沒有可關聯的舊書籍資料。'
            : '找到 ${candidates.length} 筆舊資料，請核對閱讀紀錄後再關聯。';
      });
    } catch (error) {
      if (mounted) setState(() => _legacyStatus = '搜尋失敗：$error');
    } finally {
      if (mounted) setState(() => _searchingLegacy = false);
    }
  }

  Future<void> _linkLegacyData(Map<String, dynamic> candidate) async {
    final oldBookId = candidate['bookId']?.toString() ?? '';
    if (oldBookId.isEmpty) return;
    final oldTitle = candidate['title']?.toString() ??
        candidate['fileName']?.toString() ??
        '舊書籍';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('確認關聯舊資料', style: TextStyle(color: _ink)),
        content: Text(
          '確定將「$oldTitle」的舊閱讀資料關聯到「${_linkTarget.fileName}」嗎？\n\n'
          '閱讀進度、自訂資訊、閱讀統計，以及資料庫中已有的標註都會合併。這項操作完成後不提供自動還原。',
          style: const TextStyle(color: _muted, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('確認關聯'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _linkingOldBookId = oldBookId;
      _legacyStatus = '正在合併舊書籍資料……';
    });
    try {
      final result =
          await widget.repository.linkLegacyBook(_linkTarget, oldBookId);
      final moved = result['moved'] is Map
          ? Map<String, dynamic>.from(result['moved'] as Map)
          : <String, dynamic>{};
      await widget.onBookChanged(widget.book.id);
      final summary = [
        '閱讀狀態 ${moved['readingState'] == 1 || moved['readingState'] == true ? '已合併' : '無'}',
        '閱讀事件 ${moved['readingEvents'] ?? 0} 筆',
        '標註 ${moved['annotations'] ?? 0} 筆',
      ].join(' · ');
      final note = result['note']?.toString() ?? '';
      if (mounted) {
        setState(() => _legacyStatus =
            '關聯完成。$summary${note.isNotEmpty ? ' $note' : ''}');
      }
    } catch (error) {
      if (mounted) setState(() => _legacyStatus = '關聯失敗：$error');
    } finally {
      if (mounted) setState(() => _linkingOldBookId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final comic = book.isComic;
    final basic = <Widget>[
      _info('格式', _orFallback(book.format)),
      _info('檔案名稱', _orFallback(book.fileName)),
      _info('檔案大小', _formatBytes(book.size)),
      _info(
        comic ? '頁數' : '內容項目',
        book.pageCount > 0
            ? book.pageCount.toString() + (comic ? ' 頁' : ' 項')
            : '未提供',
      ),
      _info('加入日期', _formatDate(book.addedAt)),
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

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回書架',
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          comic ? '漫畫資訊' : '電子書資訊',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        backgroundColor: _bg,
        foregroundColor: _ink,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '開啟閱讀',
            onPressed: widget.onRead,
            icon: const Icon(Icons.menu_book_rounded),
          ),
        ],
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 112,
                        child: AspectRatio(
                          aspectRatio: comic ? 2 / 3 : 3 / 4,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: ColoredBox(
                              color: _raised,
                              child: widget.cover,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              comic ? 'COMIC DETAILS' : 'EBOOK DETAILS',
                              style: const TextStyle(
                                color: _accent,
                                fontSize: 9,
                                letterSpacing: 1.4,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _editField(
                              controller: _titleController,
                              label: '作品名稱',
                              maxLength: 240,
                            ),
                            const SizedBox(height: 9),
                            _editField(
                              controller: _authorController,
                              label: '作者',
                              maxLength: 240,
                            ),
                            const SizedBox(height: 8),
                            if (book.format == 'CBZ')
                              const Text(
                                'CBZ 圖像封存固定放在漫畫書架。',
                                style: TextStyle(color: _faint, fontSize: 10),
                              )
                            else
                              DropdownButton<String>(
                                value: _shelf,
                                isExpanded: true,
                                dropdownColor: _raised,
                                underline: const SizedBox.shrink(),
                                style: const TextStyle(color: _muted, fontSize: 12),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'books',
                                    child: Text('收藏分類：電子書'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'comics',
                                    child: Text('收藏分類：漫畫'),
                                  ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          setState(() => _shelf = value);
                                        }
                                      },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _saveMetadata,
                        icon: const Icon(Icons.save_outlined, size: 16),
                        label: const Text('儲存資訊'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    OutlinedButton.icon(
                      onPressed: _saving ? null : widget.onRead,
                      icon: const Icon(Icons.menu_book_outlined, size: 16),
                      label: const Text('開啟閱讀'),
                    ),
                  ],
                ),
                if (_status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _statusText(_status),
                ],
                const SizedBox(height: 14),
                _section('檔案與閱讀資訊', basic),
                if (metadata.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _section(
                    '作品元資料',
                    metadata,
                    trailing: !comic && (book.manualTitle || book.manualAuthor)
                        ? TextButton(
                            onPressed: _saving ? null : _restoreOpfMetadata,
                            child: const Text('恢復 EPUB 內部資訊'),
                          )
                        : null,
                  ),
                ] else if (!comic) ...[
                  const SizedBox(height: 14),
                  _section(
                    '作品元資料',
                    const [
                      Text(
                        '目前沒有額外的出版或作品描述資料。若 EPUB 內含 OPF 中繼資料，掃描索引後會顯示在這裡。',
                        style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
                      ),
                    ],
                    trailing: !comic && (book.manualTitle || book.manualAuthor)
                        ? TextButton(
                            onPressed: _saving ? null : _restoreOpfMetadata,
                            child: const Text('恢復 EPUB 內部資訊'),
                          )
                        : null,
                  ),
                ],
                if (comic) ...[
                  const SizedBox(height: 14),
                  _bangumiSection(book),
                ],
                if (widget.relatedBooks.length > 1) ...[
                  const SizedBox(height: 14),
                  _volumesSection(),
                ],
                const SizedBox(height: 14),
                _legacySection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bangumiSection(FrameBook book) {
    final current = book.comicMetadata;
    final tags = _tagNames(current['tags']);
    final currentItems = <Widget>[];
    final currentTitle = current['nameCn']?.toString() ??
        current['name']?.toString() ??
        '';
    if (currentTitle.isNotEmpty) {
      currentItems.add(_info('已關聯作品', currentTitle));
    }
    if (current['name'] != null &&
        current['name'].toString().isNotEmpty &&
        current['name'].toString() != currentTitle) {
      currentItems.add(_info('原始名稱', current['name'].toString()));
    }
    if (current['subjectId'] != null || current['id'] != null) {
      currentItems.add(_info(
        'Bangumi ID',
        (current['subjectId'] ?? current['id']).toString(),
      ));
    }
    if (current['author'] != null) {
      currentItems.add(_info('作者', current['author'].toString()));
    }
    if (current['date'] != null) {
      currentItems.add(_info('發行日期', current['date'].toString()));
    }
    if (current['score'] != null &&
        current['score'].toString() != '0') {
      currentItems.add(_info(
        '評分',
        '${current['score']}${current['ratingCount'] != null ? '（${current['ratingCount']} 人）' : ''}',
      ));
    }
    if (tags.isNotEmpty) currentItems.add(_info('標籤', tags.join('、')));
    if (current['summary'] != null &&
        current['summary'].toString().isNotEmpty) {
      currentItems.add(_info('作品簡介', current['summary'].toString(), multiline: true));
    }

    return _section(
      'Bangumi 漫畫資料',
      [
        if (currentItems.isNotEmpty) ...[
          ...currentItems,
          const Divider(color: _line, height: 20),
        ] else
          const Text(
            '尚未關聯 Bangumi 作品。搜尋名稱後，可將正確條目套用到同資料夾的全部卷冊。',
            style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
          ),
        _editField(
          controller: _bangumiController,
          label: '漫畫名稱、日文原名或別名',
          maxLength: 100,
          onSubmitted: (_) => _searchBangumi(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: _searchingBangumi || _applyingBangumi
                ? null
                : _searchBangumi,
            icon: _searchingBangumi
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : const Icon(Icons.search, size: 16),
            label: const Text('搜尋 Bangumi'),
          ),
        ),
        if (_bangumiStatus.isNotEmpty) _statusText(_bangumiStatus),
        if (_bangumiResults.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final item in _bangumiResults) _bangumiCandidate(item),
        ],
      ],
    );
  }

  Widget _bangumiCandidate(Map<String, dynamic> item) {
    final title = item['nameCn']?.toString().isNotEmpty == true
        ? item['nameCn'].toString()
        : item['name']?.toString() ?? '未命名條目';
    final facts = <String>[];
    final original = item['name']?.toString() ?? '';
    if (original.isNotEmpty && original != title) facts.add(original);
    if (item['date'] != null) facts.add(item['date'].toString());
    if (item['score'] != null && item['score'].toString() != '0') {
      facts.add('評分 ${item['score']}（${item['ratingCount'] ?? 0} 人）');
    }
    final tags = _tagNames(item['tags']);
    if (tags.isNotEmpty) facts.add(tags.join('、'));
    final summary = item['summary']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: _ink, fontSize: 12, fontWeight: FontWeight.w600),
                ),
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    facts.join(' · '),
                    style: const TextStyle(color: _muted, fontSize: 10, height: 1.5),
                  ),
                ],
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    summary,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _faint, fontSize: 10, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _applyingBangumi ? null : () => _applyBangumi(item),
            child: const Text('套用'),
          ),
        ],
      ),
    );
  }

  Widget _volumesSection() {
    final volumes = [...widget.relatedBooks]
      ..sort((a, b) => compareFrameFileNames(a.fileName, b.fileName));
    return _section(
      '同資料夾卷冊（${volumes.length}）',
      [
        for (final volume in volumes)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    volume.fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: volume.id == widget.book.id ? _accent : _muted,
                      fontSize: 10,
                      fontWeight: volume.id == widget.book.id
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                Text(
                  '${volume.format}${volume.progressPercent > 0 ? ' · ${volume.progressPercent}%' : ''}',
                  style: const TextStyle(color: _faint, fontSize: 9),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _legacySection() {
    final targets = widget.relatedBooks;
    return _section(
      '書籍身份管理',
      [
        const Text(
          '若這本書曾經改名，可在這裡接回舊閱讀記憶。系統會先核對舊資料，再合併進度、閱讀統計與已有標註。',
          style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
        ),
        if (targets.length > 1) ...[
          const SizedBox(height: 10),
          DropdownButton<String>(
            value: targets.any((item) => item.id == _selectedLinkTargetId)
                ? _selectedLinkTargetId
                : widget.book.id,
            isExpanded: true,
            dropdownColor: _raised,
            style: const TextStyle(color: _muted, fontSize: 11),
            items: [
              for (final target in targets)
                DropdownMenuItem(
                  value: target.id,
                  child: Text(
                    target.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _searchingLegacy || _linkingOldBookId != null
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _selectedLinkTargetId = value;
                      _legacyCandidates = const [];
                      _legacyStatus = '';
                    });
                  },
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _searchingLegacy || _linkingOldBookId != null
                ? null
                : _searchLegacyData,
            icon: _searchingLegacy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : const Icon(Icons.manage_search, size: 16),
            label: const Text('搜尋可關聯的舊資料'),
          ),
        ),
        if (_legacyStatus.isNotEmpty) _statusText(_legacyStatus),
        if (_legacyCandidates.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final candidate in _legacyCandidates)
            _legacyCandidate(candidate),
        ],
      ],
    );
  }

  Widget _legacyCandidate(Map<String, dynamic> candidate) {
    final title = candidate['title']?.toString().isNotEmpty == true
        ? candidate['title'].toString()
        : candidate['fileName']?.toString() ?? '未命名舊書籍';
    final facts = <String>[];
    final fileName = candidate['fileName']?.toString() ?? '';
    if (fileName.isNotEmpty) facts.add(fileName);
    final progress =
        (num.tryParse(candidate['progress']?.toString() ?? '') ?? 0).round();
    if (progress > 0) facts.add('進度 $progress%');
    final seconds =
        int.tryParse(candidate['readingSeconds']?.toString() ?? '') ?? 0;
    if (seconds > 0) facts.add('累計 ${_formatReadingTime(seconds)}');
    final annotations =
        int.tryParse(candidate['annotationCount']?.toString() ?? '') ?? 0;
    if (annotations > 0) facts.add('標註 $annotations 筆');
    final id = candidate['bookId']?.toString() ?? '';
    final linking = id.isNotEmpty && id == _linkingOldBookId;
    return Container(
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: _ink, fontSize: 11, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  facts.join(' · ').isEmpty ? '保留有閱讀歷史' : facts.join(' · '),
                  style: const TextStyle(color: _muted, fontSize: 10, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _linkingOldBookId != null || _searchingLegacy
                ? null
                : () => _linkLegacyData(candidate),
            child: linking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : const Text('關聯'),
          ),
        ],
      ),
    );
  }

  Widget _section(
    String title,
    List<Widget> children, {
    Widget? trailing,
  }) {
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 11),
          ...children,
        ],
      ),
    );
  }

  Widget _editField({
    required TextEditingController controller,
    required String label,
    required int maxLength,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      maxLength: maxLength,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: _ink, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: _faint, fontSize: 10),
        counterText: '',
        isDense: true,
        filled: true,
        fillColor: _raised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: _line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: _accent),
        ),
      ),
    );
  }

  Widget _info(String label, String value, {bool multiline = false}) {
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

  Widget _statusText(String value) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          value,
          style: const TextStyle(color: _accent, fontSize: 10, height: 1.6),
        ),
      );

  static List<String> _tagNames(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((tag) {
      if (tag is Map) return (tag['name'] ?? tag['label'] ?? '').toString();
      return tag.toString();
    }).where((tag) => tag.isNotEmpty).take(16).toList();
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

  static String _formatDate(int value) {
    if (value <= 0) return '未提供';
    final milliseconds = value < 1000000000000 ? value * 1000 : value;
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static String _formatReadingTime(int seconds) {
    final total = seconds.clamp(0, 1 << 31);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    if (hours > 0) return '$hours 小時 $minutes 分鐘';
    if (minutes > 0) return '$minutes 分鐘';
    return total > 0 ? '$total 秒' : '沒有閱讀紀錄';
  }
}
