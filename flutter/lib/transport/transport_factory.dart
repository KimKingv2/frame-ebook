import 'frame_transport.dart';
import 'transport_factory_stub.dart'
    if (dart.library.io) 'transport_factory_io.dart'
    if (dart.library.js_interop) 'transport_factory_web.dart' as platform;

FrameTransport createFrameTransport() => platform.createFrameTransport();
