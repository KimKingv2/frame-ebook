import 'dart:typed_data';

abstract interface class FrameApiClient {
  Future<Map<String, dynamic>> getJson(String path);

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  );

  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List body, {
    required String contentType,
    Map<String, String> headers = const {},
  });

  Future<Map<String, dynamic>> deleteJson(
    String path,
    Map<String, dynamic> body,
  );

  Future<Uint8List> getBytes(String path);

  void close();
}

class FrameApiException implements Exception {
  const FrameApiException({
    required this.message,
    this.statusCode,
  });

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
