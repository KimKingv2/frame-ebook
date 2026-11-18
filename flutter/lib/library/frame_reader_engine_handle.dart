class FrameReaderEngineHandle {
  void Function(String command)? _sender;

  void attach(void Function(String command)? sender) => _sender = sender;

  void send(String command) => _sender?.call(command);
}
