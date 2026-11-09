/* Small, opt-in compatibility shims for the EPUB Lab only. */
(function (window) {
  'use strict';
  if (typeof window.matchMedia !== 'function') {
    window.matchMedia = function (query) {
      return { media: query, matches: false, addListener: function () {}, removeListener: function () {}, addEventListener: function () {}, removeEventListener: function () {} };
    };
  }
  try {
    var media = window.matchMedia('(min-width: 1px)');
    if (media && !media.addEventListener && media.addListener) {
      media.addEventListener = function (type, listener) { if (type === 'change') media.addListener(listener); };
      media.removeEventListener = function (type, listener) { if (type === 'change' && media.removeListener) media.removeListener(listener); };
    }
  } catch (e) {}
  if (!window.ResizeObserver) {
    window.ResizeObserver = function (callback) {
      this.callback = callback;
      this.targets = [];
      var self = this;
      this.onResize = function () { self.notify(); };
      window.addEventListener('resize', this.onResize, false);
    };
    window.ResizeObserver.prototype.observe = function (target) {
      if (this.targets.indexOf(target) === -1) this.targets.push(target);
      var self = this;
      window.setTimeout(function () { self.notify(); }, 0);
    };
    window.ResizeObserver.prototype.unobserve = function (target) {
      this.targets = this.targets.filter(function (item) { return item !== target; });
    };
    window.ResizeObserver.prototype.disconnect = function () {
      this.targets = [];
      window.removeEventListener('resize', this.onResize, false);
    };
    window.ResizeObserver.prototype.notify = function () {
      var entries = [];
      for (var i = 0; i < this.targets.length; i++) {
        var target = this.targets[i];
        entries.push({ target: target, contentRect: target.getBoundingClientRect() });
      }
      if (entries.length) this.callback(entries, this);
    };
  }
  if (window.Blob && window.FileReader && !window.Blob.prototype.arrayBuffer) {
    window.Blob.prototype.arrayBuffer = function () {
      var blob = this;
      return new Promise(function (resolve, reject) {
        var reader = new FileReader();
        reader.onload = function () { resolve(reader.result); };
        reader.onerror = function () { reject(reader.error || new Error('Blob read failed')); };
        reader.readAsArrayBuffer(blob);
      });
    };
  }
}(window));
