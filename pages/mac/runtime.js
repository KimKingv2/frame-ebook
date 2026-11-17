(function () {
  var isMac = !!(window.__TAURI__ || window.__TAURI_INTERNALS__);
  window.FRAME_LOCAL_APP = isMac;
  if (!isMac) return;
  document.addEventListener("DOMContentLoaded", function () {
    document.querySelectorAll(".cloud-manager-trigger, a[href='/reading-stats/'], #cloud-manager-dialog").forEach(function (node) {
      node.hidden = true;
      node.setAttribute("aria-hidden", "true");
    });
    var intro = document.querySelector(".intro p:not(.eyebrow)");
    if (intro) intro.textContent = "書籍保留在你的 WebDAV 儲存空間。閱讀進度、書籤、筆記與閱讀設定保存在這台 Mac，不依賴 Cloudflare。";
    var notice = document.querySelector(".notice p");
    if (notice) notice.textContent = "原始 EPUB／CBZ 留在 WebDAV。閱讀位置、外觀偏好、書籤、高亮及筆記會保存在本機，不會上傳至 Cloudflare D1。";
    var footer = document.querySelector(".footer span:last-child");
    if (footer) footer.textContent = "LOCAL READING DATA · WEBDAV FILES";
  });
})();