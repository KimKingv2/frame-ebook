(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;
  var diagnostic = null;

  function show(messageText) {
    if (message && message.isConnected) {
      message.textContent = messageText;
    }
  }

  function allNodes(selector) {
    var result = [];
    var roots = [document];
    var visited = [];
    while (roots.length) {
      var root = roots.pop();
      if (!root || visited.indexOf(root) !== -1) continue;
      visited.push(root);
      try {
        result = result.concat(Array.prototype.slice.call(root.querySelectorAll(selector)));
        var nodes = root.querySelectorAll("*");
        for (var i = 0; i < nodes.length; i++) {
          if (nodes[i].shadowRoot) roots.push(nodes[i].shadowRoot);
        }
      } catch (_) {}
    }
    return result;
  }

  function sizeOf(element) {
    if (!element) return "未找到";
    var rect = element.getBoundingClientRect();
    return Math.round(rect.width) + "×" + Math.round(rect.height);
  }

  function addDiagnostic(text) {
    if (!diagnostic) {
      diagnostic = document.createElement("div");
      diagnostic.id = "frame-runtime-diagnostic";
      diagnostic.style.cssText = [
        "position:fixed",
        "left:8px",
        "right:8px",
        "bottom:8px",
        "z-index:100000",
        "padding:7px 10px",
        "border:1px solid rgba(197,173,255,.45)",
        "border-radius:7px",
        "background:rgba(18,16,26,.94)",
        "color:#d8ccf5",
        "font:11px/1.5 -apple-system,BlinkMacSystemFont,sans-serif",
        "white-space:normal",
        "overflow-wrap:anywhere",
        "pointer-events:none"
      ].join(";");
      document.body.appendChild(diagnostic);
    }
    diagnostic.textContent = text;
  }

  function collectRuntime() {
    var views = allNodes("flutter-view");
    var panes = allNodes("flt-glass-pane");
    var canvases = allNodes("canvas");
    var canvasInfo = canvases.map(function (canvas) {
      var rect = canvas.getBoundingClientRect();
      return Math.round(rect.width) + "×" + Math.round(rect.height) +
        " CSS / " + canvas.width + "×" + canvas.height + " px";
    });
    return {
      viewport: window.innerWidth + "×" + window.innerHeight,
      dpr: window.devicePixelRatio || 1,
      flutterView: views.length ? sizeOf(views[0]) : "未找到",
      glassPane: panes.length ? sizeOf(panes[0]) : "未找到",
      canvasCount: canvases.length,
      canvas: canvasInfo.length ? canvasInfo.slice(0, 3).join("；") : "未找到"
    };
  }

  function checkApi(info) {
    fetch("/api/auth/session", {
      method: "GET",
      credentials: "include",
      headers: { "Accept": "application/json" },
      cache: "no-store"
    }).then(function (response) {
      var type = response.headers.get("content-type") || "未知格式";
      var result = "API HTTP " + response.status + " · " + type;
      return response.text().then(function (body) {
        try {
          var data = JSON.parse(body);
          result += data.authenticated === true
            ? " · Access 已驗證"
            : " · authenticated=" + String(data.authenticated);
        } catch (_) {
          if (response.url.indexOf("/cdn-cgi/access/") !== -1) {
            result += " · 被導向 Access 登入頁";
          }
        }
        addDiagnostic(
          "Flutter 首幀已觸發｜視窗 " + info.viewport +
          "｜DPR " + info.dpr +
          "｜FlutterView " + info.flutterView +
          "｜GlassPane " + info.glassPane +
          "｜Canvas " + info.canvasCount + " 個：" + info.canvas +
          "｜" + result
        );
      });
    }).catch(function (error) {
      addDiagnostic(
        "Flutter 首幀已觸發｜視窗 " + info.viewport +
        "｜FlutterView " + info.flutterView +
        "｜Canvas " + info.canvasCount +
        " 個：" + info.canvas +
        "｜API 讀取失敗：" + String(error).slice(0, 100)
      );
    });
  }

  window.addEventListener("flutter-first-frame", function () {
    firstFrame = true;
    if (message && message.isConnected) message.remove();
    window.setTimeout(function () {
      var info = collectRuntime();
      checkApi(info);
    }, 800);
  }, { once: true });

  window.addEventListener("error", function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName === "SCRIPT") {
      var source = target.src || "";
      var path = source ? new URL(source, window.location.href).pathname : "未知腳本";
      show("FRAME Ebook 腳本載入失敗：" + path);
      return;
    }
    if (event.message) {
      show("FRAME Ebook JavaScript 啟動錯誤：" + String(event.message).slice(0, 180));
    }
  }, true);

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var detail = reason && reason.message ? reason.message : String(reason || "未知錯誤");
    show("FRAME Ebook 初始化失敗：" + detail.slice(0, 180));
  });

  window.setTimeout(function () {
    if (!firstFrame && message && message.isConnected) {
      show("FRAME Ebook 啟動逾時：20 秒內沒有繪出第一幀。請查看瀏覽器 Console 的第一條紅色錯誤訊息。");
    }
  }, 20000);
})();
