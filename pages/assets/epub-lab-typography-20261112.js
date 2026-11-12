/* FRAME Reader Reading Room — Foliate.js adapter.
 * The archive is loaded fully into memory by JSZip for this small prototype.
 * Reading appearance settings are local to this browser.
 */
(function () {
  'use strict';
  var view = null;
  var currentStorageKey = null;
  var restoreCfi = null;
  var restoring = false;
  var APPEARANCE_KEY = 'frame-reader-appearance-v1';
  var THEMES = {
    paper: { background: '#fffefa', foreground: '#29262d', colorScheme: 'light' },
    sepia: { background: '#f1e7d5', foreground: '#40362b', colorScheme: 'light' },
    night: { background: '#191821', foreground: '#e5dfed', colorScheme: 'dark' }
  };
  var appearance = {
    fontScale: '1',
    lineHeight: '1.65',
    verticalMargin: '16',
    horizontalMargin: '7',
    fontFamily: 'original',
    fontWeight: 'original',
    paragraphSpacing: 'original',
    textAlign: 'original',
    theme: 'paper'
  };
  var el = function (id) { return document.getElementById(id); };
  var setText = function (id, value) { var node = el(id); if (node) node.textContent = value; };
  var safeGet = function (key) { try { return localStorage.getItem(key); } catch (e) { return null; } };
  var safeSet = function (key, value) { try { localStorage.setItem(key, value); return true; } catch (e) { return false; } };

  function titleText(value) {
    if (typeof value === 'string') return value;
    if (value && typeof value === 'object') {
      return value['zh-Hant'] || value.zh || value.en || value[Object.keys(value)[0]] || '未命名書籍';
    }
    return '未命名書籍';
  }
  function flattenTOC(items, output) {
    output = output || [];
    (items || []).forEach(function (item) {
      if (item && item.href) output.push({ label: titleText(item.label), href: item.href });
      if (item && item.subitems) flattenTOC(item.subitems, output);
    });
    return output;
  }
  function populateTOC(items) {
    var select = el('toc-select');
    select.innerHTML = '';
    var list = flattenTOC(items);
    if (!list.length) {
      var empty = document.createElement('option');
      empty.value = '';
      empty.appendChild(document.createTextNode('這本書沒有可用目錄'));
      select.appendChild(empty);
      select.disabled = true;
      return;
    }
    list.forEach(function (item) {
      var option = document.createElement('option');
      option.value = item.href;
      option.appendChild(document.createTextNode(item.label));
      select.appendChild(option);
    });
    select.disabled = false;
  }
  function updateLocation(detail) {
    if (!detail) return;
    if (typeof detail.fraction === 'number' && isFinite(detail.fraction)) {
      var percent = Math.max(0, Math.min(100, Math.round(detail.fraction * 100)));
      setText('progress-percent', percent + '%');
      var section = detail.section;
      if (section && section.total) setText('progress-detail', '章節 ' + (section.current + 1) + ' / ' + section.total);
      else setText('progress-detail', '閱讀位置已更新');
    }
    if (detail.cfi && currentStorageKey && !restoring) {
      if (safeSet(currentStorageKey, detail.cfi)) setText('reader-status', '閱讀位置已保存在這台設備。跨設備同步尚未啟用。');
      else setText('reader-status', '瀏覽器不允許保存本機閱讀位置。');
    }
  }
  function makeLoader(zip) {
    return {
      loadText: function (name) {
        var entry = zip.file(name);
        return entry ? entry.async('string') : Promise.resolve(null);
      },
      loadBlob: function (name, type) {
        var entry = zip.file(name);
        if (!entry) return Promise.resolve(null);
        return entry.async('uint8array').then(function (bytes) {
          return new Blob([bytes], { type: type || 'application/octet-stream' });
        });
      },
      getSize: function (name) {
        var entry = zip.file(name);
        return entry && entry._data && typeof entry._data.uncompressedSize === 'number' ? entry._data.uncompressedSize : 0;
      }
    };
  }
  function loadAppearance() {
    var saved = safeGet(APPEARANCE_KEY);
    if (saved) {
      try {
        var value = JSON.parse(saved);
        if (value && typeof value === 'object') {
          if (['0.9', '1', '1.1', '1.2', '1.3'].indexOf(String(value.fontScale)) !== -1) appearance.fontScale = String(value.fontScale);
          if (['1.45', '1.65', '1.85', '2'].indexOf(String(value.lineHeight)) !== -1) appearance.lineHeight = String(value.lineHeight);
          if (['8', '16', '24'].indexOf(String(value.verticalMargin)) !== -1) appearance.verticalMargin = String(value.verticalMargin);
          if (['4', '7', '10'].indexOf(String(value.horizontalMargin)) !== -1) appearance.horizontalMargin = String(value.horizontalMargin);
          if (['original', 'serif', 'sans'].indexOf(String(value.fontFamily)) !== -1) appearance.fontFamily = String(value.fontFamily);
          if (['original', 'normal', 'medium'].indexOf(String(value.fontWeight)) !== -1) appearance.fontWeight = String(value.fontWeight);
          if (['original', 'compact', 'standard', 'loose'].indexOf(String(value.paragraphSpacing)) !== -1) appearance.paragraphSpacing = String(value.paragraphSpacing);
          if (['original', 'left', 'justify'].indexOf(String(value.textAlign)) !== -1) appearance.textAlign = String(value.textAlign);
          // Migrate the previous combined control and preserve its selected scale.
          if (!value.verticalMargin && !value.horizontalMargin && ['8', '16', '24'].indexOf(String(value.margin)) !== -1) {
            appearance.verticalMargin = String(value.margin);
            appearance.horizontalMargin = ({ '8': '4', '16': '7', '24': '10' })[String(value.margin)];
          }
          if (Object.prototype.hasOwnProperty.call(THEMES, value.theme)) appearance.theme = value.theme;
        }
      } catch (e) {}
    }
    el('font-scale').value = appearance.fontScale;
    el('line-height').value = appearance.lineHeight;
    el('vertical-margin').value = appearance.verticalMargin;
    el('horizontal-margin').value = appearance.horizontalMargin;
    el('font-family').value = appearance.fontFamily;
    el('font-weight').value = appearance.fontWeight;
    el('paragraph-spacing').value = appearance.paragraphSpacing;
    el('text-align').value = appearance.textAlign;
    updateThemeButtons();
  }
  function saveAppearance() {
    var ok = safeSet(APPEARANCE_KEY, JSON.stringify(appearance));
    setText('appearance-status', ok
      ? '外觀設定已保存在這台設備；其他設備尚未同步。'
      : '瀏覽器未允許本機儲存，這次設定不會保留。');
  }
  function updateThemeButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
      button.setAttribute('aria-pressed', button.getAttribute('data-theme') === appearance.theme ? 'true' : 'false');
    });
  }
  function documentStyleText() {
    var theme = THEMES[appearance.theme];
    var scale = Number(appearance.fontScale);
    var line = Number(appearance.lineHeight);
    var rules = [
      ':root { color-scheme: ' + theme.colorScheme + ' !important; font-size: ' + Math.round(scale * 100) + '% !important; background-color: ' + theme.background + ' !important; color: ' + theme.foreground + ' !important; }',
      'html, body { background-color: ' + theme.background + ' !important; color: ' + theme.foreground + ' !important; }',
      'body { line-height: ' + line + ' !important; }',
      'body p, body li, body blockquote, body dd, body dt { line-height: ' + line + ' !important; }',
      'body, body *:not(img):not(svg):not(video):not(canvas):not(iframe) { color: ' + theme.foreground + ' !important; }',
      'body *:not(img):not(svg):not(video):not(canvas):not(iframe) { background-color: transparent !important; }',
      'img, svg, video, canvas { max-width: 100%; }'
    ];

    var fontFamilies = {
      serif: 'ui-serif, "Songti TC", "Songti SC", "Noto Serif CJK TC", "PMingLiU", serif',
      sans: '-apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans CJK TC", sans-serif'
    };
    if (fontFamilies[appearance.fontFamily]) {
      rules.push('body, body p, body h1, body h2, body h3, body h4, body h5, body h6, body li, body blockquote, body dd, body dt { font-family: ' + fontFamilies[appearance.fontFamily] + ' !important; }');
    }

    if (appearance.fontWeight !== 'original') {
      var weight = appearance.fontWeight === 'medium' ? '500' : '400';
      rules.push('body p, body li, body blockquote, body dd, body dt { font-weight: ' + weight + ' !important; }');
    }

    var paragraphSpacing = {
      compact: '0.4em',
      standard: '0.8em',
      loose: '1.2em'
    };
    if (paragraphSpacing[appearance.paragraphSpacing]) {
      rules.push('body p { margin-block-end: ' + paragraphSpacing[appearance.paragraphSpacing] + ' !important; }');
    }

    if (appearance.textAlign !== 'original') {
      var alignment = appearance.textAlign === 'justify' ? 'justify' : 'left';
      rules.push('body p, body li, body blockquote, body dd, body dt { text-align: ' + alignment + ' !important; }');
    }

    return rules.join('\n');
  }
  function applyDocumentAppearance(doc) {
    if (!doc || !doc.documentElement || !doc.head) return;
    var style = doc.getElementById('frame-reader-user-appearance');
    if (!style) {
      style = doc.createElement('style');
      style.id = 'frame-reader-user-appearance';
      doc.head.appendChild(style);
    }
    style.textContent = documentStyleText();
  }
  function applyAppearance() {
    var theme = THEMES[appearance.theme];
    var viewport = el('reader-viewport');
    viewport.dataset.theme = appearance.theme;
    viewport.style.backgroundColor = theme.background;
    viewport.style.color = theme.foreground;

    if (view) {
      view.style.setProperty('--frame-reader-page-background', theme.background);
      view.style.setProperty('--frame-reader-page-foreground', theme.foreground);
    }

    if (view && view.renderer && !view.isFixedLayout) {
      // Keep the two axes independent. Foliate expects a CSS length for
      // vertical margin and a percentage for horizontal page gap.
      view.renderer.setAttribute('margin', appearance.verticalMargin + 'px');
      view.renderer.setAttribute('gap', appearance.horizontalMargin + '%');
      try {
        view.renderer.getContents().forEach(function (item) {
          applyDocumentAppearance(item.doc);
        });
      } catch (e) {}
      if (typeof view.renderer.render === 'function') {
        view.renderer.render();
      }
    }
    updateThemeButtons();
  }
  function setAppearance(name, value) {
    appearance[name] = String(value);
    saveAppearance();
    applyAppearance();
  }
  async function openEpub(source, name) {
    if (!window.JSZip) throw new Error('JSZip 尚未載入，請重新整理頁面。');
    setText('reader-status', '正在讀取 EPUB 封裝與目錄……');
    setText('engine-status', '正在解析 EPUB');
    el('prev-page').disabled = true;
    el('next-page').disabled = true;
    el('toc-select').disabled = true;
    var zip = await window.JSZip.loadAsync(source, { checkCRC32: false });
    var module = await import('/vendor/foliate-js/epub.js');
    var parsedBook = await new module.EPUB(makeLoader(zip)).init();
    if (view) { try { view.close(); } catch (e) {} }
    var metadata = parsedBook.metadata || {};
    var identifier = metadata.identifier || name || 'sample';
    currentStorageKey = 'frame-reader-epub-cfi:' + String(identifier);
    restoreCfi = safeGet(currentStorageKey);
    restoring = !!restoreCfi;
    setText('book-title', titleText(metadata.title) || name);
    setText('book-author', titleText(metadata.author) || (name || 'EPUB 測試書'));
    populateTOC(parsedBook.toc || []);
    var viewport = el('reader-viewport');
    viewport.innerHTML = '';
    view = document.createElement('foliate-view');
    view.style.display = 'block';
    view.style.width = '100%';
    view.style.height = '100%';
    view.addEventListener('load', function (event) {
      if (!view.isFixedLayout) applyDocumentAppearance(event.detail && event.detail.doc);
    });
    view.addEventListener('relocate', function (event) {
      updateLocation(event.detail || {});
    });
    viewport.appendChild(view);
    await view.open(parsedBook);

    // Foliate separates parsing/opening from its first navigation.
    // Calling init() is required before the first section can be rendered.
    var locationMessage = 'EPUB 已載入。可使用翻頁按鈕或章節目錄。';
    try {
      if (restoreCfi) {
        await view.init({ lastLocation: restoreCfi, showTextStart: true });
        locationMessage = '已恢復這本書上次的閱讀位置。此位置目前只存在本機。';
      } else {
        await view.init({ showTextStart: true });
      }
    } catch (navigationError) {
      if (restoreCfi) {
        try {
          await view.goToTextStart();
          locationMessage = '舊閱讀位置無法恢復，已從正文開頭開始。';
        } catch (fallbackError) {
          throw fallbackError;
        }
      } else {
        throw navigationError;
      }
    }
    restoring = false;
    restoreCfi = null;
    applyAppearance();
    el('prev-page').disabled = false;
    el('next-page').disabled = false;
    setText('reader-status', locationMessage);
    setText('engine-status', view.isFixedLayout ? '固定版面 EPUB 已載入' : 'EPUB 閱讀引擎已就緒');
  }
  async function loadDemo() {
    try {
      setText('reader-status', '正在載入內建測試 EPUB……');
      var response = await fetch('/demo/frame-reader-sample.epub', { cache: 'no-store' });
      if (!response.ok) throw new Error('測試書讀取失敗：HTTP ' + response.status);
      await openEpub(await response.blob(), 'FRAME Reader 測試小書');
    } catch (error) {
      setText('engine-status', '載入失敗');
      setText('reader-status', '錯誤：' + (error && error.message ? error.message : String(error)));
      console.error(error);
    }
  }
  function featureSummary() {
    var features = [
      ['Custom Elements', !!window.customElements],
      ['Shadow DOM', !!(window.Element && Element.prototype.attachShadow)],
      ['ResizeObserver', !!window.ResizeObserver],
      ['matchMedia', typeof window.matchMedia === 'function'],
      ['Blob.arrayBuffer', !!(window.Blob && Blob.prototype.arrayBuffer)],
      ['JSZip', !!window.JSZip]
    ];
    var missing = features.filter(function (item) { return !item[1]; }).map(function (item) { return item[0]; });
    return missing.length ? '相容性提示：未檢出 ' + missing.join('、') : '閱讀引擎基礎 API 已檢出';
  }

  loadAppearance();
  el('font-scale').addEventListener('change', function (event) { setAppearance('fontScale', event.target.value); });
  el('line-height').addEventListener('change', function (event) { setAppearance('lineHeight', event.target.value); });
  el('vertical-margin').addEventListener('change', function (event) { setAppearance('verticalMargin', event.target.value); });
  el('horizontal-margin').addEventListener('change', function (event) { setAppearance('horizontalMargin', event.target.value); });
  el('font-family').addEventListener('change', function (event) { setAppearance('fontFamily', event.target.value); });
  el('font-weight').addEventListener('change', function (event) { setAppearance('fontWeight', event.target.value); });
  el('paragraph-spacing').addEventListener('change', function (event) { setAppearance('paragraphSpacing', event.target.value); });
  el('text-align').addEventListener('change', function (event) { setAppearance('textAlign', event.target.value); });
  Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
    button.addEventListener('click', function () { setAppearance('theme', button.getAttribute('data-theme')); });
  });
  el('load-demo').addEventListener('click', loadDemo);
  el('epub-file').addEventListener('change', function (event) {
    var file = event.target.files && event.target.files[0];
    if (!file) return;
    openEpub(file, file.name).then(function () {
      setText('engine-status', '本機 EPUB 已載入');
    }).catch(function (error) {
      setText('engine-status', '解析失敗');
      setText('reader-status', '錯誤：' + (error && error.message ? error.message : String(error)));
      console.error(error);
    });
  });
  el('prev-page').addEventListener('click', function () {
    if (view) view.prev().catch(function (error) { console.error(error); });
  });
  el('next-page').addEventListener('click', function () {
    if (view) view.next().catch(function (error) { console.error(error); });
  });
  el('toc-select').addEventListener('change', function (event) {
    if (view && event.target.value) view.goTo(event.target.value).catch(function (error) { console.error(error); });
  });
  setText('engine-status', featureSummary());
  import('/vendor/foliate-js/view.js').then(function () {
    setText('engine-status', featureSummary() + ' · Foliate ready');
    loadDemo();
  }).catch(function (error) {
    setText('engine-status', '閱讀引擎無法載入');
    setText('reader-status', '瀏覽器相容性錯誤：' + (error && error.message ? error.message : String(error)));
    console.error(error);
  });
}());
