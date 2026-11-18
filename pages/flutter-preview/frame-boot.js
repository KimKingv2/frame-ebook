(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;
  var diagnostic = null;
  var apiRequests = [];
  var runtimeErrors = [];
  var contextCalls = [];
  var xhrOpenCount = 0;
  var xhrSendCount = 0;
  var nativeFetch = window.fetch;

  function addLimited(list, value, max) {
    list.push(String(value).replace(/\s+/g, " ").slice(0, 180));
    if (list.length > max) list.shift();
  }

  function show(value) {
    if (message && message.isConnected) message.textContent = value;
  }

  function recordError(value) {
    if (runtimeErrors.length < 4) addLimited(runtimeErrors, value, 4);
  }

  function recordApi(value) {
    addLimited(apiRequests, value, 8);
  }

  // Observe the actual rendering context requests made during Flutter startup.
  // Do not call getContext ourselves: that could create or influence a context.
  function instrumentCanvasContext(proto, label) {
    if (!proto || !proto.getContext || proto.getContext.__frameDiagWrapped) return;
    var original = proto.getContext;
    function wrappedGetContext(type) {
      var context = null;
      var error = "";
      try {
        context = original.apply(this, arguments);
        return context;
      } catch (caught) {
        error = String(caught);
        throw caught;
      } finally {
        var target = this && this.tagName === "CANVAS" ? "canvas" : label;
        var size = "";
        try {
          size = this.width + "x" + this.height;
        } catch (_) {}
        addLimited(
          contextCalls,
          target + ".getContext(" + String(type) + ")=" +
            (context ? "OK" : "NULL") + (error ? ":" + error : "") + "@" + size,
          12
        );
      }
    }
    wrappedGetContext.__frameDiagWrapped = true;
    proto.getContext = wrappedGetContext;
  }

  if (window.HTMLCanvasElement) {
    instrumentCanvasContext(HTMLCanvasElement.prototype, "htmlCanvas");
  }
  if (window.OffscreenCanvas) {
    instrumentCanvasContext(OffscreenCanvas.prototype, "offscreenCanvas");
  }

  // Flutter package:http may use XMLHttpRequest. Record at send time, then update on completion.
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
        if (this.__frameDiagApi) {
          xhrOpenCount++;
          this.__frameDiagId = "xhr" + xhrOpenCount;
        }
      } catch (_) {
        this.__frameDiagApi = false;
      }
      return xhrOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function () {
      if (this.__frameDiagApi) {
        var xhr = this;
        var started = Date.now();
        var label = xhr.__frameDiagId + " " +
          (xhr.__frameDiagMethod || "GET") + " " +
          (xhr.__frameDiagUrl || "/api/?");
        xhrSendCount++;
        recordApi(label + " SENT");
        xhr.addEventListener("loadend", function () {
          var type = "";
          var redirected = false;
          try {
            type = xhr.getResponseHeader("content-type") || "";
            redirected = !!(xhr.responseURL &&
              new URL(xhr.responseURL, window.location.href).pathname.indexOf("/cdn-cgi/access/") === 0);
          } catch (_) {}
          recordApi(
            label + " -> HTTP" + xhr.status + " [" + type + "]" +
            (redirected ? " REDIRECTED" : "") + " " +
            (Date.now() - started) + "ms"
          );
        }, { once: true });
      }
      return xhrSend.apply(this, arguments);
    };
  }

  // Keep visibility into any fetch-based API requests too.
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
      if (isApi) recordApi("FETCH " + String(method).toUpperCase() + " " + parsed.pathname + " SENT");
      var request = nativeFetch.apply(this, arguments);
      if (!isApi) return request;
      return request.then(function (response) {
        recordApi(
          "FETCH " + String(method).toUpperCase() + " " + parsed.pathname +
          " -> HTTP" + response.status + " [" +
          (response.headers.get("content-type") || "") + "] " +
          (Date.now() - started) + "ms"
        );
        return response;
      }, function (error) {
        recordApi("FETCH " + String(method).toUpperCase() + " " +
          parsed.pathname + " FAILED " + String(error).slice(0, 70));
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

  function collectRuntime() {
    var views = allNodes("flutter-view");
    var panes = allNodes("flt-glass-pane");
    var canvases = allNodes("canvas");
    var canvas = "not-found";
    if (canvases.length) {
      var el = canvases[0];
      var rect = el.getBoundingClientRect();
      var css = getComputedStyle(el);
      canvas = Math.round(rect.width) + "x" + Math.round(rect.height) +
        "css/" + el.width + "x" + el.height + "px" +
        ";display=" + css.display +
        ";visibility=" + css.visibility +
        ";opacity=" + css.opacity;
    }
    return {
      viewport: innerWidth + "x" + innerHeight,
      dpr: devicePixelRatio || 1,
      flutterView: views.length ? sizeOf(views[0]) : "not-found",
      glassPane: panes.length ? sizeOf(panes[0]) : "not-found",
      canvasCount: canvases.length,
      canvas: canvas,
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
      var controllerPath = controller ? new URL(controller.scriptURL).pathname : "none";
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
        "position:fixed","left:8px","right:8px","bottom:8px",
        "z-index:100000","max-height:36vh","overflow:auto",
        "margin:0","padding:8px 10px",
        "border:1px solid rgba(197,173,255,.45)","border-radius:7px",
        "background:rgba(18,16,26,.97)","color:#e5dcfa",
        "font:11px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace",
        "white-space:pre-wrap","overflow-wrap:anywhere","pointer-events:none"
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
      window.setTimeout(function () {
        addDiagnostic([
          "FRAME_DIAG|firstFrame=1|viewport=" + info.viewport + "|dpr=" + info.dpr,
          "flutterView=" + info.flutterView + "|glassPane=" + info.glassPane,
          "canvasCount=" + info.canvasCount + "|canvas=" + info.canvas,
          "canvasKit=" + info.canvasKit,
          "contextCalls=" + (contextCalls.length ? contextCalls.join(" ; ") : "none"),
          "session=" + results[0],
          "xhrOpen=" + xhrOpenCount + "|xhrSend=" + xhrSendCount,
          "api=" + (apiRequests.length ? apiRequests.join(" ; ") : "none-observed"),
          "serviceWorker=" + results[1],
          "runtimeErrors=" + (runtimeErrors.length ? runtimeErrors.join(" ; ") : "none")
        ]);
      }, 2600);
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