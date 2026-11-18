package com.kimkingv2.frame_ebook;

import android.content.Context;
import java.util.Map;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.StandardMessageCodec;
import io.flutter.plugin.platform.PlatformView;
import io.flutter.plugin.platform.PlatformViewFactory;

final class FrameEbookNativeReaderFactory extends PlatformViewFactory {
    private final BinaryMessenger messenger;

    FrameEbookNativeReaderFactory(BinaryMessenger messenger) {
        super(StandardMessageCodec.INSTANCE);
        this.messenger = messenger;
    }

    @Override
    public PlatformView create(Context context, int viewId, Object args) {
        String url = "";
        if (args instanceof Map) {
            Object value = ((Map<?, ?>) args).get("url");
            if (value != null) url = value.toString();
        }
        return new FrameEbookNativeReaderView(context, messenger, viewId, url);
    }
}
