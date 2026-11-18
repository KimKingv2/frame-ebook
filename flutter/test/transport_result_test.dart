import 'package:flutter_test/flutter_test.dart';
import 'package:frame_ebook/transport/transport_result.dart';

void main() {
  group('TransportResult', () {
    test('distinguishes HTTP 206 from visible response headers', () {
      const result = TransportResult(
        statusCode: 206,
        headers: {},
        bytesRead: 1024,
        bodyTruncated: false,
        duration: Duration(milliseconds: 20),
      );
      expect(result.receivedPartialContent, isTrue);
      expect(result.contentRangeVerified, isFalse);
    });

    test('recognizes a valid Content-Range header', () {
      const result = TransportResult(
        statusCode: 206,
        headers: {'Content-Range': 'bytes 0-1023/8192'},
        bytesRead: 1024,
        bodyTruncated: false,
        duration: Duration(milliseconds: 20),
      );
      expect(result.receivedPartialContent, isTrue);
      expect(result.contentRangeVerified, isTrue);
    });

    test('does not accept HTTP 200 as partial content', () {
      const result = TransportResult(
        statusCode: 200,
        headers: {'Accept-Ranges': 'bytes'},
        bytesRead: 4096,
        bodyTruncated: true,
        duration: Duration(milliseconds: 20),
      );
      expect(result.receivedPartialContent, isFalse);
    });
  });
}
