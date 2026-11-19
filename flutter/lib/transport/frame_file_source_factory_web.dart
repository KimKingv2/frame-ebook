import 'frame_cloud_file_source.dart';
import 'frame_file_source.dart';
import 'transport_factory.dart';

FrameFileSource createFrameFileSource({required Uri baseUri}) =>
    FrameCloudFileSource(
      baseUri: baseUri,
      transport: createFrameTransport(),
      delivery: FrameCloudFileDelivery.sameOriginStream,
    );
