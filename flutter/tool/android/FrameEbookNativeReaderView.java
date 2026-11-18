package com.kimkingv2.frame_ebook;

import android.content.Context;
import android.graphics.Color;
import android.net.Uri;
import android.view.View;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.platform.PlatformView;

final class FrameEbookNativeReaderView implements PlatformView {
    private final WebView webView;
    private final MethodChannel channel;
    private final FrameEbookDirectTransport directTransport;

    FrameEbookNativeReaderView(
            Context context,
            BinaryMessenger messenger,
            int viewId,
            String initialUrl) {
        channel = new MethodChannel(messenger, "frame_ebook/native_reader/" + viewId);
        directTransport = new FrameEbookDirectTransport(this::publishStatus);
        webView = new WebView(context);
        webView.setBackgroundColor(Color.rgb(18, 16, 26));

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(true);
        settings.setSafeBrowsingEnabled(true);

        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(webView, false);

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(
                    WebView view,
                    WebResourceRequest request) {
                WebResourceResponse intercepted = directTransport.intercept(request);
                if (intercepted != null) return intercepted;
                return super.shouldInterceptRequest(view, request);
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String scheme = request.getUrl().getScheme();
                return scheme == null || !"https".equalsIgnoreCase(scheme);
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                publishProgress(0);
                publishStatus("正在載入閱讀室頁面……");
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                publishProgress(100);
                publishStatus("閱讀室已開啟，正在準備書籍內容……");
            }

            @Override
            public void onReceivedError(
                    WebView view,
                    WebResourceRequest request,
                    WebResourceError error) {
                if (request.isForMainFrame()) {
                    publishError(error.getDescription().toString());
                }
            }

            @Override
            public void onReceivedHttpError(
                    WebView view,
                    WebResourceRequest request,
                    WebResourceResponse response) {
                if (request.isForMainFrame() && response.getStatusCode() >= 400) {
                    publishError("HTTP " + response.getStatusCode() + " " + response.getReasonPhrase());
                }
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int progress) {
                publishProgress(progress);
            }
        });

        channel.setMethodCallHandler((MethodCall call, MethodChannel.Result result) -> {
            if ("reload".equals(call.method)) {
                webView.reload();
                result.success(null);
            } else if ("goBack".equals(call.method)) {
                if (webView.canGoBack()) webView.goBack();
                result.success(webView.canGoBack());
            } else if ("currentUrl".equals(call.method)) {
                result.success(webView.getUrl());
            } else {
                result.notImplemented();
            }
        });

        if (initialUrl != null && !initialUrl.isEmpty()) {
            webView.loadUrl(initialUrl);
        }
    }

    @Override
    public View getView() {
        return webView;
    }

    private void publishProgress(int progress) {
        Map<String, Object> args = new HashMap<>();
        args.put("progress", progress);
        channel.invokeMethod("progress", progress);
    }

    private void publishStatus(String status) {
        channel.invokeMethod("status", status);
    }

    private void publishError(String error) {
        channel.invokeMethod("error", error);
    }

    @Override
    public void dispose() {
        channel.setMethodCallHandler(null);
        webView.stopLoading();
        webView.setWebChromeClient(null);
        webView.setWebViewClient(null);
        webView.destroy();
    }
}
