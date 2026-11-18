(function () {
  var message = document.getElementById("frame-boot-message");
  var firstFrame = false;

  function show(messageText) {
    if (message && message.isConnected) {
      message.textContent = messageText;
    }
  }

  window.addEventListener("flutter-first-frame", function () {
    firstFrame = true;
    if (message && message.isConnected) message.remove();
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
