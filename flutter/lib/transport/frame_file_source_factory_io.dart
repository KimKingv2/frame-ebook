import 'package:webview_flutter/webview_flutter.dart';

import 'frame_cloud_file_source.dart';
import 'frame_file_source.dart';
import 'transport_factory.dart';

FrameFileSource createFrameFileSource({required Uri baseUri}) {
  final cookieManager = WebViewCookieManager();
  return FrameCloudFileSource(
    baseUri: baseUri,
    transport: createFrameTransport(),
    delivery: FrameCloudFileDelivery.nativeRedirect,
    accessCookieProvider: (origin) async {
      final cookies = await cookieManager.getCookies(domain: origin);
      return cookies
          .where((cookie) => cookie.name.isNotEmpty)
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    },
  );
}
