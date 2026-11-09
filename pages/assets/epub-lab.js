/* FRAME Reader EPUB Lab — Foliate.js adapter.
 * The archive is loaded fully into memory by JSZip for this small prototype.
 */
(function () {
  'use strict';
  var view = null;
  var currentStorageKey = null;
  var restoreCfi = null;
  var restoring = false;
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
    view.addEventListener('relocate', function (event) {
      var detail = event.detail || {};
      updateLocation(detail);
      if (restoring && restoreCfi) {
        var target = restoreCfi;
        restoring = false;
        restoreCfi = null;
        view.goTo(target).then(function () {
          setText('reader-status', '已恢復這本書上次的閱讀位置。此位置目前只存在本機。');
        }).catch(function () {
          setText('reader-status', '已找到舊閱讀位置，但恢復失敗，先從目前章節繼續閱讀。');
        });
      }
    });
    viewport.appendChild(view);
    await view.open(parsedBook);
    el('prev-page').disabled = false;
    el('next-page').disabled = false;
    setText('reader-status', 'EPUB 已載入。可使用翻頁按鈕或章節目錄。');
    if (restoreCfi) {
      var target = restoreCfi;
      restoring = false;
      restoreCfi = null;
      try {
        await view.goTo(target);
        setText('reader-status', '已恢復這本書上次的閱讀位置。此位置目前只存在本機。');
      } catch (e) {
        setText('reader-status', '舊閱讀位置無法恢復，已從書籍開頭開始。');
      }
    }
    setText('engine-status', '引擎已載入');
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
    setText('engine-status', featureSummary() + ' · Foliate view ready');
    loadDemo();
  }).catch(function (error) {
    setText('engine-status', '閱讀引擎無法載入');
    setText('reader-status', '瀏覽器相容性錯誤：' + (error && error.message ? error.message : String(error)));
    console.error(error);
  });
}());
