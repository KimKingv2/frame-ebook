/* FRAME Reader cloud-only data client.
 * Persistent library state is stored in D1/R2 and original archives remain in Alist/OpenList.
 * The browser keeps only short-lived in-memory objects needed by the active page.
 */
const bookCache = new Map();


const LOCAL_DB_NAME = "frame-ebook-macos";
const LOCAL_DB_VERSION = 3;
let localDatabasePromise = null;
function isLocalMacApp() {
  return typeof window !== "undefined" && window.FRAME_LOCAL_APP === true;
}
function openLocalDatabase() {
  if (localDatabasePromise) return localDatabasePromise;
  localDatabasePromise = new Promise((resolve, reject) => {
    const request = indexedDB.open(LOCAL_DB_NAME, LOCAL_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("books")) db.createObjectStore("books", { keyPath: "id" });
      if (!db.objectStoreNames.contains("states")) db.createObjectStore("states", { keyPath: "id" });
      if (!db.objectStoreNames.contains("annotations")) db.createObjectStore("annotations", { keyPath: "key" });
      if (!db.objectStoreNames.contains("events")) db.createObjectStore("events", { keyPath: "id" });
      if (!db.objectStoreNames.contains("preferences")) db.createObjectStore("preferences", { keyPath: "key" });
      if (!db.objectStoreNames.contains("sync_meta")) db.createObjectStore("sync_meta", { keyPath: "key" });
      if (!db.objectStoreNames.contains("sync_queue")) db.createObjectStore("sync_queue", { keyPath: "queueId", autoIncrement: true });
    };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => {
        try { db.close(); } catch (_) {}
        localDatabasePromise = null;
      };
      migrateLegacyBookIds(db).then(() => resolve(db)).catch(error => {
        try { db.close(); } catch (_) {}
        reject(new Error("Mac 本機書籍識別遷移失敗，原始資料已保留：" + (error?.message || String(error))));
      });
    };
    request.onerror = () => reject(new Error("無法開啟 Mac 本機閱讀資料庫：" + (request.error?.message || "IndexedDB error")));
    request.onblocked = () => reject(new Error("本機閱讀資料庫正在被舊版 App 連線佔用，請完全退出其他 FRAME Ebook 視窗後重試。"));
  }).catch(error => {
    localDatabasePromise = null;
    throw error;
  });
  return localDatabasePromise;
}
async function getBookIdMigrationReport() {
  if (!isLocalMacApp()) return null;
  const db = await openLocalDatabase();
  return localTransaction(db, ["sync_meta"], "readonly", (tx, set) => {
    const request = tx.objectStore("sync_meta").get("legacyBookIdMigrationV1");
    request.onsuccess = () => set(request.result || null);
  });
}

function localTransaction(db, stores, mode, execute) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(stores, mode);
    let result;
    let hasResult = false;
    const setResult = value => { result = value; hasResult = true; };
    transaction.oncomplete = () => resolve(hasResult ? result : undefined);
    transaction.onerror = () => reject(new Error("Mac 本機資料儲存失敗：" + (transaction.error?.message || "IndexedDB transaction error")));
    transaction.onabort = () => reject(new Error("Mac 本機資料交易已中止。"));
    try { execute(transaction, setResult); }
    catch (error) { try { transaction.abort(); } catch (_) {} reject(error); }
  });
}
function queueLocalChange(tx, change) {
  const queue = tx.objectStore("sync_queue");
  const type = String(change.type || "");
  const bookId = String(change.book?.id || change.annotation?.bookId || "");
  let coalesceKey = "";
  if (type === "state" && bookId) coalesceKey = "state:" + bookId;
  else if ((type === "annotation" || type === "annotation_delete") && bookId) {
    const annotationId = String(change.annotation?.id || change.id || "");
    if (annotationId) coalesceKey = "annotation:" + bookId + "::" + annotationId;
  } else if (type === "preference" && change.key) coalesceKey = "preference:" + String(change.key);

  const record = { ...change, ...(coalesceKey ? { coalesceKey } : {}), queuedAt: Date.now() };
  if (!coalesceKey) {
    queue.add(record);
    return;
  }
  const request = queue.getAll();
  request.onsuccess = () => {
    const existing = (request.result || []).filter(item => item.coalesceKey === coalesceKey)
      .sort((a,b) => Number(b.queueId)-Number(a.queueId))[0];
    if (existing) queue.put({ ...record, queueId: existing.queueId });
    else queue.add(record);
  };
}
function descriptorForQueue(book) {
  const source = book?.cloudSource || book?.source || book || {};
  return {
    id: String(book?.id || source?.id || ""),
    sourceId: String(source?.sourceId || book?.sourceId || ""),
    profileId: String(source?.profileId || book?.profileId || ""),
    library: String(source?.library || book?.library || book?.shelf || ""),
    rootPath: String(source?.rootPath || book?.rootPath || ""),
    path: String(source?.path || book?.path || "")
  };
}

function localApi(path, options = {}) {
  return openLocalDatabase().then(db => {
    const url = new URL(path, window.location.href);
    const method = String(options.method || "GET").toUpperCase();
    let body = {};
    try { body = options.body ? JSON.parse(options.body) : {}; } catch (_) {}
    const pathname = url.pathname;

    if (pathname === "/api/reading/bookshelf" && method === "GET") {
      return localTransaction(db, ["books"], "readonly", (tx, set) => {
        const request = tx.objectStore("books").getAll();
        request.onsuccess = () => {
          const items = (request.result || []).sort((a, b) =>
            (Number(b.lastOpenedAt) || 0) - (Number(a.lastOpenedAt) || 0));
          set({ items });
        };
      });
    }
    if (pathname === "/api/reading/state" && method === "GET") {
      const id = String(url.searchParams.get("book_id") || "");
      return localTransaction(db, ["states"], "readonly", (tx, set) => {
        const request = tx.objectStore("states").get(id);
        request.onsuccess = () => set({ state: request.result?.state || {} });
      });
    }
    if (pathname === "/api/reading/state" && method === "POST") {
      const id = String(body.book && body.book.id || "");
      if (!id) return Promise.reject(new Error("本機閱讀資料缺少書籍識別碼。"));
      return localTransaction(db, ["states", "books", "sync_queue"], "readwrite", (tx, set) => {
        const states = tx.objectStore("states");
        const books = tx.objectStore("books");
        const stateRequest = states.get(id);
        const bookRequest = books.get(id);
        let stateReady = false;
        let bookReady = false;
        let previous = {};
        let book = null;
        const save = () => {
          if (!stateReady || !bookReady) return;
          const patch = body.state || {};
          const state = {
            ...previous, ...patch,
            progress: { ...(previous.progress || {}), ...(patch.progress || {}) },
            appearance: { ...(previous.appearance || {}), ...(patch.appearance || {}) },
            metadata: { ...(previous.metadata || {}), ...(patch.metadata || {}) }
          };
          const updatedAt = Date.now();
          states.put({ id, state, updatedAt });
          if (book) {
            const updatedBook = {
              ...book,
              ...(state.metadata || {}),
              progress: state.progress || book.progress,
              appearance: state.appearance || book.appearance,
              lastOpenedAt: Number(state.lastOpenedAt) || book.lastOpenedAt || 0
            };
            books.put(updatedBook);
            remember(updatedBook);
          }
          queueLocalChange(tx, { type: "state", book: descriptorForQueue(book || body.book), state, updatedAt });
          set({ state });
        };
        stateRequest.onsuccess = () => { previous = stateRequest.result?.state || {}; stateReady = true; save(); };
        bookRequest.onsuccess = () => { book = bookRequest.result || body.book || null; bookReady = true; save(); };
      });
    }
    if (pathname === "/api/reading/annotations" && method === "GET") {
      const bookId = String(url.searchParams.get("book_id") || "");
      return localTransaction(db, ["annotations"], "readonly", (tx, set) => {
        const request = tx.objectStore("annotations").getAll();
        request.onsuccess = () => set({
          annotations: (request.result || []).filter(item => item.bookId === bookId)
            .map(({ key, ...annotation }) => annotation)
        });
      });
    }
    if (pathname === "/api/reading/annotations" && method === "POST") {
      const annotation = body.annotation || {};
      const book = body.book || {};
      const bookId = String(book.id || annotation.bookId || "");
      if (!bookId || !annotation.id) return Promise.reject(new Error("本機標註缺少必要識別資訊。"));
      const updatedAt = Date.now();
      const next = { ...annotation, bookId, updatedAt, key: bookId + "::" + String(annotation.id) };
      return localTransaction(db, ["annotations", "sync_queue"], "readwrite", (tx, set) => {
        tx.objectStore("annotations").put(next);
        queueLocalChange(tx, { type: "annotation", book: descriptorForQueue(book), annotation: { ...annotation, bookId, updatedAt } });
        const { key, ...saved } = next;
        set({ annotation: saved });
      });
    }
    if (pathname === "/api/reading/annotations" && method === "DELETE") {
      const book = body.book || {};
      const bookId = String(book.id || "");
      const id = String(body.id || "");
      return localTransaction(db, ["annotations", "sync_queue"], "readwrite", (tx, set) => {
        tx.objectStore("annotations").delete(bookId + "::" + id);
        queueLocalChange(tx, { type: "annotation_delete", book: descriptorForQueue(book), id, updatedAt: Date.now() });
        set({ ok: true });
      });
    }
    if (pathname === "/api/reading/events" && method === "POST") {
      const incoming = Array.isArray(body.events) ? body.events : [];
      return localTransaction(db, ["events", "books", "sync_queue"], "readwrite", (tx, set) => {
        const events = tx.objectStore("events");
        const books = tx.objectStore("books");
        let accepted = 0;
        let remaining = incoming.length;
        if (!remaining) { set({ accepted: 0 }); return; }
        incoming.forEach(event => {
          if (!event || !event.id) { remaining--; if (!remaining) set({ accepted }); return; }
          const request = events.get(String(event.id));
          request.onsuccess = () => {
            if (!request.result) {
              events.put(event);
              accepted++;
              const bookRequest = books.get(String(event.bookId || ""));
              bookRequest.onsuccess = () => {
                const book = bookRequest.result;
                if (book) queueLocalChange(tx, { type: "event", event, book: descriptorForQueue(book) });
              };
            }
            remaining--;
            if (!remaining) set({ accepted });
          };
          request.onerror = () => { remaining--; if (!remaining) set({ accepted }); };
        });
      });
    }
    if (pathname === "/api/reading/stats" && method === "GET") {
      const from = String(url.searchParams.get("from") || "");
      const to = String(url.searchParams.get("to") || "");
      return localTransaction(db, ["events"], "readonly", (tx, set) => {
        const request = tx.objectStore("events").getAll();
        request.onsuccess = () => set({
          events: (request.result || []).filter(item =>
            String(item.dayKey || "") >= from && String(item.dayKey || "") <= to)
        });
      });
    }
    if (pathname === "/api/reading/preferences" && method === "GET") {
      return localTransaction(db, ["preferences"], "readonly", (tx, set) => {
        const request = tx.objectStore("preferences").getAll();
        request.onsuccess = () => {
          const preferences = {};
          (request.result || []).forEach(item => { preferences[item.key] = item.value; });
          set({ preferences });
        };
      });
    }
    if (pathname === "/api/reading/preferences" && method === "POST") {
      const key = String(body.key || "");
      if (!key) return Promise.reject(new Error("本機偏好設定缺少欄位名稱。"));
      const updatedAt = Number(body.updatedAt) || Date.now();
      return localTransaction(db, ["preferences", "sync_queue"], "readwrite", (tx, set) => {
        tx.objectStore("preferences").put({ key, value: body.value, updatedAt });
        if (["activeProvider", "activeLibrary", "roots", "goalMinutes"].includes(key)) {
          queueLocalChange(tx, { type: "preference", key, value: body.value, updatedAt });
        }
        set({ value: body.value, updatedAt });
      });
    }
    return Promise.reject(new Error("Mac 本機模式尚未實作這項資料操作：" + pathname));
  });
}


async function readLocalStores(names) {
  const db = await openLocalDatabase();
  return localTransaction(db, names, "readonly", (tx, set) => {
    const output = {};
    let remaining = names.length;
    if (!remaining) { set(output); return; }
    names.forEach(name => {
      const request = tx.objectStore(name).getAll();
      request.onsuccess = () => {
        output[name] = request.result || [];
        remaining--;
        if (!remaining) set(output);
      };
    });
  });
}
async function getLocalSyncQueue(limit = 50) {
  const db = await openLocalDatabase();
  return localTransaction(db, ["sync_queue"], "readonly", (tx, set) => {
    const store = tx.objectStore("sync_queue");
    const request = store.getAll();
    request.onsuccess = () => set((request.result || [])
      .sort((a,b) => Number(a.queueId)-Number(b.queueId))
      .slice(0, Math.max(1, Math.min(100, Number(limit)||50))));
  });
}
async function acknowledgeLocalSyncQueue(entries) {
  const items = (Array.isArray(entries) ? entries : []).map(item =>
    typeof item === "object" && item ? { queueId:Number(item.queueId), queuedAt:Number(item.queuedAt) } :
      { queueId:Number(item), queuedAt:null }
  ).filter(item => Number.isSafeInteger(item.queueId));
  if (!items.length) return 0;
  const db = await openLocalDatabase();
  await localTransaction(db, ["sync_queue"], "readwrite", tx => {
    const queue = tx.objectStore("sync_queue");
    items.forEach(item => {
      const request = queue.get(item.queueId);
      request.onsuccess = () => {
        const current = request.result;
        if (current && (item.queuedAt == null || Number(current.queuedAt) === item.queuedAt)) {
          queue.delete(item.queueId);
        }
      };
    });
  });
  return items.length;
}
async function getLocalSyncMeta(key, fallback = null) {
  const db = await openLocalDatabase();
  return localTransaction(db, ["sync_meta"], "readonly", (tx,set) => {
    const request = tx.objectStore("sync_meta").get(String(key));
    request.onsuccess = () => set(request.result ? request.result.value : fallback);
  });
}
async function setLocalSyncMeta(key, value) {
  const db = await openLocalDatabase();
  await localTransaction(db, ["sync_meta"], "readwrite", tx => {
    tx.objectStore("sync_meta").put({ key:String(key), value });
  });
  return value;
}
function buildLocalDescriptor(book) {
  const source = book?.cloudSource || {};
  return {
    id:String(book?.id || ""),
    sourceId:String(source.sourceId || book?.sourceId || ""),
    library:String(source.library || book?.library || ""),
    rootPath:String(source.rootPath || book?.rootPath || ""),
    path:String(source.path || book?.path || "")
  };
}
async function ensureLocalSourceIds(profiles = []) {
  const profileMap = new Map();
  for (const profile of profiles || []) {
    profileMap.set(String(profile.id), await webDavSourceId(profile));
  }
  const db = await openLocalDatabase();
  const local = await readLocalStores(["books"]);
  let changed = 0;
  await localTransaction(db, ["books"], "readwrite", tx => {
    const books = tx.objectStore("books");
    for (const book of local.books || []) {
      const source = book.cloudSource || {};
      if (source.provider !== "webdav") continue;
      const sourceId = profileMap.get(String(source.profileId || book.profileId || ""));
      if (!sourceId || source.sourceId === sourceId) continue;
      const updated = { ...book, cloudSource: { ...source, sourceId } };
      books.put(updated);
      remember(updated);
      changed++;
    }
  });
  return changed;
}

async function upsertSyncedCatalogItems(items, profiles = []) {
  const profileSourceMap = {};
  for (const profile of profiles || []) {
    const sourceId = await webDavSourceId(profile);
    profileSourceMap[sourceId] = String(profile.id);
  }
  const valid = (Array.isArray(items) ? items : []).filter(item => profileSourceMap[item.sourceId]);
  if (!valid.length) return 0;
  const db = await openLocalDatabase();
  await localTransaction(db, ["books"], "readwrite", tx => {
    const books = tx.objectStore("books");
    valid.forEach(item => {
      const request = books.get(String(item.id));
      request.onsuccess = () => {
        const previous = request.result || {};
        if (previous.idMigrationConflict) return;
        const profileId = profileSourceMap[item.sourceId];
        const folderPath = String(item.parentPath || item.path || "/").replace(/\\/g,"/").replace(/[^/]+$/, "");
        const folderTitle = folderPath === "/" ? "根目錄" : folderPath.replace(/\/+$/,"").split("/").pop();
        const source = {
          ...(previous.cloudSource || {}),
          provider:"webdav", profileId, sourceId:item.sourceId,
          library:item.library, rootPath:item.rootPath, path:item.path,
          folderPath, folderTitle
        };
        const next = {
          ...previous,
          id:String(item.id), sourceType:"cloud", provider:"webdav", profileId,
          library:item.library, shelf:item.library, rootPath:item.rootPath, path:item.path,
          fileName:item.fileName, format:item.format, size:Number(item.size)||0,
          lastModified:item.modifiedAt ? (Date.parse(item.modifiedAt)||0) : 0,
          title:previous.manualTitle && previous.title ? previous.title : String(item.title || item.fileName || "未命名書籍"),
          author:previous.manualAuthor && previous.author ? previous.author : String(item.author || ""),
          language:String(item.language || previous.language || ""),
          description:String(item.description || previous.description || ""),
          publisher:String(item.publisher || previous.publisher || ""),
          publishedAt:String(item.publishedAt || previous.publishedAt || ""),
          identifier:String(item.identifier || previous.identifier || ""),
          subjects:Array.isArray(item.subjects) ? item.subjects : (previous.subjects || []),
          cloudCoverHash:item.coverHash || null, cloudCoverStatus:item.coverStatus || "",
          cloudSource:source,
          addedAt:Number(previous.addedAt)||Date.now(),
          progress:previous.progress || {percent:0,label:"尚未閱讀",cfi:"",index:null},
          appearance:previous.appearance || {}
        };
        books.put(next);
        remember(next);
      };
    });
  });
  return valid.length;
}
async function mergeCloudSnapshot(snapshot) {
  const db = await openLocalDatabase();
  const local = await readLocalStores(["books","states","annotations","events","preferences"]);
  const remoteStates = Array.isArray(snapshot.states) ? snapshot.states : [];
  const remoteAnnotations = Array.isArray(snapshot.annotations) ? snapshot.annotations : [];
  const remoteEvents = Array.isArray(snapshot.events) ? snapshot.events : [];
  const remotePreferences = Array.isArray(snapshot.preferences) ? snapshot.preferences : [];
  const remoteAnnotationDeletes = new Set((Array.isArray(snapshot.annotationDeletes) ? snapshot.annotationDeletes : [])
    .map(value => {
      const match = String(value || "").match(/^(cloud:[a-f0-9]{64}):(.*)$/);
      return match ? match[1] + "::" + match[2] : "";
    }).filter(Boolean));
  const localStates = new Map((local.states||[]).map(item=>[String(item.id),item]));
  const localAnnotations = new Map((local.annotations||[]).map(item=>[String(item.bookId)+"::"+String(item.id),item]));
  const localEvents = new Map((local.events||[]).map(item=>[String(item.id),item]));
  const localPreferences = new Map((local.preferences||[]).map(item=>[String(item.key),item]));
  const localBooks = new Map((local.books||[]).map(item=>[String(item.id),item]));
  const stateWrites=[], annotationWrites=[], eventWrites=[], preferenceWrites=[], outgoing=[];
  const now=Date.now();

  for(const remote of remoteStates){
    const id=String(remote.book?.id||"");
    if(!id)continue;
    const existing=localStates.get(id);
    const localTime=Number(existing?.updatedAt||existing?.state?.lastOpenedAt)||0;
    const remoteTime=Number(remote.updatedAt||remote.state?.lastOpenedAt)||0;
    if(existing && localTime>remoteTime){
      const bookRecord=localBooks.get(id);
      if(bookRecord)outgoing.push({type:"state",book:buildLocalDescriptor(bookRecord),state:existing.state,updatedAt:localTime});
    }else{
      stateWrites.push({id,state:remote.state||{},updatedAt:remoteTime||now});
    }
  }
  for(const [id,existing] of localStates){
    if(!remoteStates.some(item=>String(item.book?.id||"")===id) && existing.state && Object.keys(existing.state).length){
      const bookRecord=localBooks.get(id);
      if(bookRecord)outgoing.push({type:"state",book:buildLocalDescriptor(bookRecord),state:existing.state,updatedAt:Number(existing.updatedAt)||now});
    }
  }
  for(const remote of remoteAnnotations){
    const annotation=remote.annotation||{},book=remote.book||{};
    const key=String(book.id||"")+"::"+String(annotation.id||"");
    if(!key.includes("::")||!annotation.id)continue;
    const existing=localAnnotations.get(key);
    const localTime=Number(existing?.updatedAt||existing?.createdAt)||0;
    const remoteTime=Number(annotation.updatedAt||annotation.createdAt)||0;
    if(existing && localTime>remoteTime){
      const bookRecord=localBooks.get(String(book.id||""));
      if(bookRecord)outgoing.push({type:"annotation",book:buildLocalDescriptor(bookRecord),annotation:existing});
    }else{
      annotationWrites.push({...annotation,bookId:String(book.id),key});
    }
  }
  const annotationDeletesToApply = [];
  for(const [key,existing] of localAnnotations){
    if(remoteAnnotationDeletes.has(key)){
      annotationDeletesToApply.push(key);
      continue;
    }
    if(!remoteAnnotations.some(item=>String(item.book?.id||"")+"::"+String(item.annotation?.id||"")===key)){
      const [bookId]=key.split("::");
      const bookRecord=localBooks.get(bookId);
      if(bookRecord)outgoing.push({type:"annotation",book:buildLocalDescriptor(bookRecord),annotation:existing});
    }
  }
  for(const remote of remoteEvents){
    if(!remote?.id)continue;
    if(!localEvents.has(String(remote.id)))eventWrites.push(remote);
  }
  for(const [id,event] of localEvents){
    if(!remoteEvents.some(item=>String(item.id)===id))outgoing.push({type:"event",event});
  }
  for(const remote of remotePreferences){
    const existing=localPreferences.get(String(remote.key));
    if(existing && Number(existing.updatedAt||0)>Number(remote.updatedAt||0)){
      outgoing.push({type:"preference",key:existing.key,value:existing.value,updatedAt:existing.updatedAt});
    }else{
      preferenceWrites.push({key:remote.key,value:remote.value,updatedAt:Number(remote.updatedAt)||now});
    }
  }
  for(const [key,existing] of localPreferences){
    if(!remotePreferences.some(item=>String(item.key)===key)){
      outgoing.push({type:"preference",key,value:existing.value,updatedAt:Number(existing.updatedAt)||now});
    }
  }

  await localTransaction(db,["books","states","annotations","events","preferences","sync_queue","sync_meta"],"readwrite",tx=>{
    const books=tx.objectStore("books"),states=tx.objectStore("states"),annotations=tx.objectStore("annotations"),events=tx.objectStore("events"),preferences=tx.objectStore("preferences");
    stateWrites.forEach(item=>{
      states.put(item);
      const request=books.get(String(item.id));
      request.onsuccess=()=>{
        const book=request.result;
        if(!book)return;
        const state=item.state||{};
        const updated={...book,...(state.metadata||{}),progress:state.progress||book.progress,appearance:state.appearance||book.appearance,lastOpenedAt:Number(state.lastOpenedAt)||book.lastOpenedAt||0};
        books.put(updated);remember(updated);
      };
    });
    annotationDeletesToApply.forEach(key=>annotations.delete(key));
    annotationWrites.forEach(item=>annotations.put(item));
    eventWrites.forEach(item=>events.put(item));
    preferenceWrites.forEach(item=>preferences.put(item));
    outgoing.forEach(change=>queueLocalChange(tx,change));
    tx.objectStore("sync_meta").put({key:"cloudSyncInitialized",value:true});
    tx.objectStore("sync_meta").put({key:"cloudSyncCursor",value:Number(snapshot.cursor)||0});
  });
  return {states:stateWrites.length,annotations:annotationWrites.length,events:eventWrites.length,preferences:preferenceWrites.length,queued:outgoing.length};
}
async function applyRemoteSyncChanges(changes) {
  const list=Array.isArray(changes)?changes:[];
  if(!list.length)return 0;
  const db=await openLocalDatabase();
  const local=await readLocalStores(["books"]);
  const bookMap=new Map((local.books||[]).map(item=>[String(item.id),item]));
  await localTransaction(db,["states","annotations","events","preferences","books"],"readwrite",tx=>{
    const states=tx.objectStore("states"),annotations=tx.objectStore("annotations"),events=tx.objectStore("events"),preferences=tx.objectStore("preferences"),books=tx.objectStore("books");
    for(const change of list){
      const payload=change.payload||{};
      if(change.entityType==="state"&&payload.book?.id){
        const id=String(payload.book.id),state=payload.state||{};
        states.put({id,state,updatedAt:Number(change.createdAt)||Date.now()});
        const book=bookMap.get(id);
        if(book){
          const updated={...book,...(state.metadata||{}),progress:state.progress||book.progress,appearance:state.appearance||book.appearance,lastOpenedAt:Number(state.lastOpenedAt)||book.lastOpenedAt||0};
          books.put(updated);remember(updated);
        }
      }else if(change.entityType==="annotation"&&change.operation==="upsert"&&payload.annotation){
        const annotation=payload.annotation,bookId=String(annotation.bookId||payload.book?.id||"");
        annotations.put({...annotation,bookId,key:bookId+"::"+String(annotation.id)});
      }else if(change.entityType==="annotation"&&change.operation==="delete"){
        const bookId=String(payload.book?.id||""),id=String(payload.id||"");
        if(bookId&&id)annotations.delete(bookId+"::"+id);
      }else if(change.entityType==="event"&&payload.id){
        events.put(payload);
      }else if(change.entityType==="preference"&&payload.key){
        preferences.put({key:String(payload.key),value:payload.value,updatedAt:Number(change.createdAt)||Date.now()});
      }
    }
  });
  return list.length;
}
async function getLocalSyncSnapshot() {
  return readLocalStores(["books","states","annotations","events","preferences"]);
}


async function readJson(response, fallback) {
  let data = {};
  try { data = await response.json(); } catch (_) {}
  if (!response.ok || data?.ok === false || data?.error) {
    throw new Error(String(data?.error || fallback || ("HTTP " + response.status)));
  }
  return data;
}

async function api(path, options = {}, fallback = "雲端資料讀取失敗。") {
  if (isLocalMacApp()) return localApi(path, options);
  const response = await fetch(path, {
    credentials: "same-origin",
    cache: "no-store",
    ...options,
    headers: { ...(options.headers || {}) }
  });
  return readJson(response, fallback);
}

function normalizeDescriptor(book) {
  const source = book?.cloudSource || book?.source || book || {};
  const descriptor = {
    id: String(book?.id || source?.id || ""),
    provider: String(source?.provider || book?.provider || ""),
    library: String(source?.library || book?.library || book?.shelf || ""),
    rootPath: String(source?.rootPath || source?.root_path || book?.rootPath || ""),
    path: String(source?.path || source?.bookPath || book?.path || ""),
    profileId: String(source?.profileId || source?.profile_id || book?.profileId || ""),
    sourceId: String(source?.sourceId || source?.source_id || book?.sourceId || "")
  };
  if (!descriptor.id || !descriptor.provider || !descriptor.library || !descriptor.rootPath || !descriptor.path) {
    throw new Error("缺少有效的 Alist／OpenList 雲端書籍識別資訊。請返回書架重新開啟。");
  }
  return descriptor;
}

function descriptorQuery(book) {
  const d = normalizeDescriptor(book);
  return new URLSearchParams({
    book_id: d.id,
    provider: d.provider,
    library: d.library,
    root_path: d.rootPath,
    path: d.path,
    profile_id: d.profileId,
    source_id: d.sourceId
  });
}

function remember(book) {
  if (book?.id) bookCache.set(String(book.id), book);
  return book;
}

async function cloudBookId(scope, path) {
  const provider = String(scope?.provider || "");
  const library = String(scope?.library || "");
  const filePath = String(path || "").replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  const pathParts = filePath.split("/");
  const fileName = pathParts[pathParts.length - 1] || "";
  if (!["vps", "worker", "mobile", "local", "webdav"].includes(provider) ||
      !["books", "comics"].includes(library) || !fileName.trim()) {
    throw new Error("雲端書籍識別資訊無效。");
  }
  if (provider === "webdav" && (!filePath || filePath.includes("\0") ||
      pathParts.some(part => !part || part === "." || part === ".."))) {
    throw new Error("WebDAV 書籍路徑無效。");
  }
  return filenameBookId(fileName);
}

async function webDavSourceId(profile) {
  const rawUrl = String(profile?.baseUrl || profile?.base_url || "").trim();
  if (!rawUrl) throw new Error("WebDAV 來源缺少網址，無法建立跨設備來源識別碼。");
  let origin;
  try {
    const parsed = new URL(rawUrl);
    if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error("invalid");
    origin = parsed.origin.toLowerCase();
  } catch (_) {
    throw new Error("WebDAV 來源網址無效，無法建立跨設備來源識別碼。");
  }
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(origin));
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
  return "webdav:" + hash;
}

async function listBooks() {
  const data = await api("/api/reading/bookshelf", {}, "無法讀取雲端書架。");
  const items = Array.isArray(data.items) ? data.items : [];
  items.forEach(remember);
  return items;
}
async function addLocalBook(book) {
  if (!isLocalMacApp()) throw new Error("只能在 FRAME Ebook Mac 版加入本機書架。");
  if (!book || !book.id || !book.cloudSource) throw new Error("書籍資料不完整，無法加入本機書架。");
  const db = await openLocalDatabase();
  await localTransaction(db, ["books"], "readwrite", (tx, set) => {
    tx.objectStore("books").put(book);
    set(book);
  });
  return remember(book);
}

async function saveLocalBookCover(id, blob) {
  if (!isLocalMacApp()) return false;
  const key = String(id || "");
  if (!key || !(blob instanceof Blob) || !blob.size || blob.size > 2 * 1024 * 1024) {
    throw new Error("封面縮圖資料無效或超過 2 MiB。");
  }
  const db = await openLocalDatabase();
  await localTransaction(db, ["books"], "readwrite", (tx, set) => {
    const objectStore = tx.objectStore("books");
    const request = objectStore.get(key);
    request.onsuccess = () => {
      const book = request.result;
      if (!book) { set(false); return; }
      const updated = {
        ...book,
        coverBlob: blob,
        coverMime: blob.type || "image/webp",
        coverUpdatedAt: Date.now()
      };
      objectStore.put(updated);
      remember(updated);
      set(true);
    };
  });
  return true;
}

async function removeLocalBook(id) {
  if (!isLocalMacApp()) throw new Error("只能在 FRAME Ebook Mac 版管理本機書架。");
  const key = String(id || "");
  const db = await openLocalDatabase();
  await localTransaction(db, ["books", "states", "annotations"], "readwrite", (tx, set) => {
    tx.objectStore("books").delete(key);
    tx.objectStore("states").delete(key);
    const annotations = tx.objectStore("annotations");
    const request = annotations.getAll();
    request.onsuccess = () => (request.result || []).forEach(item => {
      if (item.bookId === key) annotations.delete(item.key);
    });
    set(true);
  });
  bookCache.delete(key);
  return true;
}


async function getBook(bookOrId) {
  if (bookOrId && typeof bookOrId === "object") {
    const descriptor = normalizeDescriptor(bookOrId);
    const query = descriptorQuery(bookOrId);
    const data = await api("/api/reading/state?" + query.toString(), {}, "無法讀取這本書的雲端閱讀資料。");
    const localBooks = isLocalMacApp()
      ? await api("/api/reading/bookshelf", {}, "無法讀取本機書架。")
      : { items: [] };
    const localBook = (localBooks.items || []).find(item => String(item.id) === descriptor.id);
    const base = bookCache.get(descriptor.id) || localBook || {
      id: descriptor.id,
      sourceType: "cloud",
      provider: descriptor.provider,
      library: descriptor.library,
      rootPath: descriptor.rootPath,
      path: descriptor.path,
      fileName: descriptor.path.split("/").pop(),
      title: descriptor.path.split("/").pop()?.replace(/\.(epub|cbz)$/i, "") || "未命名書籍",
      author: "",
      format: descriptor.path.toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB",
      shelf: descriptor.library,
      size: 0,
      progress: { percent: 0, label: "尚未閱讀", cfi: "", index: null },
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path,
        profileId: descriptor.profileId,
        sourceId: descriptor.sourceId
      }
    };
    const remote = data.state || {};
    const metadata = remote.metadata || {};
    return remember({
      ...base,
      ...metadata,
      title: metadata.manualTitle && metadata.title ? metadata.title :
        (base.title || metadata.title || "未命名書籍"),
      author: metadata.manualAuthor && metadata.author ? metadata.author :
        (base.author || metadata.author || ""),
      id: descriptor.id,
      sourceType: "cloud",
      progress: remote.progress || base.progress,
      appearance: remote.appearance || {},
      lastOpenedAt: Number(remote.lastOpenedAt) || Number(base.lastOpenedAt) || 0,
      manualTitle: !!metadata.manualTitle,
      manualAuthor: !!metadata.manualAuthor,
      cloudSource: {
        provider: descriptor.provider,
        library: descriptor.library,
        rootPath: descriptor.rootPath,
        path: descriptor.path,
        profileId: descriptor.profileId,
        sourceId: descriptor.sourceId || base.cloudSource?.sourceId || ""
      }
    });
  }
  const key = String(bookOrId || "");
  const cached = bookCache.get(key);
  if (cached) return cached;
  if (isLocalMacApp()) {
    const localBooks = await api("/api/reading/bookshelf", {}, "無法讀取本機書架。");
    const localBook = (localBooks.items || []).find(item => String(item.id) === key);
    return localBook ? remember(localBook) : null;
  }
  return null;
}

async function updateBook(id, patch = {}) {
  const book = await getBook(String(id));
  if (!book) throw new Error("找不到這本雲端書籍，請返回書架重新載入。");
  const payload = {};
  if (patch.progress) payload.progress = { ...(book.progress || {}), ...patch.progress };
  if (patch.appearance) payload.appearance = { ...(book.appearance || {}), ...patch.appearance };
  if (patch.lastOpenedAt != null) payload.lastOpenedAt = Number(patch.lastOpenedAt) || Date.now();
  const metadataKeys = ["title", "author", "shelf", "manualTitle", "manualAuthor", "language", "pageCount"];
  if (metadataKeys.some(key => Object.prototype.hasOwnProperty.call(patch, key))) {
    payload.metadata = {};
    metadataKeys.forEach(key => {
      if (Object.prototype.hasOwnProperty.call(patch, key)) payload.metadata[key] = patch[key];
      else if (Object.prototype.hasOwnProperty.call(book, key)) payload.metadata[key] = book[key];
    });
  }
  const descriptor = normalizeDescriptor(book);
  const result = await api("/api/reading/state", {
    method: "POST",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      book: descriptor,
      state: payload
    })
  }, "雲端閱讀資料保存失敗。");
  const remote = result.state || {};
  const updated = {
    ...book,
    ...(remote.metadata || {}),
    progress: remote.progress || book.progress,
    appearance: remote.appearance || book.appearance || {},
    lastOpenedAt: Number(remote.lastOpenedAt) || book.lastOpenedAt || 0
  };
  return remember(updated);
}

async function saveAnnotation(annotation) {
  const book = await getBook(String(annotation?.bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法保存標註。");
  const record = {
    id: String(annotation.id || (crypto.randomUUID ? crypto.randomUUID() : "ann-" + Date.now())),
    bookId: book.id,
    type: ["highlight", "note", "bookmark"].includes(annotation.type) ? annotation.type : "note",
    cfi: String(annotation.cfi || "").slice(0, 4000),
    quote: String(annotation.quote || "").slice(0, 12000),
    text: String(annotation.text || "").slice(0, 20000),
    color: String(annotation.color || "yellow").slice(0, 32),
    createdAt: Number(annotation.createdAt) || Date.now()
  };
  const data = await api("/api/reading/annotations", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ book: normalizeDescriptor(book), annotation: record })
  }, "雲端標註保存失敗。");
  return data.annotation;
}

async function listAnnotations(bookId) {
  const book = await getBook(String(bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法讀取標註。");
  const query = descriptorQuery(book);
  const data = await api("/api/reading/annotations?" + query.toString(), {}, "雲端標註讀取失敗。");
  return Array.isArray(data.annotations) ? data.annotations : [];
}

async function deleteAnnotation(id, bookId) {
  const book = await getBook(String(bookId || ""));
  if (!book) throw new Error("找不到這本雲端書籍，無法刪除標註。");
  await api("/api/reading/annotations", {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ book: normalizeDescriptor(book), id: String(id || "") })
  }, "雲端標註刪除失敗。");
  return true;
}

function localDayKey(timestamp) {
  const date = new Date(Number(timestamp) || Date.now());
  return [date.getFullYear(), String(date.getMonth() + 1).padStart(2, "0"), String(date.getDate()).padStart(2, "0")].join("-");
}

async function recordReadingEvent(event) {
  if (!event || !event.id || !event.dayKey || !String(event.bookId || "").startsWith("cloud:")) return false;
  const result = await api("/api/reading/events", {
    method: "POST",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ events: [event] })
  }, "雲端閱讀紀錄保存失敗。");
  return Number(result.accepted || 0) > 0;
}

async function getReadingEvents(fromDay, toDay) {
  const query = new URLSearchParams({
    from: String(fromDay),
    to: String(toDay),
    include_events: "1"
  });
  const data = await api("/api/reading/stats?" + query.toString(), {}, "讀取雲端閱讀紀錄失敗。");
  return Array.isArray(data.events) ? data.events : [];
}

async function getReadingSetting(key, fallback = null) {
  if (!preferenceCache) {
    if (!preferencePromise) {
      preferencePromise = api("/api/reading/preferences", {}, "讀取雲端偏好設定失敗。")
        .then(data => { preferenceCache = data.preferences || {}; return preferenceCache; })
        .finally(() => { preferencePromise = null; });
    }
    await preferencePromise;
  }
  return Object.prototype.hasOwnProperty.call(preferenceCache, key) ? preferenceCache[key] : fallback;
}

async function setReadingSetting(key, value) {
  const data = await api("/api/reading/preferences", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, value })
  }, "保存雲端偏好設定失敗。");
  preferenceCache = { ...(preferenceCache || {}), [key]: data.value };
  return data.value;
}


export {
  getBook, updateBook, listBooks, cloudBookId, webDavSourceId, getBookIdMigrationReport, ensureLocalSourceIds, addLocalBook, saveLocalBookCover, removeLocalBook,
  saveAnnotation, listAnnotations, deleteAnnotation, localDayKey,
  recordReadingEvent, getReadingEvents, getReadingSetting, setReadingSetting,
  getLocalSyncQueue, acknowledgeLocalSyncQueue, getLocalSyncMeta, setLocalSyncMeta,
  upsertSyncedCatalogItems, mergeCloudSnapshot, applyRemoteSyncChanges, getLocalSyncSnapshot
};
