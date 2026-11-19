import 'frame_file_source.dart';
import 'frame_file_source_factory_stub.dart'
    if (dart.library.io) 'frame_file_source_factory_io.dart'
    if (dart.library.js_interop) 'frame_file_source_factory_web.dart' as platform;

FrameFileSource createFrameFileSource({required Uri baseUri}) =>
    platform.createFrameFileSource(baseUri: baseUri);
