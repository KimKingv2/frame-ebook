(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;
  var diagnostic = null;
  var apiRequests = [];
  var runtimeErrors = [];
  var nativeFetch = window.fetch;

  function show(messageText) {
    if (message && message.isConnected) {
      message.textContent = messageText;
    }
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
        "max-height:28vh",
        "overflow:auto",
        "padding:7px 10px",
        "border:1px solid rgba(197,173,255,.45)",
        "border-radius:7px",
        "background:rgba(18,16,26,.96)",
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

  function recordError(value) {
    if (runtimeErrors.length < 4) {
      runtimeErrors.push(String(value).replace(/\s+/g, " ").slice(0, 150));
    }
  }

  // Record the app's own API calls without reading or changing their bodies.
  if (typeof nativeFetch === "function") {
    window.fetch = function (input, init) {
      var rawUrl = typeof input === "string" ? input :
        (input && input.url ? input.url : String(input));
      var method = (init && init.method) ||
        (input && input.method) || "GET";
      var requestUrl;
      try {
        requestUrl = new URL(rawUrl, window.location.href);
      } catch (_) {
        return nativeFetch.apply(this, arguments);
      }
      var isFrameApi = requestUrl.origin === window.location.origin &&
        requestUrl.pathname.indexOf("/api/") === 0;
      var started = Date.now();
      var request = nativeFetch.apply(this, arguments);
      if (!isFrameApi) return request;
      return request.then(function (response) {
        apiRequests.push(
          method + " " + requestUrl.pathname + "=" + response.status +
          " " + (response.headers.get("content-type") || "?") +
          (response.redirected ? " redirected" : "") +
          " " + (Date.now() - started) + "ms"
        );
        if (apiRequests.length > 8) apiRequests.shift();
        return response;
      }, function (error) {
        apiRequests.push(method + " " + requestUrl.pathname +
          "=FAILED " + String(error).slice(0, 80));
        if (apiRequests.length > 8) apiRequests.shift();
        throw error;
      });
    };
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

  function styleOf(element) {
    if (!element) return "未找到";
    var style = window.getComputedStyle(element);
    return style.display + "/" + style.visibility +
      "/opacity:" + style.opacity + "/transform:" + style.transform;
  }

  function collectRuntime() {
    var views = allNodes("flutter-view");
    var panes = allNodes("flt-glass-pane");
    var canvases = allNodes("canvas");
    var canvasInfo = canvases.map(function (canvas) {
      var gl = null;
      var renderer = "無 WebGL context";
      var lost = "未知";
      var preserve = "未知";
      try {
        gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
        if (gl) {
          renderer = gl.getParameter(gl.VERSION) || "WebGL";
          lost = gl.isContextLost() ? "是" : "否";
          var attrs = gl.getContextAttributes();
          preserve = attrs ? String(attrs.preserveDrawingBuffer) : "未知";
        }
      } catch (error) {
        renderer = "WebGL 檢查失敗：" + String(error).slice(0, 70);
      }
      return Math.round(canvas.getBoundingClientRect().width) + "×" +
        Math.round(canvas.getBoundingClientRect().height) + " CSS/" +
        canvas.width + "×" + canvas.height + " px" +
        "；" + styleOf(canvas) +
        "；" + renderer + "；contextLost=" + lost +
        "；preserve=" + preserve;
    });
    return {
      viewport: window.innerWidth + "×" + window.innerHeight,
      dpr: window.devicePixelRatio || 1,
      flutterView: views.length ? sizeOf(views[0]) + " " + styleOf(views[0]) : "未找到",
      glassPane: panes.length ? sizeOf(panes[0]) + " " + styleOf(panes[0]) : "未找到",
      canvasCount: canvases.length,
      canvas: canvasInfo.length ? canvasInfo.slice(0, 2).join("；") : "未找到",
      canvasKit: window.flutterCanvasKit ? "已載入" : "尚未掛到 window"
    };
  }

  function checkSession() {
    return nativeFetch.call(window, "/api/auth/session", {
      method: "GET",
      credentials: "include",
      headers: { "Accept": "application/json" },
      cache: "no-store"
    }).then(function (response) {
      var type = response.headers.get("content-type") || "未知格式";
      return response.text().then(function (body) {
        var state = "HTTP " + response.status + " " + type;
        try {
          var data = JSON.parse(body);
          state += data.authenticated === true ? "；Access已驗證" :
            "；authenticated=" + String(data.authenticated);
        } catch (_) {
          state += "；回應非 JSON";
        }
        return state;
      });
    }).catch(function (error) {
      return "讀取失敗：" + String(error).slice(0, 100);
    });
  }

  function serviceWorkerInfo() {
    if (!navigator.serviceWorker) return Promise.resolve("不支援");
    return navigator.serviceWorker.getRegistrations().then(function (registrations) {
      var controller = navigator.serviceWorker.controller;
      var controllerPath = controller ?
        new URL(controller.scriptURL).pathname : "無 controller";
      var relevant = registrations.map(function (registration) {
        return new URL(registration.scope).pathname;
      }).filter(function (scope) {
        return scope === "/" || scope.indexOf("/flutter-preview/") === 0;
      });
      return "controller=" + controllerPath +
        "；registrations=" + (relevant.length ? relevant.join(",") : "無");
    }).catch(function (error) {
      return "讀取失敗：" + String(error).slice(0, 80);
    });
  }

  function renderDiagnostic(info, session, sw) {
    var calls = apiRequests.length ? apiRequests.join(" | ") : "尚未觀察到 API 呼叫";
    var errors = runtimeErrors.length ? runtimeErrors.join(" | ") : "無瀏覽器層錯誤";
    addDiagnostic(
      "Flutter首幀已觸發｜視窗 " + info.viewport + "｜DPR " + info.dpr +
      "\nFlutterView " + info.flutterView +
      "\nGlassPane " + info.glassPane +
      "\nCanvas " + info.canvasCount + "個：" + info.canvas +
      "\nCanvasKit " + info.canvasKit +
      "\nSession " + session +
      "\nAPI呼叫 " + calls +
      "\nServiceWorker " + sw +
      "\nRuntime錯誤 " + errors
    );
  }

  window.addEventListener("flutter-first-frame", function () {
    firstFrame = true;
    if (message && message.isConnected) message.remove();
    var info = collectRuntime();
    Promise.all([checkSession(), serviceWorkerInfo()]).then(function (results) {
      // Allow the app's own post-login bookshelf request to finish as well.
      window.setTimeout(function () {
        renderDiagnostic(info, results[0], results[1]);
      }, 1800);
    });
  }, { once: true });

  window.addEventListener("error", function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName === "SCRIPT") {
      var source = target.src || "";
      var path = source ? new URL(source, window.location.href).pathname : "未知腳本";
      show("FRAME Ebook 腳本載入失敗：" + path);
      recordError("script " + path);
      return;
    }
    if (event.message) {
      recordError(event.message);
      show("FRAME Ebook JavaScript 啟動錯誤：" + String(event.message).slice(0, 180));
    }
  }, true);

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var detail = reason && reason.message ? reason.message : String(reason || "未知錯誤");
    recordError("rejection " + detail);
    show("FRAME Ebook 初始化失敗：" + detail.slice(0, 180));
  });

  window.setTimeout(function () {
    if (!firstFrame && message && message.isConnected) {
      show("FRAME Ebook 啟動逾時：20 秒內沒有繪出第一幀。請查看瀏覽器 Console 的第一條紅色錯誤訊息。");
    }
  }, 20000);
})();