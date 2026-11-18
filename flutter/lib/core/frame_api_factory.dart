import 'frame_api_client.dart';
import 'frame_api_factory_stub.dart'
    if (dart.library.io) 'frame_api_factory_io.dart'
    if (dart.library.js_interop) 'frame_api_factory_web.dart' as platform;

FrameApiClient createFrameApiClient({required Uri baseUri}) =>
    platform.createFrameApiClient(baseUri: baseUri);
