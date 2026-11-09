/* ES5-only compatibility probe for older e-ink browsers. */
(function () {
  var pages = [
    { title: '閱讀，不必追趕時間', body: [
      '這是一段用來測試 Kindle 網頁排版的文字。真正的電子書閱讀器需要在有限的螢幕尺寸上，清楚呈現段落、標題、行距與頁面邊界。',
      '請點擊下方的「下一頁」。如果文字順利切換，代表基本的 JavaScript 互動可以正常工作。'
    ]},
    { title: '第二頁：翻頁反應', body: [
      '電子墨水螢幕的刷新速度與一般 LCD 不同。閱讀介面應避免動畫、頻繁重排和不必要的背景效果。',
      '這一頁用來確認按鈕點擊事件是否可靠，以及頁面內容能否在舊版瀏覽器中更新。'
    ]},
    { title: '第三頁：保存閱讀位置', body: [
      '閱讀器需要記住書籍、章節與段落位置。這個測試會嘗試將頁碼保存在瀏覽器的本機儲存空間。',
      '重新整理頁面後，如果仍然回到同一頁，就代表本機進度保存正常。這還不是跨設備同步。'
    ]},
    { title: '第四頁：網頁閱讀的邊界', body: [
      '正式版本還需要測試 EPUB 章節載入、字體設定、目錄跳轉、網路中斷後的恢復，以及 Cloudflare 登入流程。',
      '本頁不會讀取私人書庫，也不會把測試結果傳送到任何伺服器。'
    ]}
  ];

  var currentPage = 0;
  var storageKey = 'frame-reader-kindle-test-page';
  var moduleSupported = false;
  var moduleProbeReady = false;

  function byId(id) { return document.getElementById(id); }
  function safeGet(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
  }
  function safeSet(key, value) {
    try { window.localStorage.setItem(key, value); return true; } catch (e) { return false; }
  }
  function setText(id, value) {
    var node = byId(id);
    if (node) { node.textContent = value; }
  }
  function renderPage() {
    var p = pages[currentPage];
    var box = byId('sample-page');
    var html = '<p class="chapter-label">FRAME READER · 測試章節</p>';
    var i;
    html += '<h3>' + p.title + '</h3>';
    for (i = 0; i < p.body.length; i++) { html += '<p>' + p.body[i] + '</p>'; }
    box.innerHTML = html;
    setText('page-count', '第 ' + (currentPage + 1) + ' / ' + pages.length + ' 頁');
    if (safeSet(storageKey, String(currentPage))) {
      setText('save-status', '已將第 ' + (currentPage + 1) + ' 頁保存到這台設備。重新整理可測試是否記住位置。');
    } else {
      setText('save-status', '本機儲存不可用，翻頁正常但無法保存測試進度。');
    }
    byId('prev-page').disabled = currentPage === 0;
    byId('next-page').disabled = currentPage === pages.length - 1;
  }
  function addRow(container, name, value, state) {
    var row = document.createElement('div');
    var nameNode = document.createElement('span');
    var valueNode = document.createElement('span');
    row.className = 'test-row';
    nameNode.className = 'test-name';
    valueNode.className = 'test-value ' + state;
    nameNode.appendChild(document.createTextNode(name));
    valueNode.appendChild(document.createTextNode(value));
    row.appendChild(nameNode);
    row.appendChild(valueNode);
    container.appendChild(row);
  }
  function checkCookie() {
    try {
      document.cookie = 'frame_reader_probe=1; path=/; SameSite=Lax';
      var ok = document.cookie.indexOf('frame_reader_probe=1') !== -1;
      document.cookie = 'frame_reader_probe=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/';
      return ok;
    } catch (e) { return false; }
  }
  function checkSessionStorage() {
    try {
      var key = 'frame-reader-session-probe';
      window.sessionStorage.setItem(key, 'ok');
      var ok = window.sessionStorage.getItem(key) === 'ok';
      window.sessionStorage.removeItem(key);
      return ok;
    } catch (e) { return false; }
  }
  function checkStorage() {
    var key = 'frame-reader-storage-probe';
    if (!safeSet(key, 'ok')) { return false; }
    var ok = safeGet(key) === 'ok';
    try { window.localStorage.removeItem(key); } catch (e) {}
    return ok;
  }
  function runTests() {
    var target = byId('test-results');
    var tests = [
      ['JavaScript 執行', true],
      ['DOM 事件監聽', !!document.addEventListener],
      ['Cookies', checkCookie()],
      ['localStorage', checkStorage()],
      ['sessionStorage', checkSessionStorage()],
      ['XMLHttpRequest', !!window.XMLHttpRequest],
      ['fetch API', !!window.fetch],
      ['Promise', !!window.Promise],
      ['ES Modules', moduleSupported],
      ['ArrayBuffer / Uint8Array', !!window.ArrayBuffer && !!window.Uint8Array],
      ['Blob / FileReader', !!window.Blob && !!window.FileReader],
      ['IndexedDB', !!window.indexedDB],
      ['Web Crypto', !!(window.crypto && window.crypto.subtle)],
      ['觸控事件', ('ontouchstart' in window) || (navigator.maxTouchPoints > 0)],
      ['CSS Flexbox', !!(window.CSS && window.CSS.supports && window.CSS.supports('display', 'flex'))],
      ['CSS Grid', !!(window.CSS && window.CSS.supports && window.CSS.supports('display', 'grid'))]
    ];
    var i;
    target.innerHTML = '';
    for (i = 0; i < tests.length; i++) {
      var ok = tests[i][1];
      var state = ok ? 'pass' : 'warn';
      var value = ok ? '可用' : '未檢出';
      if (tests[i][0] === 'ES Modules' && !moduleProbeReady) { value = '等待檢查'; state = 'warn'; }
      addRow(target, tests[i][0], value, state);
    }
    setText('user-agent', navigator.userAgent || '瀏覽器未提供 User-Agent');
    setText('screen-size', String(window.innerWidth || document.documentElement.clientWidth) + ' × ' +
      String(window.innerHeight || document.documentElement.clientHeight) + ' CSS px；螢幕 ' +
      String(screen.width) + ' × ' + String(screen.height));
    testNetwork();
  }
  function testNetwork() {
    var xhr;
    try {
      xhr = new XMLHttpRequest();
      xhr.open('GET', '/health.json?probe=' + new Date().getTime(), true);
      xhr.onreadystatechange = function () {
        if (xhr.readyState === 4) {
          var ok = xhr.status >= 200 && xhr.status < 300;
          addRow(byId('test-results'), '同網域 HTTPS / XHR',
            ok ? '成功 (' + xhr.status + ')' : '失敗 (' + xhr.status + ')',
            ok ? 'pass' : 'fail');
        }
      };
      xhr.onerror = function () {
        addRow(byId('test-results'), '同網域 HTTPS / XHR', '網路錯誤', 'fail');
      };
      xhr.send(null);
    } catch (e) {
      addRow(byId('test-results'), '同網域 HTTPS / XHR', '無法啟動', 'fail');
    }
  }
  function restorePage() {
    var value = parseInt(safeGet(storageKey), 10);
    if (!isNaN(value) && value >= 0 && value < pages.length) { currentPage = value; }
    renderPage();
  }

  byId('prev-page').onclick = function () {
    if (currentPage > 0) { currentPage--; renderPage(); }
  };
  byId('next-page').onclick = function () {
    if (currentPage < pages.length - 1) { currentPage++; renderPage(); }
  };
  byId('run-tests').onclick = runTests;
  restorePage();
  runTests();

  window.setTimeout(function () {
    moduleProbeReady = true;
    moduleSupported = window.FRAME_READER_MODULE_OK === true;
    runTests();
  }, 1200);
}());
