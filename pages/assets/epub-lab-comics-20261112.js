/* FRAME Reader Reading Room — Foliate.js adapter.
 * The archive is loaded fully into memory by JSZip for this small prototype.
 * Reading appearance settings are local to this browser.
 */
(function () {
  'use strict';
  var view = null;
  var currentStorageKey = null;
  var currentIndexStorageKey = null;
  var restoreCfi = null;
  var restorePageIndex = null;
  var restoring = false;
  var currentBookId = null;
  var currentAppearanceKey = null;
  var progressSaveTimer = null;
  var pendingProgress = null;
  var pendingProgressBookId = null;
  var libraryStorePromise = import('/assets/library-store.js');
  var APPEARANCE_KEY = 'frame-reader-appearance-v1';
  currentAppearanceKey = APPEARANCE_KEY;
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
    readingMode: 'paginated',
    pageLayout: '2',
    comicReadingMode: 'paginated',
    comicPageLayout: '2',
    comicImageFit: 'fit-page',
    backdrop: 'wood',
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
  async function flushLibraryProgress() {
    if (progressSaveTimer) {
      clearTimeout(progressSaveTimer);
      progressSaveTimer = null;
    }
    if (!pendingProgress || !pendingProgressBookId) return;
    var bookId = pendingProgressBookId;
    var patch = pendingProgress;
    pendingProgress = null;
    pendingProgressBookId = null;
    try {
      var store = await libraryStorePromise;
      var book = await store.getBook(bookId);
      if (book) {
        await store.updateBook(bookId, {
          progress: Object.assign({}, book.progress || {}, patch),
          lastOpenedAt: Date.now()
        });
      }
    } catch (error) {
      console.warn('FRAME Reader could not save local progress:', error);
    }
  }
  function queueLibraryProgress(patch) {
    if (!currentBookId) return;
    pendingProgressBookId = currentBookId;
    pendingProgress = Object.assign({}, pendingProgress || {}, patch);
    if (progressSaveTimer) clearTimeout(progressSaveTimer);
    progressSaveTimer = setTimeout(function () {
      flushLibraryProgress();
    }, 350);
  }
  function updateLocation(detail) {
    if (!detail) return;
    var progressPatch = {};
    if (typeof detail.fraction === 'number' && isFinite(detail.fraction)) {
      var percent = Math.max(0, Math.min(100, Math.round(detail.fraction * 100)));
      setText('progress-percent', percent + '%');
      var section = detail.section;
      var label = section && section.total
        ? '章節 ' + (section.current + 1) + ' / ' + section.total
        : (typeof detail.index === 'number' ? '第 ' + (detail.index + 1) + ' 頁' : '閱讀位置已更新');
      setText('progress-detail', label);
      progressPatch.percent = percent;
      progressPatch.label = label;
    }
    if (detail.cfi && currentStorageKey && !restoring) {
      if (safeSet(currentStorageKey, detail.cfi)) setText('reader-status', '閱讀位置已保存在這台設備。跨設備同步尚未啟用。');
      else setText('reader-status', '瀏覽器不允許保存本機閱讀位置。');
      progressPatch.cfi = detail.cfi;
    }
    if (typeof detail.index === 'number' && currentIndexStorageKey && !restoring) {
      safeSet(currentIndexStorageKey, String(detail.index));
      progressPatch.index = detail.index;
    }
    if (Object.keys(progressPatch).length) queueLibraryProgress(progressPatch);
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
    Object.assign(appearance, {
      fontScale: '1', lineHeight: '1.65', verticalMargin: '16', horizontalMargin: '7',
      fontFamily: 'original', fontWeight: 'original', paragraphSpacing: 'original', textAlign: 'original',
      readingMode: 'paginated', pageLayout: '2', comicReadingMode: 'paginated',
      comicPageLayout: '2', comicImageFit: 'fit-page', backdrop: 'wood', theme: 'paper'
    });
    var saved = safeGet(currentAppearanceKey || APPEARANCE_KEY);
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
          if (['paginated', 'scrolled'].indexOf(String(value.readingMode)) !== -1) appearance.readingMode = String(value.readingMode);
          if (['1', '2'].indexOf(String(value.pageLayout)) !== -1) appearance.pageLayout = String(value.pageLayout);
          if (['paginated', 'scrolled'].indexOf(String(value.comicReadingMode)) !== -1) appearance.comicReadingMode = String(value.comicReadingMode);
          if (['1', '2'].indexOf(String(value.comicPageLayout)) !== -1) appearance.comicPageLayout = String(value.comicPageLayout);
          if (['fit-page', 'fit-width'].indexOf(String(value.comicImageFit)) !== -1) appearance.comicImageFit = String(value.comicImageFit);
          if (['wood', 'linen', 'slate'].indexOf(String(value.backdrop)) !== -1) appearance.backdrop = String(value.backdrop);
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
    el('reading-mode').value = appearance.readingMode;
    el('page-layout').value = appearance.pageLayout;
    el('comic-reading-mode').value = appearance.comicReadingMode;
    el('comic-page-layout').value = appearance.comicPageLayout;
    el('comic-image-fit').value = appearance.comicImageFit;
    updateThemeButtons();
    updateBackdropButtons();
    updateLayoutControlState();
  }
  function saveAppearance() {
    var ok = safeSet(currentAppearanceKey || APPEARANCE_KEY, JSON.stringify(appearance));
    setText('appearance-status', ok
      ? '外觀設定已保存在這台設備；其他設備尚未同步。'
      : '瀏覽器未允許本機儲存，這次設定不會保留。');
  }
  function updateThemeButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
      button.setAttribute('aria-pressed', button.getAttribute('data-theme') === appearance.theme ? 'true' : 'false');
    });
  }
  function updateBackdropButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-backdrop]'), function (button) {
      button.setAttribute('aria-pressed', button.getAttribute('data-backdrop') === appearance.backdrop ? 'true' : 'false');
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
  function updateReadingModeNote() {
    var note = el('reading-mode-note');
    if (!note) return;
    if (view && view.isFixedLayout) {
      if (appearance.comicReadingMode === 'scrolled') {
        note.textContent = '直式長卷：圖片依螢幕寬度垂直串接，接近可視區時才載入頁面。';
      } else if (appearance.comicPageLayout === '2') {
        note.textContent = '雙頁優先：桌面與平板橫向呈現跨頁，手機直向自動切回單頁。';
      } else {
        note.textContent = '單頁翻頁：所有裝置一次顯示一頁，適合逐頁閱讀。';
      }
    } else if (!view) {
      note.textContent = '圖像閱讀設定會在載入 CBZ 或固定版面 EPUB 後啟用。';
    } else if (appearance.readingMode === 'scrolled') {
      note.textContent = '連續捲動模式；頁面欄數與上下留白會在切回分頁時恢復。';
    } else if (appearance.pageLayout === '2') {
      note.textContent = '雙頁優先：橫向寬螢幕呈現雙頁，直向畫面自動切回單頁。';
    } else {
      note.textContent = '單頁翻頁模式，適合窄螢幕或逐頁專注閱讀。';
    }
  }
  function updateLayoutControlState() {
    var fixed = !!(view && view.isFixedLayout);
    el('reading-mode').disabled = fixed;
    el('page-layout').disabled = fixed;
    el('comic-reading-mode').disabled = !fixed;
    el('comic-page-layout').disabled = !fixed;
    el('comic-image-fit').disabled = !fixed || appearance.comicReadingMode === 'scrolled';
    updateReadingModeNote();
  }
  function applyAppearance() {
    var theme = THEMES[appearance.theme];
    var viewport = el('reader-viewport');
    viewport.dataset.theme = appearance.theme;
    viewport.dataset.backdrop = appearance.backdrop;
    viewport.dataset.comicFlow = appearance.comicReadingMode;
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
      if (appearance.readingMode === 'scrolled') {
        view.renderer.setAttribute('flow', 'scrolled');
      } else {
        view.renderer.removeAttribute('flow');
      }
      view.renderer.setAttribute('max-column-count', appearance.pageLayout);
      try {
        view.renderer.getContents().forEach(function (item) {
          applyDocumentAppearance(item.doc);
        });
      } catch (e) {}
      if (typeof view.renderer.render === 'function') {
        view.renderer.render();
      }
    } else if (view && view.renderer && view.isFixedLayout) {
      if (typeof view.renderer.setPageLayout === 'function') {
        Promise.resolve(view.renderer.setPageLayout(appearance.comicPageLayout)).catch(console.error);
      }
      if (typeof view.renderer.setFlow === 'function') {
        view.renderer.setFlow(appearance.comicReadingMode);
      }
      view.renderer.setAttribute('zoom', appearance.comicImageFit);
    }
    updateThemeButtons();
    updateBackdropButtons();
    updateReadingModeNote();
  }
  function setAppearance(name, value) {
    appearance[name] = String(value);
    saveAppearance();
    applyAppearance();
    updateLayoutControlState();
  }
  async function openEpub(source, name, bookId) {
    await flushLibraryProgress();
    if (!window.JSZip) throw new Error('JSZip 尚未載入，請重新整理頁面。');
    setText('reader-status', '正在讀取書籍封裝與目錄……');
    setText('engine-status', '正在解析書籍');
    el('prev-page').disabled = true;
    el('next-page').disabled = true;
    el('toc-select').disabled = true;
    var isCbz = /\.cbz$/i.test(String(source && source.name || name || ''));
    var parsedBook;
    if (isCbz) {
      await import('/vendor/foliate-js/view.js');
    } else {
      var zip = await window.JSZip.loadAsync(source, { checkCRC32: false });
      var epubModule = await import('/vendor/foliate-js/epub.js');
      parsedBook = await new epubModule.EPUB(makeLoader(zip)).init();
    }
    if (view) { try { view.close(); } catch (e) {} }
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
    await view.open(isCbz ? source : parsedBook);
    parsedBook = view.book;

    var metadata = parsedBook.metadata || {};
    currentBookId = bookId || null;
    currentAppearanceKey = currentBookId ? APPEARANCE_KEY + ':' + currentBookId : APPEARANCE_KEY;
    if (currentBookId) {
      window.history.replaceState(null, '', '/epub-lab/?book=' + encodeURIComponent(currentBookId));
    } else {
      window.history.replaceState(null, '', '/epub-lab/');
    }
    loadAppearance();
    var libraryStore = await libraryStorePromise;
    var libraryRecord = currentBookId ? await libraryStore.getBook(currentBookId) : null;
    var identifier = currentBookId || metadata.identifier || name || 'sample';
    currentStorageKey = view.isFixedLayout ? null : 'frame-reader-epub-cfi:' + String(identifier);
    currentIndexStorageKey = view.isFixedLayout
      ? 'frame-reader-fixed-index:' + String(identifier)
      : null;
    restoreCfi = currentStorageKey ? safeGet(currentStorageKey) : null;
    var storedIndex = currentIndexStorageKey ? Number(safeGet(currentIndexStorageKey)) : NaN;
    var savedProgress = libraryRecord && libraryRecord.progress ? libraryRecord.progress : {};
    if (!restoreCfi && !view.isFixedLayout && savedProgress.cfi) restoreCfi = savedProgress.cfi;
    if ((!Number.isInteger(storedIndex) || storedIndex < 0) && Number.isInteger(savedProgress.index)) {
      storedIndex = savedProgress.index;
    }
    restorePageIndex = Number.isInteger(storedIndex) && storedIndex >= 0 ? storedIndex : null;
    restoring = !!restoreCfi || restorePageIndex !== null;
    setText('book-title', (libraryRecord && libraryRecord.title) || titleText(metadata.title) || name);
    setText('book-author', (libraryRecord && libraryRecord.author) || titleText(metadata.author) || (isCbz ? '漫畫圖像檔' : (name || 'EPUB 測試書')));
    populateTOC(parsedBook.toc || []);
    if (libraryRecord) {
      await libraryStore.updateBook(currentBookId, { lastOpenedAt: Date.now() });
    }

    if (view.isFixedLayout) {
      if (typeof view.renderer.setPageLayout === 'function') {
        await view.renderer.setPageLayout(appearance.comicPageLayout);
      }
      view.renderer.setAttribute('zoom', appearance.comicImageFit);
      if (typeof view.renderer.setFlow === 'function') {
        view.renderer.setFlow(appearance.comicReadingMode);
      }
    }

    var locationMessage = isCbz
      ? 'CBZ 漫畫已載入。可使用翻頁按鈕、章節目錄或直式長卷模式。'
      : 'EPUB 已載入。可使用翻頁按鈕或章節目錄。';
    try {
      if (restoreCfi) {
        await view.init({ lastLocation: restoreCfi, showTextStart: true });
        locationMessage = '已恢復這本書上次的閱讀位置。此位置目前只存在本機。';
      } else {
        await view.init({ showTextStart: true });
        if (restorePageIndex !== null && view.isFixedLayout) {
          await view.goTo(Math.min(restorePageIndex, parsedBook.sections.length - 1));
          locationMessage = '已恢復圖像書籍上次的閱讀頁面。此位置目前只存在本機。';
        }
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
    restorePageIndex = null;
    updateLayoutControlState();
    applyAppearance();
    el('prev-page').disabled = false;
    el('next-page').disabled = false;
    setText('reader-status', locationMessage);
    setText('engine-status', isCbz
      ? 'CBZ 漫畫閱讀引擎已就緒'
      : (view.isFixedLayout ? '固定版面 EPUB 已載入' : 'EPUB 閱讀引擎已就緒'));
  }
  async function loadComicDemo() {
    try {
      setText('reader-status', '正在製作原創漫畫測試檔……');
      var zip = new window.JSZip();
      var pages = [
        { name: '00-cover.svg', title: '紙上星河', subtitle: 'FRAME READER · COMIC TEST', mood: '#27213a', accent: '#c6a4ff' },
        { name: '01-page.svg', title: '第一頁 · 夜色', subtitle: '城市的燈，逐格亮起。', mood: '#24394a', accent: '#9dd7e6' },
        { name: '02-page.svg', title: '第二頁 · 回聲', subtitle: '有些故事，從翻頁才開始。', mood: '#453044', accent: '#f3b5c8' },
        { name: '03-page.svg', title: '第三頁 · 清晨', subtitle: '天亮以前，還有一頁。', mood: '#66503b', accent: '#f4d28c' }
      ];
      pages.forEach(function (page, index) {
        var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="900" height="1280" viewBox="0 0 900 1280">' +
          '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="' + page.mood + '"/><stop offset="1" stop-color="#11101b"/></linearGradient></defs>' +
          '<rect width="900" height="1280" fill="#f5efe5"/><rect x="34" y="34" width="832" height="1212" rx="9" fill="url(#g)"/>' +
          '<path d="M80 240 C240 120 330 360 470 220 S700 100 820 270" fill="none" stroke="' + page.accent + '" stroke-width="5" opacity=".65"/>' +
          '<circle cx="' + (230 + index * 120) + '" cy="' + (450 + index * 35) + '" r="' + (112 + index * 8) + '" fill="' + page.accent + '" opacity=".13"/>' +
          '<rect x="105" y="610" width="690" height="390" rx="12" fill="#11101b" opacity=".34" stroke="' + page.accent + '" stroke-width="3"/>' +
          '<path d="M145 910 L300 740 L440 875 L580 690 L750 900" fill="none" stroke="' + page.accent + '" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>' +
          '<text x="105" y="155" fill="' + page.accent + '" font-size="24" letter-spacing="6" font-family="sans-serif">' + page.subtitle + '</text>' +
          '<text x="105" y="1100" fill="#fffaf2" font-size="' + (index === 0 ? '72' : '54') + '" font-weight="700" font-family="sans-serif">' + page.title + '</text>' +
          '<text x="105" y="1170" fill="#d9cce9" font-size="20" letter-spacing="5" font-family="sans-serif">FRAME · ORIGINAL DEMO PAGE ' + (index + 1) + '</text>' +
          '</svg>';
        zip.file(page.name, svg);
      });
      var blob = await zip.generateAsync({ type: 'blob', compression: 'STORE' });
      var file = new File([blob], 'FRAME Reader Comic Demo.cbz', { type: 'application/vnd.comicbook+zip' });
      var store = await libraryStorePromise;
      var record = await store.importBookFile(file);
      await openEpub(file, file.name, record.id);
      setText('reader-status', '原創漫畫示範已加入本機書架。可切換單頁、雙頁與直式長卷。');
    } catch (error) {
      setText('engine-status', '漫畫示範載入失敗');
      setText('reader-status', '錯誤：' + (error && error.message ? error.message : String(error)));
      console.error(error);
    }
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
  el('reading-mode').addEventListener('change', function (event) { setAppearance('readingMode', event.target.value); });
  el('page-layout').addEventListener('change', function (event) { setAppearance('pageLayout', event.target.value); });
  el('comic-reading-mode').addEventListener('change', function (event) { setAppearance('comicReadingMode', event.target.value); });
  el('comic-page-layout').addEventListener('change', function (event) { setAppearance('comicPageLayout', event.target.value); });
  el('comic-image-fit').addEventListener('change', function (event) { setAppearance('comicImageFit', event.target.value); });
  Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
    button.addEventListener('click', function () { setAppearance('theme', button.getAttribute('data-theme')); });
  });
  Array.prototype.forEach.call(document.querySelectorAll('[data-backdrop]'), function (button) {
    button.addEventListener('click', function () { setAppearance('backdrop', button.getAttribute('data-backdrop')); });
  });
  el('load-demo').addEventListener('click', loadDemo);
  el('load-comic-demo').addEventListener('click', loadComicDemo);
  el('epub-file').addEventListener('change', function (event) {
    var file = event.target.files && event.target.files[0];
    if (!file) return;
    (async function () {
      var store = await libraryStorePromise;
      var record = await store.importBookFile(file);
      await openEpub(file, file.name, record.id);
      setText('engine-status', '本機書籍已加入書架');
      setText('reader-status', '已加入本機書架。檔案與閱讀記錄只保存在這台設備。');
    }()).catch(function (error) {
      setText('engine-status', '解析或匯入失敗');
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
  window.addEventListener('pagehide', function () { flushLibraryProgress(); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) flushLibraryProgress();
  });
  setText('engine-status', featureSummary());
  import('/vendor/foliate-js/view.js').then(async function () {
    setText('engine-status', featureSummary() + ' · Foliate ready');
    var bookId = new URLSearchParams(window.location.search).get('book');
    if (bookId) {
      var store = await libraryStorePromise;
      var record = await store.getBook(bookId);
      if (!record || !record.blob) throw new Error('找不到這本本機書籍。請回到書架確認檔案是否仍存在。');
      await openEpub(record.blob, record.fileName, record.id);
    } else {
      loadDemo();
    }
  }).catch(function (error) {
    setText('engine-status', '書籍或閱讀引擎載入失敗');
    setText('reader-status', '錯誤：' + (error && error.message ? error.message : String(error)));
    console.error(error);
  });
}());
