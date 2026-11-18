(function () {
  'use strict';
  try {
    if (new URLSearchParams(window.location.search).get('embed') === 'flutter') {
      document.documentElement.classList.add('flutter-reader-embed');
    }
  } catch (error) {
    console.warn('FRAME Reader embed mode could not be initialized:', error);
  }
}());
