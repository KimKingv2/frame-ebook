(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;
  var diagnostic = null;
  var apiRequests = [];
  var runtimeErrors = [];
  var nativeFetch = window.fetch;

  function show(messageText) {
    if (message && message.isConnected) message.textContent = messageText;
  }

  function recordError(value) {
    if (runtimeErrors.length < 4) {
      runtimeErrors.push(String(value).replace(/\s+/g, " ").slice(0, 120));
    }
  }

  function recordApi(method, url, status, type, redirected, elapsed) {
    var line = method + " " + url + " -> " + status +
      " [" + (type || "unknown") + "]" +
      (redirected ? " REDIRECTED" : "") + " " + elapsed + "ms";
    apiRequests.push(line);
    if (apiRequests.length > 8) apiRequests.shift();
  }

  // Flutter's package:http BrowserClient uses XMLHttpRequest.
  // Instrument it before Flutter bootstraps, without reading request/response bodies.
  if (window.XMLHttpRequest) {
    var xhrOpen = XMLHttpRequest.prototype.open;
    var xhrSend = XMLHttpRequest.prototype.send;

    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        var parsed = new URL(String(url), window.location.href);
        this.__frameDiagApi = parsed.origin === window.location.origin &&
          parsed.pathname.indexOf("/api/") === 0;
        this.__frameDiagMethod = String(method || "GET").toUpperCase();
        this.__frameDiagUrl = parsed.pathname + parsed.search;
      } catch (_) {
        this.__frameDiagApi = false;
      }
      return xhrOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function () {
      if (this.__frameDiagApi) {
        var xhr = this;
        var started = Date.now();
        xhr.addEventListener("loadend", function () {
          var type = "";
          var redirected = false;
          try {
            type = xhr.getResponseHeader("content-type") || "";
            redirected = !!(xhr.responseURL &&
              new URL(xhr.responseURL, window.location.href).pathname.indexOf("/cdn-cgi/access/") === 0);
          } catch (_) {}
          recordApi(
            xhr.__frameDiagMethod || "GET",
            xhr.__frameDiagUrl || "/api/?",
            "HTTP" + xhr.status,
            type,
            redirected,
            Date.now() - started
          );
        }, { once: true });
      }
      return xhrSend.apply(this, arguments);
    };
  }

  // Also observe fetch-based API calls, if the app adds any later.
  if (typeof nativeFetch === "function") {
    window.fetch = function (input, init) {
      var rawUrl = typeof input === "string" ? input :
        (input && input.url ? input.url : String(input));
      var method = (init && init.method) ||
        (input && input.method) || "GET";
      var parsed;
      try {
        parsed = new URL(rawUrl, window.location.href);
      } catch (_) {
        return nativeFetch.apply(this, arguments);
      }
      var isApi = parsed.origin === window.location.origin &&
        parsed.pathname.indexOf("/api/") === 0;
      var started = Date.now();
      var request = nativeFetch.apply(this, arguments);
      if (!isApi) return request;
      return request.then(function (response) {
        recordApi(
          String(method).toUpperCase(),
          parsed.pathname + parsed.search,
          "HTTP" + response.status,
          response.headers.get("content-type") || "",
          response.redirected,
          Date.now() - started
        );
        return response;
      }, function (error) {
        recordApi(
          String(method).toUpperCase(),
          parsed.pathname + parsed.search,
          "FAILED",
          String(error).slice(0, 60),
          false,
          Date.now() - started
        );
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
    if (!element) return "not-found";
    var rect = element.getBoundingClientRect();
    return Math.round(rect.width) + "x" + Math.round(rect.height);
  }

  function canvasInfo(canvas) {
    var rect = canvas.getBoundingClientRect();
    var css = window.getComputedStyle(canvas);
    var result = Math.round(rect.width) + "x" + Math.round(rect.height) +
      "css/" + canvas.width + "x" + canvas.height + "px" +
      ";display=" + css.display +
      ";visibility=" + css.visibility +
      ";opacity=" + css.opacity;
    var gl = null;
    try {
      gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
      if (gl) {
        var attrs = gl.getContextAttributes();
        result += ";webgl=" + (gl.getParameter(gl.VERSION) || "yes") +
          ";contextLost=" + gl.isContextLost() +
          ";preserve=" + (attrs ? attrs.preserveDrawingBuffer : "unknown");
      } else {
        result += ";webgl=none";
      }
    } catch (error) {
      result += ";webgl-check-error=" + String(error).slice(0, 70);
    }
    return result;
  }

  function collectRuntime() {
    var views = allNodes("flutter-view");
    var panes = allNodes("flt-glass-pane");
    var canvases = allNodes("canvas");
    return {
      viewport: window.innerWidth + "x" + window.innerHeight,
      dpr: window.devicePixelRatio || 1,
      flutterView: views.length ? sizeOf(views[0]) : "not-found",
      glassPane: panes.length ? sizeOf(panes[0]) : "not-found",
      canvasCount: canvases.length,
      canvas: canvases.length ? canvasInfo(canvases[0]) : "not-found",
      canvasKit: window.flutterCanvasKit ? "loaded" : "not-on-window"
    };
  }

  function checkSession() {
    return nativeFetch.call(window, "/api/auth/session", {
      method: "GET",
      credentials: "include",
      headers: { "Accept": "application/json" },
      cache: "no-store"
    }).then(function (response) {
      var type = response.headers.get("content-type") || "unknown";
      return response.text().then(function (body) {
        var state = "HTTP" + response.status + ":" + type;
        try {
          var data = JSON.parse(body);
          state += ":authenticated=" + String(data.authenticated) +
            ":accessEnabled=" + String(data.accessEnabled);
        } catch (_) {
          state += ":invalid-json";
        }
        return state;
      });
    }).catch(function (error) {
      return "FAILED:" + String(error).slice(0, 80);
    });
  }

  function serviceWorkerInfo() {
    if (!navigator.serviceWorker) return Promise.resolve("unsupported");
    return navigator.serviceWorker.getRegistrations().then(function (registrations) {
      var controller = navigator.serviceWorker.controller;
      var controllerPath = controller ?
        new URL(controller.scriptURL).pathname : "none";
      var relevant = registrations.map(function (registration) {
        return new URL(registration.scope).pathname;
      }).filter(function (scope) {
        return scope === "/" || scope.indexOf("/flutter-preview/") === 0;
      });
      return "controller=" + controllerPath +
        ";registrations=" + (relevant.length ? relevant.join(",") : "none");
    }).catch(function (error) {
      return "FAILED:" + String(error).slice(0, 60);
    });
  }

  function addDiagnostic(lines) {
    if (!diagnostic) {
      diagnostic = document.createElement("pre");
      diagnostic.id = "frame-runtime-diagnostic";
      diagnostic.style.cssText = [
        "position:fixed",
        "left:8px",
        "right:8px",
        "bottom:8px",
        "z-index:100000",
        "max-height:34vh",
        "overflow:auto",
        "margin:0",
        "padding:8px 10px",
        "border:1px solid rgba(197,173,255,.45)",
        "border-radius:7px",
        "background:rgba(18,16,26,.97)",
        "color:#e5dcfa",
        "font:11px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace",
        "white-space:pre-wrap",
        "overflow-wrap:anywhere",
        "pointer-events:none"
      ].join(";");
      document.body.appendChild(diagnostic);
    }
    diagnostic.textContent = lines.join("\n");
  }

  window.addEventListener("flutter-first-frame", function () {
    firstFrame = true;
    if (message && message.isConnected) message.remove();

    var info = collectRuntime();
    Promise.all([checkSession(), serviceWorkerInfo()]).then(function (results) {
      // Wait for the initial bookshelf request to finish before printing the log.
      window.setTimeout(function () {
        var calls = apiRequests.length ? apiRequests.join(" | ") : "none-observed";
        var errors = runtimeErrors.length ? runtimeErrors.join(" | ") : "none";
        addDiagnostic([
          "FRAME_DIAG|firstFrame=1|viewport=" + info.viewport + "|dpr=" + info.dpr,
          "flutterView=" + info.flutterView + "|glassPane=" + info.glassPane,
          "canvasCount=" + info.canvasCount + "|canvas=" + info.canvas,
          "canvasKit=" + info.canvasKit,
          "session=" + results[0],
          "api=" + calls,
          "serviceWorker=" + results[1],
          "runtimeErrors=" + errors
        ]);
      }, 2200);
    });
  }, { once: true });

  window.addEventListener("error", function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName === "SCRIPT") {
      var source = target.src || "";
      var path = source ? new URL(source, window.location.href).pathname : "unknown-script";
      recordError("script-load:" + path);
      show("FRAME Ebook script load failed: " + path);
      return;
    }
    if (event.message) {
      recordError(event.message);
      show("FRAME Ebook JavaScript error: " + String(event.message).slice(0, 150));
    }
  }, true);

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var detail = reason && reason.message ? reason.message : String(reason || "unknown");
    recordError("rejection:" + detail);
    show("FRAME Ebook initialization error: " + detail.slice(0, 150));
  });

  window.setTimeout(function () {
    if (!firstFrame && message && message.isConnected) {
      show("FRAME Ebook startup timeout: no first frame after 20 seconds.");
    }
  }, 20000);
})();