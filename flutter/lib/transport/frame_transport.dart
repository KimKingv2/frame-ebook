import 'frame_file_source.dart';
import 'transport_result.dart';

abstract interface class FrameTransport {
  Future<TransportResult> probeRange({
    required Uri uri,
    Map<String, String> headers = const {},
    int start = 0,
    int end = 1023,
    int maxBodyBytes = 4096,
    Duration timeout = const Duration(seconds: 25),
  });

  /// Opens a one-shot streaming response without aggregating the body in memory.
  Future<FrameFileResponse> openStream({
    required Uri uri,
    Map<String, String> headers = const {},
    FrameByteRange? range,
    FrameFileCancellation? cancellation,
    Duration timeout = const Duration(seconds: 120),
  });

  void close();
}
