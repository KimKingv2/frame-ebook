(() => {
  "use strict";
  const trigger = document.getElementById("open-cloud-manager");
  const dialog = document.getElementById("cloud-manager-dialog");
  const closeButton = document.getElementById("close-cloud-manager");
  const frame = document.getElementById("cloud-manager-frame");
  if (!trigger || !dialog || !closeButton || !frame) return;

  let frameStarted = false;
  const sendToManager = type => {
    try { frame.contentWindow?.postMessage({ type }, window.location.origin); } catch (_) {}
  };
  const open = () => {
    if (!dialog.open) {
      try { dialog.showModal(); }
      catch (_) { dialog.setAttribute("open", ""); }
    }
    if (!frameStarted) {
      frameStarted = true;
      frame.src = frame.dataset.src || "/cloud/?manager=1";
    } else {
      sendToManager("frame-reader-cloud-manager-open");
    }
  };
  const close = () => {
    if (dialog.open && typeof dialog.close === "function") dialog.close();
    else dialog.removeAttribute("open");
  };

  trigger.addEventListener("click", open);
  closeButton.addEventListener("click", close);
  dialog.addEventListener("click", event => {
    if (event.target === dialog) close();
  });
  dialog.addEventListener("close", () => sendToManager("frame-reader-cloud-manager-close"));
  frame.addEventListener("load", () => {
    if (dialog.open) sendToManager("frame-reader-cloud-manager-open");
  });
})();
