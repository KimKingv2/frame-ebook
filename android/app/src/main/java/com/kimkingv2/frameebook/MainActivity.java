package com.kimkingv2.frameebook;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static final String HOME_URL = "https://frame-ebook.pages.dev/";
    private static final int COLOR_BACKGROUND = Color.rgb(16, 14, 21);
    private static final int COLOR_SURFACE = Color.rgb(28, 24, 36);
    private static final int COLOR_ACCENT = Color.rgb(155, 123, 222);

    private WebView webView;
    private TextView statusView;
    private ProgressBar progressBar;
    private FrameEbookDirectTransport directTransport;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(COLOR_SURFACE);
        getWindow().setNavigationBarColor(COLOR_BACKGROUND);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(COLOR_BACKGROUND);

        LinearLayout toolbar = new LinearLayout(this);
        toolbar.setOrientation(LinearLayout.HORIZONTAL);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.setPadding(dp(12), dp(6), dp(12), dp(6));
        toolbar.setBackgroundColor(COLOR_SURFACE);

        TextView brand = new TextView(this);
        brand.setText("FRAME  EBOOK");
        brand.setTextColor(Color.WHITE);
        brand.setTextSize(15);
        brand.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        brand.setLetterSpacing(0.06f);
        toolbar.addView(brand, new LinearLayout.LayoutParams(0, dp(44), 1f));

        Button backButton = makeToolbarButton("‹");
        backButton.setContentDescription("返回上一頁");
        toolbar.addView(backButton, new LinearLayout.LayoutParams(dp(44), dp(44)));

        Button reloadButton = makeToolbarButton("↻");
        reloadButton.setContentDescription("重新載入");
        toolbar.addView(reloadButton, new LinearLayout.LayoutParams(dp(44), dp(44)));

        root.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setProgress(0);
        progressBar.setProgressTintList(android.content.res.ColorStateList.valueOf(COLOR_ACCENT));
        progressBar.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(COLOR_ACCENT));
        root.addView(progressBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(2)));

        statusView = new TextView(this);
        statusView.setText("正在連線至 FRAME Ebook…");
        statusView.setTextColor(Color.rgb(188, 178, 205));
        statusView.setTextSize(11);
        statusView.setSingleLine(true);
        statusView.setPadding(dp(14), dp(5), dp(14), dp(5));
        statusView.setBackgroundColor(Color.rgb(21, 18, 28));
        root.addView(statusView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(26)));

        webView = new WebView(this);
        webView.setBackgroundColor(COLOR_BACKGROUND);
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

        directTransport = new FrameEbookDirectTransport(this::setStatus);
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(
                    WebView view, WebResourceRequest request) {
                WebResourceResponse nativeResponse = directTransport.intercept(request);
                if (nativeResponse != null) return nativeResponse;
                return super.shouldInterceptRequest(view, request);
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String scheme = request.getUrl().getScheme();
                // The reader and Cloudflare Access flow are HTTPS-only. Keeping
                // navigation inside this WebView preserves the Access cookie jar.
                return scheme == null || !"https".equalsIgnoreCase(scheme);
            }

            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                progressBar.setVisibility(View.VISIBLE);
                progressBar.setProgress(0);
                setStatus("正在載入 FRAME Ebook…");
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                if (progressBar.getProgress() >= 100) progressBar.setVisibility(View.GONE);
                setStatus("已連線 · 漫畫 302 原生直連已就緒");
            }

            @Override
            public void onReceivedError(
                    WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    setStatus("頁面載入失敗：" + error.getDescription());
                }
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                progressBar.setProgress(newProgress);
                if (newProgress >= 100) progressBar.setVisibility(View.GONE);
                else progressBar.setVisibility(View.VISIBLE);
            }
        });

        root.addView(webView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);

        backButton.setOnClickListener(v -> {
            if (webView.canGoBack()) webView.goBack();
            else webView.loadUrl(HOME_URL);
        });
        reloadButton.setOnClickListener(v -> webView.reload());

        if (savedInstanceState != null) {
            webView.restoreState(savedInstanceState);
        }
        if (webView.getUrl() == null) webView.loadUrl(HOME_URL);
    }

    private Button makeToolbarButton(String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextColor(Color.WHITE);
        button.setTextSize(23);
        button.setAllCaps(false);
        button.setPadding(0, 0, 0, 0);
        button.setBackground(makeRoundedBackground(Color.rgb(43, 36, 54), dp(12)));
        return button;
    }

    private GradientDrawable makeRoundedBackground(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(radius);
        return drawable;
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void setStatus(String message) {
        runOnUiThread(() -> {
            if (statusView != null) statusView.setText(message);
        });
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) webView.goBack();
        else super.onBackPressed();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (webView != null) webView.onResume();
    }

    @Override
    protected void onPause() {
        if (webView != null) webView.onPause();
        super.onPause();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        if (webView != null) webView.saveState(outState);
        super.onSaveInstanceState(outState);
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.stopLoading();
            webView.setWebChromeClient(null);
            webView.setWebViewClient(null);
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }
}
