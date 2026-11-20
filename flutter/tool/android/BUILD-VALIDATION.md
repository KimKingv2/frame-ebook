# Android native build validation

This marker intentionally participates in the native build policy. The shared
Dart API client now supports authenticated binary POST requests from the
WebView-backed Android application. Keep the Android Release build in CI for
this cross-platform transport change, even though no Android-specific runtime
configuration is modified.
