/* FRAME Reader local library store.
 * Book archives and metadata stay in this browser's IndexedDB.
 * Nothing in this module uploads book content to a remote service.
 */
const DB_NAME = "frame-reader-library";
const DB_VERSION = 2;
const STORE_NAME = "books";
let databasePromise;

function openDatabase() {
  if (databasePromise) return databasePromise;
  databasePromise = new Promise((resolve, reject) => {
    if (!("indexedDB" in window)) {
      reject(new Error("這個瀏覽器不支援 IndexedDB，無法建立本機書庫。"));
      return;
    }
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        const store = db.createObjectStore(STORE_NAME, { keyPath: "id" });
        store.createIndex("addedAt", "addedAt", { unique: false });
        store.createIndex("lastOpenedAt", "lastOpenedAt", { unique: false });
        store.createIndex("title", "title", { unique: false });
      }
      if (!db.objectStoreNames.contains("reading_events")) {
        const events = db.createObjectStore("reading_events", { keyPath: "id" });
        events.createIndex("dayKey", "dayKey", { unique: false });
        events.createIndex("bookId", "bookId", { unique: false });
        events.createIndex("endedAt", "endedAt", { unique: false });
        events.createIndex("synced", "synced", { unique: false });
      }
      if (!db.objectStoreNames.contains("reading_settings")) {
        db.createObjectStore("reading_settings", { keyPath: "key" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("無法開啟本機書庫。"));
    request.onblocked = () => reject(new Error("書庫正在被另一個分頁更新，請關閉其他 FRAME Reader 分頁後重試。"));
  });
  return databasePromise;
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("本機書庫操作失敗。"));
  });
}

function transactionDone(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error("本機書庫交易失敗。"));
    tx.onabort = () => reject(tx.error || new Error("本機書庫交易已中止。"));
  });
}

async function readAll() {
  const db = await openDatabase();
  const tx = db.transaction(STORE_NAME, "readonly");
  return requestResult(tx.objectStore(STORE_NAME).getAll());
}

async function getBook(id) {
  if (!id) return null;
  const db = await openDatabase();
  const tx = db.transaction(STORE_NAME, "readonly");
  return (await requestResult(tx.objectStore(STORE_NAME).get(String(id)))) || null;
}

async function writeRecord(record) {
  const db = await openDatabase();
  const tx = db.transaction(STORE_NAME, "readwrite");
  const completed = transactionDone(tx);
  const request = tx.objectStore(STORE_NAME).put(record);
  await requestResult(request);
  await completed;
  return record;
}

function makeId() {
  if (window.crypto && typeof window.crypto.randomUUID === "function") return window.crypto.randomUUID();
  const values = new Uint32Array(4);
  if (window.crypto && window.crypto.getRandomValues) window.crypto.getRandomValues(values);
  else for (let i = 0; i < values.length; i++) values[i] = Math.floor(Math.random() * 0xffffffff);
  return Array.from(values).map(value => value.toString(16).padStart(8, "0")).join("-");
}

function basename(name) {
  return String(name || "").split(/[\\/]/).pop().replace(/\.(epub|cbz)$/i, "").trim();
}

function normalizePath(path) {
  const parts = [];
  String(path || "").replace(/\\/g, "/").split("/").forEach(part => {
    if (!part || part === ".") return;
    if (part === "..") parts.pop();
    else parts.push(part);
  });
  return parts.join("/");
}

function findText(node, localName) {
  if (!node) return "";
  const items = node.getElementsByTagName("*");
  for (let i = 0; i < items.length; i++) {
    if (String(items[i].localName || items[i].nodeName).toLowerCase() === localName.toLowerCase()) {
      const value = (items[i].textContent || "").trim();
      if (value) return value;
    }
  }
  return "";
}

function mimeFromName(name) {
  const extension = String(name).split(".").pop().toLowerCase();
  const types = {
    jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", webp: "image/webp",
    gif: "image/gif", svg: "image/svg+xml", avif: "image/avif", bmp: "image/bmp"
  };
  return types[extension] || "application/octet-stream";
}

async function inspectEpub(file) {
  if (!window.JSZip) throw new Error("EPUB 解析模組尚未載入，請重新整理後再試。");
  const zip = await window.JSZip.loadAsync(file, { checkCRC32: false });
  const containerEntry = zip.file("META-INF/container.xml");
  if (!containerEntry) throw new Error("這個 EPUB 缺少 META-INF/container.xml。");
  const containerXml = new DOMParser().parseFromString(await containerEntry.async("string"), "application/xml");
  const rootfiles = containerXml.getElementsByTagName("rootfile");
  if (!rootfiles.length) throw new Error("找不到 EPUB 的 OPF 書籍資訊。");
  const opfPath = normalizePath(rootfiles[0].getAttribute("full-path"));
  const opfEntry = zip.file(opfPath);
  if (!opfEntry) throw new Error("找不到 EPUB 封裝資訊檔：" + opfPath);
  const opfXml = new DOMParser().parseFromString(await opfEntry.async("string"), "application/xml");
  if (opfXml.getElementsByTagName("parsererror").length) throw new Error("EPUB 書籍資訊格式無法解析。");

  const metadataNode = opfXml.getElementsByTagName("metadata")[0] || opfXml;
  const title = findText(metadataNode, "title") || basename(file.name) || "未命名 EPUB";
  const author = findText(metadataNode, "creator");
  const language = findText(metadataNode, "language");
  const identifier = findText(metadataNode, "identifier");
  const spine = opfXml.getElementsByTagName("spine")[0];
  const pageCount = spine ? spine.getElementsByTagName("itemref").length : 0;

  const manifest = Array.from(opfXml.getElementsByTagName("item"));
  let coverItem = null;
  let coverId = "";
  const metaItems = Array.from(opfXml.getElementsByTagName("meta"));
  for (const item of metaItems) {
    if (String(item.getAttribute("name")).toLowerCase() === "cover") {
      coverId = item.getAttribute("content") || "";
      break;
    }
  }
  if (coverId) coverItem = manifest.find(item => item.getAttribute("id") === coverId) || null;
  if (!coverItem) coverItem = manifest.find(item => (item.getAttribute("properties") || "").split(/\s+/).includes("cover-image")) || null;
  if (!coverItem) coverItem = manifest.find(item => /^image\//i.test(item.getAttribute("media-type") || "") && /cover|front/i.test(item.getAttribute("href") || "")) || null;

  let coverBlob = null;
  if (coverItem) {
    const opfDirectory = opfPath.includes("/") ? opfPath.slice(0, opfPath.lastIndexOf("/") + 1) : "";
    const coverPath = normalizePath(opfDirectory + coverItem.getAttribute("href"));
    const coverEntry = zip.file(coverPath);
    if (coverEntry) {
      const blob = await coverEntry.async("blob");
      if (blob.size > 0 && blob.size <= 12 * 1024 * 1024) {
        coverBlob = new Blob([blob], { type: coverItem.getAttribute("media-type") || mimeFromName(coverPath) });
      }
    }
  }
  return { title, author, language, identifier, pageCount, coverBlob };
}

async function inspectCbz(file) {
  if (!window.JSZip) throw new Error("CBZ 索引模組尚未載入，請重新整理後再試。");
  const zip = await window.JSZip.loadAsync(file, { checkCRC32: false });
  const images = Object.keys(zip.files).filter(path => {
    const entry = zip.files[path];
    return !entry.dir && /\.(jpe?g|png|webp|gif|svg|avif|bmp)$/i.test(path);
  }).sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" }));
  if (!images.length) throw new Error("這個 CBZ 封存檔裡沒有可讀取的圖片。");
  const coverPath = images.find(path => /(^|[/_-])(cover|front)([/_.-]|$)/i.test(path)) || images[0];
  const coverBlob = await zip.file(coverPath).async("blob");
  return {
    title: basename(file.name) || "未命名漫畫",
    author: "",
    language: "",
    identifier: "",
    pageCount: images.length,
    coverBlob: coverBlob.size <= 12 * 1024 * 1024 ? new Blob([coverBlob], { type: mimeFromName(coverPath) }) : null
  };
}

function quotaMessage(error) {
  if (error && (error.name === "QuotaExceededError" || error.name === "NS_ERROR_DOM_QUOTA_REACHED")) {
    return new Error("這台設備的瀏覽器儲存空間不足，書籍尚未加入。請先釋出瀏覽器空間或移除不需要的本機書籍。");
  }
  return error;
}

async function importBookFile(file, options = {}) {
  if (!(file instanceof Blob) || !file.name) throw new Error("請選擇有效的 EPUB 或 CBZ 檔案。");
  const extension = String(file.name).split(".").pop().toLowerCase();
  if (extension !== "epub" && extension !== "cbz") throw new Error("目前只支援 EPUB 與 CBZ。");
  if (file.size <= 0) throw new Error("這個檔案是空的。");

  const existing = (await readAll()).find(book =>
    book.fileName === file.name && book.size === file.size && Number(book.lastModified || 0) === Number(file.lastModified || 0)
  );
  const metadata = extension === "epub" ? await inspectEpub(file) : await inspectCbz(file);
  const now = Date.now();
  const requestedShelf = options && (options.shelf === "books" || options.shelf === "comics") ? options.shelf : "";
  const shelf = extension === "cbz" ? "comics" : (requestedShelf || (existing && existing.shelf === "comics" ? "comics" : "books"));
  const record = {
    id: existing ? existing.id : makeId(),
    fileName: file.name,
    title: existing && existing.manualTitle ? existing.title : (metadata.title || basename(file.name)),
    author: existing && existing.manualAuthor ? existing.author : (metadata.author || ""),
    language: metadata.language || "",
    identifier: metadata.identifier || "",
    format: extension.toUpperCase(),
    shelf,
    pageCount: Number(metadata.pageCount) || 0,
    size: file.size,
    lastModified: Number(file.lastModified) || 0,
    blob: file,
    coverBlob: metadata.coverBlob || (existing && existing.coverBlob) || null,
    addedAt: existing ? existing.addedAt : now,
    updatedAt: now,
    lastOpenedAt: existing ? existing.lastOpenedAt : 0,
    progress: existing && existing.progress ? existing.progress : { percent: 0, label: "尚未閱讀", cfi: "", index: null },
    manualTitle: existing ? !!existing.manualTitle : false,
    manualAuthor: existing ? !!existing.manualAuthor : false
  };
  try {
    await writeRecord(record);
  } catch (error) {
    throw quotaMessage(error);
  }
  return record;
}

async function updateBook(id, patch) {
  const current = await getBook(id);
  if (!current) return null;
  const updated = Object.assign({}, current, patch || {}, { updatedAt: Date.now() });
  try {
    return await writeRecord(updated);
  } catch (error) {
    throw quotaMessage(error);
  }
}

async function deleteBook(id) {
  const db = await openDatabase();
  const tx = db.transaction(STORE_NAME, "readwrite");
  const completed = transactionDone(tx);
  await requestResult(tx.objectStore(STORE_NAME).delete(String(id)));
  await completed;
  return true;
}

async function listBooks() {
  const books = await readAll();
  return books.sort((a, b) => (Number(b.lastOpenedAt) || 0) - (Number(a.lastOpenedAt) || 0) ||
    (Number(b.addedAt) || 0) - (Number(a.addedAt) || 0));
}



function localDayKey(timestamp) {
  const date = new Date(Number(timestamp) || Date.now());
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return year + "-" + month + "-" + day;
}

async function recordReadingEvent(event) {
  if (!event || !event.id || !event.dayKey || !event.bookId) throw new Error("閱讀事件缺少必要識別資訊。");
  const seconds = Math.max(0, Math.min(30, Math.round(Number(event.seconds) || 0)));
  if (!seconds) return false;
  const record = {
    id: String(event.id),
    dayKey: String(event.dayKey),
    bookId: String(event.bookId),
    bookTitle: String(event.bookTitle || "未命名書籍").slice(0, 240),
    format: String(event.format || "").toUpperCase().slice(0, 8),
    localHour: Math.max(0, Math.min(23, Number(event.localHour) || 0)),
    seconds,
    startedAt: Number(event.startedAt) || Date.now() - seconds * 1000,
    endedAt: Number(event.endedAt) || Date.now(),
    synced: false
  };
  const db = await openDatabase();
  const tx = db.transaction("reading_events", "readwrite");
  const completed = transactionDone(tx);
  tx.objectStore("reading_events").put(record);
  await completed;
  return record;
}

async function getReadingEvents(fromDay, toDay) {
  const db = await openDatabase();
  const tx = db.transaction("reading_events", "readonly");
  const index = tx.objectStore("reading_events").index("dayKey");
  const range = IDBKeyRange.bound(String(fromDay), String(toDay));
  return requestResult(index.getAll(range));
}

async function getPendingReadingEvents(limit = 100) {
  const db = await openDatabase();
  const tx = db.transaction("reading_events", "readonly");
  const store = tx.objectStore("reading_events");
  const index = store.index("synced");
  const rows = await requestResult(index.getAll(false, Math.max(1, Math.min(500, Number(limit) || 100))));
  return rows;
}

async function markReadingEventsSynced(ids) {
  const list = Array.isArray(ids) ? ids.map(String) : [];
  if (!list.length) return 0;
  const db = await openDatabase();
  const tx = db.transaction("reading_events", "readwrite");
  const completed = transactionDone(tx);
  const store = tx.objectStore("reading_events");
  for (const id of list) {
    const request = store.get(id);
    request.onsuccess = () => {
      if (request.result) store.put(Object.assign({}, request.result, { synced: true }));
    };
  }
  await completed;
  return list.length;
}

async function getReadingSetting(key, fallback = null) {
  const db = await openDatabase();
  const tx = db.transaction("reading_settings", "readonly");
  const row = await requestResult(tx.objectStore("reading_settings").get(String(key)));
  return row ? row.value : fallback;
}

async function setReadingSetting(key, value) {
  const db = await openDatabase();
  const tx = db.transaction("reading_settings", "readwrite");
  const completed = transactionDone(tx);
  tx.objectStore("reading_settings").put({ key: String(key), value });
  await completed;
  return value;
}

export { openDatabase, importBookFile, getBook, updateBook, deleteBook, listBooks, localDayKey, recordReadingEvent, getReadingEvents, getPendingReadingEvents, markReadingEventsSynced, getReadingSetting, setReadingSetting };
