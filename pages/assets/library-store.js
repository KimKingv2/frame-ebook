/* FRAME Reader local library store.
 * Book archives and metadata stay in this browser's IndexedDB.
 * Nothing in this module uploads book content to a remote service.
 */
const DB_NAME = "frame-reader-library";
const DB_VERSION = 3;
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
      if (!db.objectStoreNames.contains("annotations")) {
        const annotations = db.createObjectStore("annotations", { keyPath: "id" });
        annotations.createIndex("bookId", "bookId", { unique: false });
        annotations.createIndex("updatedAt", "updatedAt", { unique: false });
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
    book.sourceType !== "cloud" &&
    book.fileName === file.name &&
    book.size === file.size &&
    Number(book.lastModified || 0) === Number(file.lastModified || 0)
  );
  const metadata = extension === "epub" ? await inspectEpub(file) : await inspectCbz(file);
  const now = Date.now();
  const requestedShelf = options && (options.shelf === "books" || options.shelf === "comics") ? options.shelf : "";
  const shelf = extension === "cbz" ? "comics" : (requestedShelf || (existing && existing.shelf === "comics" ? "comics" : "books"));
  const record = {
    id: existing ? existing.id : makeId(),
    sourceType: "local",
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
  const tx = db.transaction([STORE_NAME, "annotations"], "readwrite");
  const completed = transactionDone(tx);
  tx.objectStore(STORE_NAME).delete(String(id));
  const annotationStore = tx.objectStore("annotations");
  const annotationIndex = annotationStore.index("bookId");
  const annotationRequest = annotationIndex.openKeyCursor(IDBKeyRange.only(String(id)));
  annotationRequest.onsuccess = () => {
    const cursor = annotationRequest.result;
    if (!cursor) return;
    annotationStore.delete(cursor.primaryKey);
    cursor.continue();
  };
  await completed;
  return true;
}

async function listBooks() {
  const books = await readAll();
  return books.sort((a, b) => (Number(b.lastOpenedAt) || 0) - (Number(a.lastOpenedAt) || 0) ||
    (Number(b.addedAt) || 0) - (Number(a.addedAt) || 0));
}

async function cloudBookId(scope, path) {
  const provider = String(scope?.provider || "");
  const library = String(scope?.library || "");
  const rootPath = normalizePath(scope?.rootPath || "");
  const filePath = normalizePath(path || "");
  if (!provider || !["books", "comics"].includes(library) || !rootPath || !filePath) {
    throw new Error("雲端書籍識別資訊無效。");
  }
  const identity = [provider, library, rootPath, filePath].join("\\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(identity));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return "cloud:" + hash;
}

async function upsertCloudBooks(scope, items, options = {}) {
  const source = {
    provider: String(scope?.provider || ""),
    library: String(scope?.library || ""),
    rootPath: normalizePath(scope?.rootPath || "")
  };
  if (!source.provider || !["books", "comics"].includes(source.library) || !source.rootPath) {
    throw new Error("雲端書架來源設定無效。");
  }
  const validItems = (Array.isArray(items) ? items : []).filter(item => {
    if (!item || item.isDir) return false;
    const format = String(item.format || "").toUpperCase();
    return source.library === "books" ? format === "EPUB" : format === "EPUB" || format === "CBZ";
  });
  if (!validItems.length) {
    const empty = [];
    if (options.replaceGroups !== true) return empty;
    const db = await openDatabase();
    const tx = db.transaction(STORE_NAME, "readwrite");
    const done = transactionDone(tx);
    const objectStore = tx.objectStore(STORE_NAME);
    let removedCount = 0;
    const allRequest = objectStore.getAll();
    allRequest.onsuccess = () => {
      for (const record of allRequest.result || []) {
        const current = record?.cloudSource;
        if (record?.sourceType === "cloud" && current?.provider === source.provider &&
            current?.library === source.library && current?.rootPath === source.rootPath) {
          objectStore.delete(record.id);
          removedCount++;
        }
      }
    };
    await done;
    empty.removedCount = removedCount;
    return empty;
  }

  const identityPaths = validItems.map(item => normalizePath(item.path));
  if (identityPaths.some(path => !path)) throw new Error("雲端書架資料夾路徑無效。");
  const ids = await Promise.all(identityPaths.map(path => cloudBookId(source, path)));
  const db = await openDatabase();
  const readTx = db.transaction(STORE_NAME, "readonly");
  const readDone = transactionDone(readTx);
  const store = readTx.objectStore(STORE_NAME);
  const existingRequests = ids.map(id => requestResult(store.get(id)));
  const allRecordsRequest = requestResult(store.getAll());
  const [existingRecords, allRecords] = await Promise.all([
    Promise.all(existingRequests),
    allRecordsRequest
  ]);
  await readDone;

  const now = Date.now();
  const replaceGroups = options.replaceGroups === true;
  const validIds = new Set(ids);
  const staleRecords = replaceGroups ? (allRecords || []).filter(record => {
    const current = record?.cloudSource;
    return record?.sourceType === "cloud" && current?.provider === source.provider &&
      current?.library === source.library && current?.rootPath === source.rootPath && !validIds.has(record.id);
  }) : [];
  const records = validItems.map((item, index) => {
    const existing = existingRecords[index] || null;
    const folderPath = normalizePath(item.groupPath || "");
    const grouped = !!folderPath;
    const incomingFiles = (Array.isArray(item.groupFiles) && item.groupFiles.length ? item.groupFiles : [item])
      .filter(file => file && normalizePath(file.path))
      .map(file => ({
        path: normalizePath(file.path),
        name: String(file.name || String(file.path).split("/").pop() || ""),
        format: String(file.format || "").toUpperCase(),
        size: Math.max(0, Number(file.size) || 0),
        modified: file.modified ? String(file.modified) : null,
        coverHash: /^[a-f0-9]{64}$/i.test(String(file.coverHash || "")) ? String(file.coverHash).toLowerCase() : null,
        coverStatus: String(file.coverStatus || "")
      }));
    const oldFiles = !replaceGroups && Array.isArray(existing?.cloudSource?.files) ? existing.cloudSource.files : [];
    const filesByPath = new Map();
    for (const file of [...oldFiles, ...incomingFiles]) {
      if (file?.path) filesByPath.set(normalizePath(file.path), file);
    }
    const mergedFiles = [...filesByPath.values()].sort((a, b) =>
      String(a.path).localeCompare(String(b.path), "zh-Hant", { numeric: true, sensitivity: "base" }));
    const fileName = String(item.name || String(item.path || "").split("/").pop() || "未命名書籍");
    const format = String(item.format || "").toUpperCase();
    const fallbackTitle = grouped
      ? String(item.groupTitle || folderPath.split("/").pop() || fileName)
      : (basename(fileName) || "未命名書籍");
    const coverHash = /^[a-f0-9]{64}$/i.test(String(item.coverHash || "")) ? String(item.coverHash).toLowerCase() : null;
    const coverBlob = existing && existing.cloudCoverHash === coverHash ? (existing.coverBlob || null) : null;
    const modifiedAt = item.modified ? String(item.modified) : null;
    const parsedModified = modifiedAt ? Date.parse(modifiedAt) : NaN;
    const incomingHashes = Array.isArray(item.groupCoverHashes)
      ? item.groupCoverHashes.filter(hash => /^[a-f0-9]{64}$/i.test(String(hash))).map(hash => String(hash).toLowerCase())
      : (coverHash ? [coverHash] : []);
    if (coverHash && item.coverStatus === "ready") incomingHashes.push(coverHash);
    const oldHashes = !replaceGroups && Array.isArray(existing?.cloudCoverHashes) ? existing.cloudCoverHashes : [];
    const cloudCoverHashes = [...new Set([...oldHashes, ...incomingHashes])].slice(0, 8);

    return {
      ...(existing || {}),
      id: ids[index],
      sourceType: "cloud",
      fileName,
      title: existing?.manualTitle ? existing.title : fallbackTitle,
      folderTitle: grouped ? fallbackTitle : "",
      author: existing?.manualAuthor ? existing.author : (existing?.author || ""),
      language: existing?.language || "",
      identifier: existing?.identifier || "",
      format,
      shelf: source.library,
      pageCount: Number(existing?.pageCount) || 0,
      size: Math.max(0, Number(item.size) || 0),
      lastModified: Number.isFinite(parsedModified) ? parsedModified : (Number(existing?.lastModified) || 0),
      modifiedAt,
      blob: null,
      coverBlob,
      cloudCoverHash: coverHash,
      cloudCoverHashes,
      cloudCoverType: String(item.coverType || ""),
      cloudCoverStatus: cloudCoverHashes.length ? "ready" : String(item.coverStatus || (coverHash ? "ready" : "pending")),
      cloudSource: {
        provider: source.provider,
        library: source.library,
        rootPath: source.rootPath,
        path: normalizePath(item.path),
        folderPath: folderPath || "",
        files: mergedFiles.slice(0, 250),
        modifiedAt
      },
      addedAt: Number(existing?.addedAt) || now,
      updatedAt: now,
      lastOpenedAt: Number(existing?.lastOpenedAt) || 0,
      progress: existing?.progress || { percent: 0, label: "尚未閱讀", cfi: "", index: null },
      manualTitle: !!existing?.manualTitle,
      manualAuthor: !!existing?.manualAuthor
    };
  });

  const writeTx = db.transaction(STORE_NAME, "readwrite");
  const writeDone = transactionDone(writeTx);
  const writeStore = writeTx.objectStore(STORE_NAME);
  records.forEach(record => writeStore.put(record));
  staleRecords.forEach(record => writeStore.delete(record.id));
  await writeDone;
  records.removedCount = staleRecords.length;
  return records;
}

function cloudAnnotationDescriptor(book) {
  const source = book && book.cloudSource;
  if (!book || book.sourceType !== "cloud" || !source ||
      !source.provider || !source.library || !source.rootPath || !source.path) {
    throw new Error("這本雲端書籍缺少有效的 OpenList 來源資訊。");
  }
  return {
    id: String(book.id),
    provider: String(source.provider),
    library: String(source.library),
    rootPath: String(source.rootPath),
    path: String(source.path)
  };
}

function cloudAnnotationUrl(book) {
  const source = cloudAnnotationDescriptor(book);
  const params = new URLSearchParams({
    book_id: source.id,
    provider: source.provider,
    library: source.library,
    root_path: source.rootPath,
    path: source.path
  });
  return "/api/reading/annotations?" + params.toString();
}

async function requestCloudAnnotations(method, book, payload = null) {
  const response = await fetch(cloudAnnotationUrl(book), {
    method,
    credentials: "same-origin",
    cache: "no-store",
    headers: payload ? { "Content-Type": "application/json" } : undefined,
    body: payload ? JSON.stringify(Object.assign({ book: cloudAnnotationDescriptor(book) }, payload)) : undefined
  });
  let result;
  try { result = await response.json(); } catch (_) {
    throw new Error("雲端標註 API 回應格式無效（HTTP " + response.status + "）。");
  }
  if (!response.ok || !result || result.ok !== true) {
    throw new Error(String(result && result.error || "雲端標註同步失敗（HTTP " + response.status + "）。"));
  }
  return result;
}

async function saveAnnotation(annotation) {
  if (!annotation || !annotation.bookId) throw new Error("筆記缺少所屬書籍識別碼。");
  const bookId = String(annotation.bookId);
  const book = await getBook(bookId);
  if (!book) throw new Error("找不到這本書，無法保存標註。");
  const now = Date.now();
  const record = {
    id: String(annotation.id || makeId()),
    bookId,
    type: ["highlight", "note", "bookmark"].includes(annotation.type) ? annotation.type : "note",
    cfi: String(annotation.cfi || "").slice(0, 4000),
    quote: String(annotation.quote || "").slice(0, 12000),
    text: String(annotation.text || "").slice(0, 20000),
    color: String(annotation.color || "yellow").slice(0, 32),
    createdAt: Number(annotation.createdAt) || now,
    updatedAt: now
  };

  if (book.sourceType === "cloud") {
    const result = await requestCloudAnnotations("POST", book, { annotation: record });
    return result.annotation;
  }

  const db = await openDatabase();
  const tx = db.transaction("annotations", "readwrite");
  const done = transactionDone(tx);
  tx.objectStore("annotations").put(record);
  await done;
  return record;
}

async function listAnnotations(bookId) {
  const id = String(bookId || "");
  const book = await getBook(id);
  if (!book) throw new Error("找不到這本書，無法讀取標註。");

  if (book.sourceType === "cloud") {
    const result = await requestCloudAnnotations("GET", book);
    return Array.isArray(result.annotations) ? result.annotations : [];
  }

  const db = await openDatabase();
  const tx = db.transaction("annotations", "readonly");
  const index = tx.objectStore("annotations").index("bookId");
  const rows = await requestResult(index.getAll(id));
  return rows.sort((a, b) => Number(a.createdAt || 0) - Number(b.createdAt || 0));
}

async function deleteAnnotation(id, bookId = "") {
  const annotationId = String(id || "");
  if (!annotationId) return false;
  let book = bookId ? await getBook(String(bookId)) : null;

  if (!book) {
    const lookupDb = await openDatabase();
    const lookupTx = lookupDb.transaction("annotations", "readonly");
    const localAnnotation = await requestResult(lookupTx.objectStore("annotations").get(annotationId));
    if (localAnnotation) book = await getBook(localAnnotation.bookId);
  }
  if (!book) throw new Error("刪除標註時找不到所屬書籍，請傳入 bookId。");

  if (book.sourceType === "cloud") {
    await requestCloudAnnotations("DELETE", book, { id: annotationId });
    return true;
  }

  const db = await openDatabase();
  const tx = db.transaction("annotations", "readwrite");
  const done = transactionDone(tx);
  tx.objectStore("annotations").delete(annotationId);
  await done;
  return true;
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

export { openDatabase, importBookFile, getBook, updateBook, deleteBook, listBooks, cloudBookId, upsertCloudBooks, saveAnnotation, listAnnotations, deleteAnnotation, localDayKey, recordReadingEvent, getReadingEvents, getPendingReadingEvents, markReadingEventsSynced, getReadingSetting, setReadingSetting };
