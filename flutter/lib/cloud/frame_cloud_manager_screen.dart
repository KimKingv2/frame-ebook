import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../core/frame_api_client.dart';
import '../core/frame_api_scope.dart';
import '../core/frame_app_config.dart';
import '../legacy/frame_legacy_page.dart';
import '../library/frame_library_repository.dart';
import 'frame_cloud_models.dart';
import 'frame_cloud_repository.dart';
import 'local_openlist_client.dart';
import 'local_openlist_settings_store.dart';

const _bg=Color(0xFF12101A), _panel=Color(0xFF1B1825), _soft=Color(0xFF211C2B);
const _line=Color(0xFF393247), _text=Color(0xFFF4F0FA), _muted=Color(0xFFAAA2B8);
const _faint=Color(0xFF827A91), _accent=Color(0xFFC5ADFF);

class FrameCloudManagerScreen extends StatefulWidget {
  const FrameCloudManagerScreen({super.key});
  @override
  State<FrameCloudManagerScreen> createState()=>_FrameCloudManagerScreenState();
}

class _FrameCloudManagerScreenState extends State<FrameCloudManagerScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final FrameCloudRepository _cloud;
  late final FrameLibraryRepository _library;
  late final LocalOpenListSettingsStore _settings;
  final _url=TextEditingController(), _user=TextEditingController(), _password=TextEditingController();
  final _books=TextEditingController(text:FrameCloudDefaults.booksRoot), _comics=TextEditingController(text:FrameCloudDefaults.comicsRoot);
  final _search=TextEditingController();
  FrameCloudSession? _session;
  FrameCloudProvider _provider=FrameCloudProvider.vps;
  FrameCloudLibrary _libraryType=FrameCloudLibrary.books;
  LocalOpenListClient? _local;
  FrameCloudDirectoryPage? _directory;
  List<FrameCloudEntry> _localEntries=[];
  FrameCloudScanState? _booksScan, _comicsScan;
  String _path=FrameCloudDefaults.booksRoot, _status='正在讀取設定……', _listingStatus='';
  String? _error;
  int _page=1, _localTotal=0;
  bool _started=false, _loading=true, _busy=false, _loggingIn=false, _saving=false, _listing=false;

  @override
  void initState(){super.initState();_tabs=TabController(length:2,vsync:this);}
  @override
  void didChangeDependencies(){
    super.didChangeDependencies();
    if(_started)return;
    _started=true;
    final api=FrameApiScope.of(context);
    _cloud=FrameCloudRepository(api);
    _library=FrameLibraryRepository(api);
    _settings=LocalOpenListSettingsStore();
    unawaited(_init());
  }
  @override
  void dispose(){
    _tabs.dispose();_url.dispose();_user.dispose();_password.dispose();_books.dispose();_comics.dispose();_search.dispose();_local?.close();super.dispose();
  }

  bool get _isLocal=>_provider==FrameCloudProvider.local;
  bool get _localReady=>_local?.isAuthenticated==true;
  String get _root=>normalizeFrameCloudPath(_libraryType==FrameCloudLibrary.books?_books.text:_comics.text)??'/';
  int get _total=>_isLocal?_localTotal:(_directory?.total??0);
  int get _perPage=>_isLocal?100:(_directory?.perPage??80);
  int get _pages=>_total==0?1:(_total+_perPage-1)~/_perPage;
  List<FrameCloudEntry> get _items=>_isLocal?_localEntries:(_directory?.items??const []);
  List<FrameCloudEntry> get _visible{
    final q=_search.text.trim().toLowerCase();
    return q.isEmpty?_items:_items.where((x)=>x.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _init() async {
    try{
      final r=await Future.wait([_cloud.loadSession(),_cloud.loadPreferences(),_settings.loadBaseUrl()]);
      final session=r[0] as FrameCloudSession, prefs=r[1] as FrameCloudPreferences, saved=r[2] as String?;
      if(!mounted)return;
      setState((){
        _session=session;_provider=prefs.activeProvider;_libraryType=prefs.activeLibrary;
        _books.text=prefs.rootFor(FrameCloudLibrary.books,session:session);
        _comics.text=prefs.rootFor(FrameCloudLibrary.comics,session:session);
        if(saved!=null)_url.text=saved;
        _path=_root;_loading=false;_status='Cloudflare Access 已通過。';
      });
      await _refreshScan();
      await _loadDirectory();
    }catch(e){
      if(mounted)setState(()=>_loading=false);
      _setStatus('讀取雲端設定失敗：'+e.toString(),error:true);
    }
  }
  void _setStatus(String v,{bool error=false}){if(!mounted)return;setState(() { _status = v; _error = error ? v : null; });}

  Future<void> _selectProvider(FrameCloudProvider p) async {
    setState(() { _provider = p; _path = _root; _page = 1; });
    if(p.isServerSide){try{await _cloud.saveActiveProvider(p);}catch(e){_setStatus('保存來源失敗：'+e.toString(),error:true);}}
    await _loadDirectory();
  }
  Future<void> _selectLibrary(FrameCloudLibrary v) async {
    setState(()=>{_libraryType=v,_path=v==FrameCloudLibrary.books?_books.text:_comics.text,_page=1});
    try{await _cloud.saveActiveLibrary(v);}catch(_){}
    await _loadDirectory();
  }
  Future<void> _login() async {
    if(_loggingIn)return;
    setState(()=>_loggingIn=true);
    LocalOpenListClient? pending;
    try{
      final base=LocalOpenListClient.normalizeLocalOpenListUrl(_url.text);
      pending=LocalOpenListClient(baseUrl:base);
      await pending.login(username:_user.text,password:_password.text);
      await _settings.saveBaseUrl(base);
      _local?.close();_local=pending;pending=null;_password.clear();
      await _selectProvider(FrameCloudProvider.local);
      _setStatus('本地 OpenList 已登入。密碼與短效 Token 僅存在記憶體。');
    }catch(e){pending?.close();_setStatus('登入失敗：'+e.toString(),error:true);}
    finally{if(mounted)setState(()=>_loggingIn=false);}
  }
  Future<void> _logout() async {
    _local?.close();_local=null;_password.clear();
    await _loadDirectory();
    _setStatus('本地 OpenList 已登出，Token 已從記憶體清除。');
  }
  Future<void> _saveRoots() async {
    if(_saving)return;
    setState(()=>_saving=true);
    try{
      final b=normalizeFrameCloudPath(_books.text),c=normalizeFrameCloudPath(_comics.text);
      if(b==null||c==null)throw const FormatException('兩條根目錄必須是有效絕對路徑，且不可包含 . 或 ..。');
      await _cloud.saveSharedRoots(booksRoot:b,comicsRoot:c);
      _books.text=b;_comics.text=c;_path=_root;
      await _loadDirectory();
      _setStatus('電子書與漫畫根目錄已保存至 D1，三個伺服器來源共用相同路徑。');
    }catch(e){_setStatus('保存根目錄失敗：'+e.toString(),error:true);}
    finally{if(mounted)setState(()=>_saving=false);}
  }
  Future<void> _test() async {
    if(_busy)return;
    setState(()=>_busy=true);
    try{
      if(_isLocal){
        if(!_localReady)throw const LocalOpenListException('請先登入本地 OpenList。');
        final d=await _local!.listDirectory(_root);
        _setStatus('本地 OpenList 連線成功，共 '+d.total.toString()+' 個項目。');
      }else{
        if(_session?.providers[_provider]?.configured!=true)throw FrameApiException(message:_provider.label+' 尚未設定 Pages Variable／Secret。');
        final d=await _cloud.loadIndexedDirectory(provider:_provider,library:_libraryType,rootPath:_root,path:_root);
        _setStatus('D1 索引 API 可用，共 '+d.total.toString()+' 個項目。');
        await _loadDirectory();
      }
    }catch(e){_setStatus('連線測試失敗：'+e.toString(),error:true);}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _refreshScan() async {
    final p=_provider.isServerSide?_provider:FrameCloudProvider.vps;
    try{
      final r=await Future.wait([
        _cloud.loadScanState(provider:p,library:FrameCloudLibrary.books,rootPath:_books.text),
        _cloud.loadScanState(provider:p,library:FrameCloudLibrary.comics,rootPath:_comics.text),
      ]);
      if (mounted) setState(() { _booksScan = r[0]; _comicsScan = r[1]; });
    }catch(_){}
  }
  Future<void> _loadDirectory() async {
    if(_listing||_loading)return;
    if(!frameCloudPathIsWithinRoot(_path,_root))_path=_root;
    setState(()=>_listing=true);
    try{
      if(_isLocal&&_localReady){
        final d=await _local!.listDirectory(_path,page:_page);
        _localTotal=d.total;_directory=null;
        _localEntries=d.items.map((x){
          final ext=x.name.split('.').last.toLowerCase();
          final fmt=x.isDirectory?'':ext=='epub'?'EPUB':ext=='cbz'?'CBZ':'';
          return FrameCloudEntry(name:x.name,path:x.path,parentPath:x.parentPath,isDirectory:x.isDirectory,format:fmt,size:x.size,modified:x.modified,coverHash:null,coverType:null,coverStatus:'pending',coverError:null);
        }).where((x)=>x.isDirectory||(_libraryType==FrameCloudLibrary.books?x.format=='EPUB':x.format=='EPUB'||x.format=='CBZ')).toList();
        _listingStatus='本地 OpenList 即時目錄，共 '+d.total.toString()+' 個項目。';
      }else{
        _directory=await _cloud.loadIndexedDirectory(provider:_provider,library:_libraryType,rootPath:_root,path:_path,page:_page);
        _localEntries=[];_localTotal=_directory!.total;
        _listingStatus=_directory!.indexed?'D1 索引已載入，共 '+_directory!.total.toString()+' 個項目。':'尚未建立索引，請先執行掃描。';
      }
      _error=null;
    }catch(e){_listingStatus='讀取目錄失敗：'+e.toString();_error=e.toString();}
    finally{if(mounted)setState(()=>_listing=false);}
  }
  Future<void> _navigate(String p) async {
    final n=normalizeFrameCloudPath(p);
    if(n==null||!frameCloudPathIsWithinRoot(n,_root))return;
    setState(() { _path = n; _page = 1; _search.clear(); });
    await _loadDirectory();
  }
  Future<void> _up() async {
    if(_path==_root)return;
    final parts=_path.split('/').where((x)=>x.isNotEmpty).toList();
    if(parts.isNotEmpty)parts.removeLast();
    final parent=parts.isEmpty?'/':'/'+parts.join('/');
    await _navigate(parent.length<_root.length?_root:parent);
  }
  void _setRoot(FrameCloudLibrary kind){
    if(kind==FrameCloudLibrary.books){_books.text=_path;}else{_comics.text=_path;}
    setState(()=>_status='已將目前路徑填入根目錄，請保存。');
  }
  void _legacy(String path,String title,[Map<String,String> query=const {}]){
    final uri=FrameAppConfig.apiBaseUri.replace(path:path,queryParameters:query.isEmpty?null:query);
    Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>buildFrameLegacyPage(uri:uri,title:title)));
  }
  void _scan(){unawaited(_cloud.saveActiveLibrary(_libraryType));_legacy('/cloud/','main 原版完整掃描與封面索引',const {'manager':'1'});}
  Future<void> _open(FrameCloudEntry x) async {
    if(x.isDirectory)return _navigate(x.path);
    if(_isLocal){_legacy('/cloud/','本地 OpenList 書庫',const {'manager':'1'});return;}
    try{
      final list=await _library.loadBookshelf();
      final found=list.where((b)=>b.provider==_provider.apiValue&&b.library==_libraryType.apiValue&&b.rootPath==_root&&b.path==x.path);
      if(found.isEmpty)throw const FrameApiException(message:'檔案尚未加入書架索引，請先完成掃描。');
      final b=found.first;
      _legacy('/epub-lab/',b.title.isEmpty?b.fileName:b.title,{'book':b.id,'provider':b.provider,'library':b.library,'root_path':b.rootPath,'path':b.path});
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('開啟失敗：'+e.toString())));}
  }

  @override
  Widget build(BuildContext context)=>Scaffold(
    backgroundColor:_bg,
    appBar:AppBar(
      backgroundColor:_bg,
      title:const Text('FRAME  READER',style:TextStyle(color:_accent,letterSpacing:2)),
      actions:[IconButton(onPressed:_loading?null:_init,icon:const Icon(Icons.refresh))],
      bottom:TabBar(controller:_tabs,indicatorColor:_accent,labelColor:_accent,unselectedLabelColor:_muted,tabs:const [Tab(text:'連接與掃描'),Tab(text:'雲端書庫')]),
    ),
    body:_loading?const Center(child:CircularProgressIndicator(color:_accent)):TabBarView(controller:_tabs,children:[_connectionTab(),_libraryTab()]),
  );

  Widget _connectionTab()=>ListView(padding:const EdgeInsets.all(18),children:[
    _heading('CONNECTION PROFILES','書庫連線設定','四種來源共用一組書庫根目錄與現有 D1 索引。'),
    const SizedBox(height:12),
    _panel(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const _Label('候選書庫來源'),
      DropdownButtonFormField<FrameCloudProvider>(
        initialValue:_provider,
        items:FrameCloudProvider.values.map((p)=>DropdownMenuItem(value:p,child:Text(p.label))).toList(),
        onChanged:(p){if(p!=null)_selectProvider(p);},
      ),
      for(final p in FrameCloudProvider.values)_providerTile(p),
      if(_isLocal)...[
        const Divider(color:_line,height:22),
        const _Label('本地 OpenList 網址'),
        TextField(controller:_url,keyboardType:TextInputType.url,autocorrect:false,decoration:const InputDecoration(hintText:'http://192.168.31.185:5244')),
        const SizedBox(height:8),const _Label('帳號'),
        TextField(controller:_user,autocorrect:false,decoration:const InputDecoration(hintText:'OpenList 帳號')),
        const SizedBox(height:8),const _Label('密碼'),
        TextField(controller:_password,obscureText:true,autocorrect:false,decoration:const InputDecoration(hintText:'只在登入時使用，不保存')),
        Wrap(spacing:8,children:[
          FilledButton(onPressed:_loggingIn?null:_login,child:Text(_loggingIn?'登入中……':'登入本地 OpenList')),
          OutlinedButton(onPressed:_localReady?_logout:null,child:const Text('登出並清除 Token')),
        ]),
        const Text('只保存網址，不保存帳密和 Token。HTTP 僅允許 localhost／私有 IPv4。',style:TextStyle(color:_faint,fontSize:10)),
      ],
      const Divider(color:_line,height:22),
      const _Label('電子書根目錄（EPUB）'),
      TextField(controller:_books,autocorrect:false),
      TextButton(onPressed:()=>_setRoot(FrameCloudLibrary.books),child:const Text('將目前位置設為電子書根目錄')),
      const SizedBox(height:6),const _Label('漫畫根目錄（EPUB／CBZ）'),
      TextField(controller:_comics,autocorrect:false),
      TextButton(onPressed:()=>_setRoot(FrameCloudLibrary.comics),child:const Text('將目前位置設為漫畫根目錄')),
      Wrap(spacing:8,children:[
        FilledButton(onPressed:_saving?null:_saveRoots,child:Text(_saving?'保存中……':'保存兩條根目錄')),
        OutlinedButton(onPressed:_busy?null:_test,child:Text(_busy?'測試中……':'測試連線')),
      ]),
      _statusBox(_status,error:_error!=null),
    ])),
    const SizedBox(height:20),
    _heading('PERSISTENT CLOUD INDEX','書庫掃描與索引','完整遞迴掃描、續掃、metadata、封面擷取暫由 main 原版引擎承接。'),
    const SizedBox(height:12),
    _panel(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      _scanLine('電子書',_booksScan),const Divider(color:_line,height:18),_scanLine('漫畫',_comicsScan),
      const SizedBox(height:10),FilledButton.icon(onPressed:_scan,icon:const Icon(Icons.play_arrow),label:const Text('開啟完整掃描／續掃面板')),
      const Text('Flutter 遞迴掃描器尚在移植，此入口保留 main 的暫停／續掃、日誌、metadata 與封面重試。',style:TextStyle(color:_faint,fontSize:10)),
    ])),
  ]);

  Widget _libraryTab(){
    final crumbs=_path.split('/').where((p)=>p.isNotEmpty).toList();
    final q=_search.text.trim().toLowerCase();
    final entries=q.isEmpty?_items:_items.where((x)=>x.name.toLowerCase().contains(q)).toList();
    return ListView(padding:const EdgeInsets.all(18),children:[
      _heading('CLOUD BOOK INDEX','雲端書庫','瀏覽 D1 索引或本地 OpenList 即時目錄。'),
      const SizedBox(height:12),
      _panel(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        const _Label('書庫分類'),
        DropdownButtonFormField<FrameCloudLibrary>(
          initialValue:_libraryType,
          items:FrameCloudLibrary.values.map((x)=>DropdownMenuItem(value:x,child:Text(x.label))).toList(),
          onChanged:(x){if(x!=null)_selectLibrary(x);},
        ),
        Row(children:[
          IconButton(onPressed:()=>_navigate(_root),icon:const Icon(Icons.home_outlined)),
          IconButton(onPressed:_path==_root?null:_up,icon:const Icon(Icons.arrow_upward)),
          Expanded(child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:[
            TextButton(onPressed:()=>_navigate(_root),child:Text(_root)),
            for(var i=0;i<crumbs.length;i++)...[
              const Icon(Icons.chevron_right,color:_faint,size:14),
              TextButton(onPressed:()=>_navigate('/'+crumbs.take(i+1).join('/')),child:Text(crumbs[i])),
            ],
          ]))),
          IconButton(onPressed:_listing?null:_loadDirectory,icon:const Icon(Icons.refresh)),
        ]),
        TextField(controller:_search,onChanged:(_)=>setState((){}),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'搜尋目前資料夾')),
        Text(_listingStatus,style:const TextStyle(color:_muted,fontSize:10)),
        if(_listing)const LinearProgressIndicator(color:_accent),
        if(_error!=null)_statusBox(_error!,error:true),
        for(final x in entries)_entryTile(x),
        const Divider(color:_line,height:18),
        Row(mainAxisAlignment:MainAxisAlignment.center,children:[
          OutlinedButton(onPressed:_page<=1||_listing?null:(){setState(()=>_page--);_loadDirectory();},child:const Text('上一頁')),
          const SizedBox(width:10),Text('第 '+_page.toString()+' / '+_pages.toString()+' 頁',style:const TextStyle(color:_muted,fontSize:10)),const SizedBox(width:10),
          OutlinedButton(onPressed:_page>=_pages||_listing?null:(){setState(()=>_page++);_loadDirectory();},child:const Text('下一頁')),
        ]),
      ])),
    ]);
  }

  List<FrameCloudEntry> get _items=>_isLocal?_localEntries:(_directory?.items??const []);
  Widget _entryTile(FrameCloudEntry x){
    final dir=x.isDirectory, icon=dir?Icons.folder_outlined:x.format=='CBZ'?Icons.auto_stories_outlined:Icons.menu_book_outlined;
    return Container(margin:const EdgeInsets.only(top:6),decoration:BoxDecoration(color:_soft,border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),
      child:ListTile(dense:true,leading:Icon(icon,color:dir?_accent:_muted),title:Text(x.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:_text,fontSize:11)),subtitle:Text(dir?'資料夾':x.format+' · '+_bytes(x.size),style:const TextStyle(color:_faint,fontSize:9)),trailing:Icon(dir?Icons.chevron_right:Icons.open_in_new,color:_faint,size:16),onTap:()=>_open(x)));
  }
  Widget _providerTile(FrameCloudProvider p){
    final selected=p==_provider, ready=p==FrameCloudProvider.local?_localReady:_session?.providers[p]?.configured==true;
    final note=p==FrameCloudProvider.local?(_localReady?'已登入，本機 Token 有效':'裝置直連，需手動登入'):(ready?'Cloudflare Pages 已設定':'尚未設定 Pages Variable／Secret');
    return Container(margin:const EdgeInsets.only(top:6),padding:const EdgeInsets.symmetric(horizontal:10,vertical:8),decoration:BoxDecoration(color:selected?const Color(0x332F2444):_soft,border:Border.all(color:_line),borderRadius:BorderRadius.circular(8)),
      child:Row(children:[Icon(ready?Icons.check_circle:Icons.circle_outlined,color:ready?const Color(0xFF8BD8B1):_faint,size:16),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(p.label,style:const TextStyle(color:_text,fontSize:11)),Text(note,style:const TextStyle(color:_muted,fontSize:9))])),if(selected)const Text('目前選取',style:TextStyle(color:_accent,fontSize:9))else TextButton(onPressed:()=>_selectProvider(p),child:const Text('選用'))]));
  }
  Widget _scanLine(String title,FrameCloudScanState? s){
    final state=s==null?'尚未掃描':s.completed?'已完成':s.pausedByUser?'已暫停，可續掃':'有待續進度';
    final detail=s==null?'尚未建立 D1 掃描進度':'資料夾 '+s.visitedFolderCount.toString()+' · 掃描 '+s.scannedCount.toString()+' · 寫入 '+s.indexedCount.toString()+' · 失敗 '+s.failedCount.toString()+'\n待續 '+s.pendingFolders.length.toString()+' · 封面完成 '+s.coverReadyCount.toString()+' · 封面失敗 '+s.coverFailedCount.toString();
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Expanded(child:Text(title,style:const TextStyle(color:_text,fontSize:11))),Text(state,style:const TextStyle(color:_accent,fontSize:9))]),const SizedBox(height:5),Text(detail,style:const TextStyle(color:_muted,fontSize:10,height:1.5))]);
  }
  Widget _heading(String kicker,String title,String desc)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(kicker,style:const TextStyle(color:Color(0xFF8F7BB7),fontSize:8,letterSpacing:2)),const SizedBox(height:7),Text(title,style:const TextStyle(color:_text,fontSize:23,fontWeight:FontWeight.w600)),const SizedBox(height:5),Text(desc,style:const TextStyle(color:_muted,fontSize:10,height:1.5))]);
  Widget _panel(Widget child)=>Container(padding:const EdgeInsets.all(15),decoration:BoxDecoration(color:_panel,border:Border.all(color:_line),borderRadius:BorderRadius.circular(12)),child:child);
  Widget _statusBox(String text,{bool error=false})=>Container(margin:const EdgeInsets.only(top:9),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:error?const Color(0x332D191E):const Color(0x33291F3A),border:Border.all(color:error?const Color(0x77A75C68):const Color(0x667A64AC)),borderRadius:BorderRadius.circular(8)),child:Text(text,style:TextStyle(color:error?const Color(0xFFFFA5A5):_muted,fontSize:10,height:1.5)));
  String _bytes(int b)=>b<1048576?(b/1024).round().toString()+' KB':b<1073741824?(b/1048576).toStringAsFixed(1)+' MB':(b/1073741824).toStringAsFixed(2)+' GB';
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.only(bottom:6),child:Text(text,style:const TextStyle(color:Color(0xFFD4CDE1),fontSize:10,fontWeight:FontWeight.w600)));
}
