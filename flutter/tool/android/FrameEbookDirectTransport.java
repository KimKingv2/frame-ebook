package com.kimkingv2.frame_ebook;

import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;

import java.io.ByteArrayInputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class FrameEbookDirectTransport {
    private static final String APP_HOST = "frame-ebook.pages.dev";
    private static final String FILE_PATH = "/api/cloud/file";
    private static final int MAX_REDIRECTS = 6;
    private static final int CONNECT_TIMEOUT_MS = 20_000;
    private static final int READ_TIMEOUT_MS = 120_000;

    interface StatusListener {
        void onStatus(String message);
    }

    private final StatusListener statusListener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    FrameEbookDirectTransport(StatusListener statusListener) {
        this.statusListener = statusListener;
    }

    WebResourceResponse intercept(WebResourceRequest request) {
        if (request == null || !"GET".equalsIgnoreCase(request.getMethod())) return null;
        Uri uri = request.getUrl();
        if (!isCloudFileRequest(uri)) return null;

        Uri endpoint = redirectEndpoint(uri);
        publish("正在取得雲端書檔的 302 下載位址…");
        String range = validRange(header(request.getRequestHeaders(), "Range"));
        try {
            return openDirectResponse(endpoint.toString(), range, request.getRequestHeaders());
        } catch (Exception error) {
            String detail = error.getMessage() == null ? "未知網路錯誤" : error.getMessage();
            publish("雲端書檔直連失敗：" + detail);
            return jsonError(502, "雲端書檔直連失敗：" + detail);
        }
    }

    private boolean isCloudFileRequest(Uri uri) {
        if (uri == null
                || !"https".equalsIgnoreCase(uri.getScheme())
                || !APP_HOST.equalsIgnoreCase(uri.getHost())
                || !FILE_PATH.equals(uri.getPath())) return false;

        String provider = uri.getQueryParameter("provider");
        String library = uri.getQueryParameter("library");
        String delivery = uri.getQueryParameter("delivery");
        return ("vps".equals(provider) || "worker".equals(provider) || "mobile".equals(provider))
                && ("books".equals(library) || "comics".equals(library))
                && ("stream".equals(delivery) || "redirect".equals(delivery));
    }

    private Uri redirectEndpoint(Uri original) {
        Uri.Builder builder = original.buildUpon().clearQuery();
        for (String key : original.getQueryParameterNames()) {
            if ("delivery".equals(key)) continue;
            List<String> values = original.getQueryParameters(key);
            for (String value : values) builder.appendQueryParameter(key, value);
        }
        return builder.appendQueryParameter("delivery", "redirect").build();
    }

    private WebResourceResponse openDirectResponse(
            String endpoint,
            String range,
            Map<String, String> originalHeaders) throws IOException {

        String accessCookie = CookieManager.getInstance().getCookie(endpoint);
        String userAgent = header(originalHeaders, "User-Agent");
        URL current = new URL(endpoint);
        boolean firstRequest = true;

        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            HttpURLConnection connection = (HttpURLConnection) current.openConnection();
            connection.setInstanceFollowRedirects(false);
            connection.setRequestMethod("GET");
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setUseCaches(false);
            connection.setRequestProperty("Accept", "*/*");
            connection.setRequestProperty("Accept-Encoding", "identity");
            if (userAgent != null && !userAgent.isEmpty()) {
                connection.setRequestProperty("User-Agent", userAgent);
            }
            if (range != null) connection.setRequestProperty("Range", range);
            if (firstRequest && accessCookie != null && !accessCookie.isEmpty()) {
                // The Access cookie is sent only to the protected Pages host.
                // It is never forwarded to a signed storage URL.
                connection.setRequestProperty("Cookie", accessCookie);
            }

            final int status;
            try {
                status = connection.getResponseCode();
            } catch (IOException error) {
                connection.disconnect();
                throw error;
            }

            if (isRedirect(status)) {
                String location = connection.getHeaderField("Location");
                connection.disconnect();
                if (location == null || location.trim().isEmpty()) {
                    throw new IOException("伺服器回傳跳轉，但沒有提供 Location。");
                }

                URL next = new URL(current, location);
                validateRedirect(next);
                if (isAccessLogin(next)) {
                    publish("Cloudflare Access 登入已過期，請返回書架重新登入。");
                    return jsonError(401, "Cloudflare Access 登入已過期。請返回書架重新登入，再開啟書籍。");
                }

                if (firstRequest) publish("已取得 HTTP 302，正在直接連線雲端網盤…");
                current = next;
                firstRequest = false;
                continue;
            }

            InputStream body;
            try {
                body = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
            } catch (IOException error) {
                body = connection.getErrorStream();
                if (body == null) {
                    connection.disconnect();
                    throw error;
                }
            }
            if (body == null) body = new ByteArrayInputStream(new byte[0]);

            String contentType = connection.getHeaderField("Content-Type");
            String mimeType = "application/octet-stream";
            String encoding = null;
            if (contentType != null) {
                String[] parts = contentType.split(";");
                if (parts.length > 0 && !parts[0].trim().isEmpty()) mimeType = parts[0].trim();
                for (int i = 1; i < parts.length; i++) {
                    String part = parts[i].trim();
                    if (part.toLowerCase(Locale.ROOT).startsWith("charset=")) {
                        encoding = part.substring("charset=".length()).replace("\"", "").trim();
                    }
                }
            }

            Map<String, String> responseHeaders = copySafeHeaders(connection);
            String reason = connection.getResponseMessage();
            if (reason == null || reason.trim().isEmpty()) {
                reason = status >= 400 ? "Upstream Error" : "OK";
            }

            publish(status == 206
                    ? "雲端直連成功 · 網盤回傳 206 Range"
                    : "雲端直連成功 · 正在串流書檔正文");
            return new WebResourceResponse(
                    mimeType,
                    encoding,
                    status,
                    reason,
                    responseHeaders,
                    new DisconnectingInputStream(body, connection)
            );
        }

        throw new IOException("網盤跳轉次數過多，已停止請求。");
    }

    private void validateRedirect(URL target) throws IOException {
        if (!"https".equalsIgnoreCase(target.getProtocol())) {
            throw new IOException("網盤跳轉不是 HTTPS，為保護簽名網址已拒絕。");
        }
        if (target.getUserInfo() != null) throw new IOException("網盤跳轉網址包含帳號資訊，已拒絕。");
        String host = target.getHost();
        if (host == null || host.isEmpty() || host.equalsIgnoreCase("localhost")
                || host.equals("127.0.0.1") || host.equals("::1")) {
            throw new IOException("網盤跳轉目的地無效。");
        }
    }

    private boolean isAccessLogin(URL target) {
        String host = target.getHost() == null ? "" : target.getHost().toLowerCase(Locale.ROOT);
        String path = target.getPath() == null ? "" : target.getPath().toLowerCase(Locale.ROOT);
        return host.endsWith(".cloudflareaccess.com") || path.startsWith("/cdn-cgi/access/login");
    }

    private boolean isRedirect(int status) {
        return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
    }

    private String validRange(String range) {
        if (range == null) return null;
        String value = range.trim();
        return value.matches("bytes=(\\d+-\\d*|-\\d+)") ? value : null;
    }

    private String header(Map<String, String> headers, String name) {
        if (headers == null) return null;
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(name)) return entry.getValue();
        }
        return null;
    }

    private Map<String, String> copySafeHeaders(HttpURLConnection connection) {
        Map<String, String> result = new LinkedHashMap<>();
        String[] allowed = {
                "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
                "ETag", "Last-Modified", "Cache-Control", "Content-Disposition",
                "Content-Encoding", "X-Content-Type-Options"
        };
        for (String name : allowed) {
            String value = connection.getHeaderField(name);
            if (value != null && !value.isEmpty()) result.put(name, value);
        }
        if (!result.containsKey("Cache-Control")) result.put("Cache-Control", "no-store");
        return result;
    }

    private WebResourceResponse jsonError(int status, String message) {
        String escaped = message.replace("\\", "\\\\").replace("\"", "\\\"");
        byte[] bytes = ("{\"error\":\"" + escaped + "\"}").getBytes(StandardCharsets.UTF_8);
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Cache-Control", "no-store");
        headers.put("Content-Length", String.valueOf(bytes.length));
        return new WebResourceResponse(
                "application/json", "UTF-8", status,
                status == 401 ? "Unauthorized" : "Bad Gateway",
                headers, new ByteArrayInputStream(bytes)
        );
    }

    private void publish(String message) {
        if (statusListener != null) mainHandler.post(() -> statusListener.onStatus(message));
    }

    private static final class DisconnectingInputStream extends FilterInputStream {
        private final HttpURLConnection connection;
        private boolean closed;

        DisconnectingInputStream(InputStream input, HttpURLConnection connection) {
            super(input);
            this.connection = connection;
        }

        @Override
        public void close() throws IOException {
            if (closed) return;
            closed = true;
            try {
                super.close();
            } finally {
                connection.disconnect();
            }
        }
    }
}
