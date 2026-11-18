(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;

  function show(value) {
    if (message && message.isConnected) message.textContent = value;
  }

  window.addEventListener("flutter-first-frame", function () {
    firstFrame = true;
    if (message && message.isConnected) message.remove();
  }, { once: true });

  window.addEventListener("error", function (event) {
    var target = event.target;
    if (target && target !== window && target.tagName === "SCRIPT") {
      var source = target.src || "";
      var path = "unknown-script";
      try {
        if (source) path = new URL(source, window.location.href).pathname;
      } catch (_) {}
      show("FRAME Ebook script load failed: " + path);
      return;
    }
    if (event.message) {
      show("FRAME Ebook JavaScript error: " + String(event.message).slice(0, 150));
    }
  }, true);

  window.addEventListener("unhandledrejection", function (event) {
    var reason = event.reason;
    var detail = reason && reason.message ? reason.message : String(reason || "unknown");
    show("FRAME Ebook initialization error: " + detail.slice(0, 150));
  });

  window.setTimeout(function () {
    if (!firstFrame && message && message.isConnected) {
      show("FRAME Ebook startup timeout: no first frame after 20 seconds.");
    }
  }, 20000);
})();
