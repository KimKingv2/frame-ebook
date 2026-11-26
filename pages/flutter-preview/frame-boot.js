(function () {
  var message = document.getElementById('frame-boot-message');
  if (!message) return;

  var hint = document.getElementById('frame-boot-hint');
  var retry = document.getElementById('frame-boot-retry');
  var firstFrameReceived = false;

  var timeoutId = window.setTimeout(function () {
    if (firstFrameReceived || !message.isConnected) return;
    if (hint) hint.hidden = false;
    if (retry) retry.hidden = false;
  }, 18000);

  if (retry) {
    retry.addEventListener('click', function () {
      window.location.reload();
    });
  }

  window.addEventListener('flutter-first-frame', function () {
    firstFrameReceived = true;
    window.clearTimeout(timeoutId);
    message.remove();
  }, { once: true });
}());
