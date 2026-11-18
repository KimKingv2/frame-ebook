import 'package:material_ui/material_ui.dart';

import '../core/frame_app_config.dart';
import 'frame_book.dart';
import 'frame_reader_engine.dart';

class FrameReaderScreen extends StatefulWidget {
  const FrameReaderScreen({
    required this.book,
    super.key,
  });

  final FrameBook book;

  @override
  State<FrameReaderScreen> createState() => _FrameReaderScreenState();
}

class _FrameReaderScreenState extends State<FrameReaderScreen> {
  final FrameReaderEngineHandle _engine = FrameReaderEngineHandle();

  Uri get _readerUri {
    final descriptor = widget.book.descriptor();
    final query = <String, String>{
      'book': widget.book.id,
      'provider': widget.book.provider,
      'library': widget.book.library,
      'root_path': widget.book.rootPath,
      'path': widget.book.path,
      'embed': 'flutter',
    };
    final profileId = descriptor['profileId']?.toString() ?? '';
    final sourceId = descriptor['sourceId']?.toString() ?? '';
    if (profileId.isNotEmpty) query['profile_id'] = profileId;
    if (sourceId.isNotEmpty) query['source_id'] = sourceId;
    return FrameAppConfig.apiBaseUri.replace(
      path: '/epub-lab/',
      queryParameters: query,
    );
  }

  @override
  Widget build(BuildContext context) {
    final author = widget.book.author.trim();
    return Scaffold(
      backgroundColor: const Color(0xFF12101A),
      appBar: AppBar(
        toolbarHeight: 58,
        backgroundColor: const Color(0xFF171420),
        leading: IconButton(
          tooltip: '返回書架',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        titleSpacing: 0,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.book.title.isEmpty ? widget.book.fileName : widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFF4F0FA),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (author.isNotEmpty)
              Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFAAA2B8),
                  fontSize: 10,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '目錄、筆記與書籤',
            onPressed: () => _engine.send('toggle-sidebar'),
            icon: const Icon(Icons.menu_book_outlined),
          ),
          IconButton(
            tooltip: '閱讀設定',
            onPressed: () => _engine.send('toggle-appearance'),
            icon: const Icon(Icons.text_fields_rounded),
          ),
          IconButton(
            tooltip: '切換目前頁面的書籤',
            onPressed: () => _engine.send('toggle-bookmark'),
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: '更多閱讀功能',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              if (value == 'fullscreen') {
                _engine.send('toggle-fullscreen');
              } else if (value == 'reload') {
                _engine.send('reload');
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'fullscreen',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.fullscreen_rounded),
                  title: Text('全螢幕閱讀'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem<String>(
                value: 'reload',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.refresh_rounded),
                  title: Text('重新載入閱讀室'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: buildFrameReaderEngine(
          uri: _readerUri,
          title: widget.book.title,
          handle: _engine,
        ),
      ),
    );
  }
}
