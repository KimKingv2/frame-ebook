window.addEventListener('flutter-first-frame', function () {
  var message = document.getElementById('frame-boot-message');
  if (message) message.remove();
}, { once: true });
