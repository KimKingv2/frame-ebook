import * as store from "/assets/library-store.js?v=20261117-sync-r1";

const API = {
  snapshot: "/api/device/sync/snapshot",
  catalog: "/api/device/sync/catalog",
  push: "/api/device/sync/push",
  pull: "/api/device/sync/pull"
};
const CATALOG_REFRESH_MS = 24 * 60 * 60 * 1000;
const SYNC_INTERVAL_MS = 60 * 1000;

function parseNativeResponse(raw) {
  let data;
  try { data = typeof raw === "string" ? JSON.parse(raw) : raw; }
  catch (_) { throw new Error("Cloudflare 同步回應不是有效 JSON。"); }
  if (!data || typeof data !== "object") throw new Error("Cloudflare 同步回應格式無效。");
  if (data.ok === false || data.error) {
    let message = String(data.error || ("HTTP " + (data.httpStatus || "unknown")));
    try {
      const nested = JSON.parse(message);
      message = String(nested.error || nested.message || message);
    } catch (_) {}
    throw new Error(message);
  }
  return data;
}

export function startMacSync({ invoke, getProfiles, onStatus = () => {}, onLog = () => {}, onCatalogUpdated = () => {} } = {}) {
  if (!window.FRAME_LOCAL_APP || !window.__TAURI__?.core?.invoke) return null;

  let inFlight = null;
  let intervalId = null;
  let stopped = false;
  let lastResult = null;
  const nativeInvoke = invoke || ((name, args = {}) => window.__TAURI__.core.invoke(name, args));

  async function request(method, path, body) {
    const raw = await nativeInvoke("cloud_sync_request", {
      method,
      path,
      body: body == null ? null : JSON.stringify(body)
    });
    return parseNativeResponse(raw);
  }

  async function loadProfiles() {
    if (typeof getProfiles === "function") {
      const value = await getProfiles();
      if (Array.isArray(value)) return value;
    }
    const value = await nativeInvoke("list_webdav_profiles");
    return Array.isArray(value) ? value : [];
  }

  async function fetchCloudCatalog(sourceMap, profiles, refreshCatalog) {
    const profilesBySource = new Map();
    for (const profile of profiles) {
      try { profilesBySource.set(await store.webDavSourceId(profile), profile); }
      catch (error) { onLog("WARN", "無法計算 WebDAV 來源識別碼", error.message || String(error)); }
    }
    let imported = 0;
    const unmatched = [];
    for (const [sourceId, provider] of Object.entries(sourceMap || {})) {
      const profile = profilesBySource.get(sourceId);
      if (!profile) {
        unmatched.push(sourceId);
        continue;
      }
      const metaKey = "cloudCatalogFetchedAt:" + sourceId;
      const fetchedAt = Number(await store.getLocalSyncMeta(metaKey, 0)) || 0;
      if (!refreshCatalog && fetchedAt && Date.now() - fetchedAt < CATALOG_REFRESH_MS) continue;
      onStatus("正在同步雲端書架索引 · " + (profile.name || provider));
      const query = new URLSearchParams({ source_id: sourceId });
      const result = await request("GET", API.catalog + "?" + query.toString());
      if (result.truncated) {
        throw new Error("Cloudflare 書架索引超過 10,000 筆。為避免只匯入部分書架，已停止本次更新；請縮小雲端書庫根目錄後再重新整理。");
      }
      imported += await store.upsertSyncedCatalogItems(result.items || [], [profile]);
      await store.setLocalSyncMeta(metaKey, Date.now());
      onLog("INFO", "雲端書架索引已更新", (result.count || 0) + " 筆 · " + (profile.name || provider));
    }
    if (imported) { try { onCatalogUpdated(imported); } catch (_) {} }
    if (unmatched.length) {
      onLog("WARN", "部分 Cloudflare 書庫尚未對應到這台 Mac 的 WebDAV 來源",
        unmatched.length + " 個來源未能唯一對應到 Cloudflare Provider。請確認該網域只配置一個 Cloudflare AList Provider，且 Mac WebDAV 與其指向同一主機。");
    }
    return imported;
  }

  async function pushPendingChanges(snapshot) {
    const queue = await store.getLocalSyncQueue(50);
    if (!queue.length) return 0;
    const bookMap = new Map((snapshot.books || []).map(book => [String(book.id), book]));
    const changes = [];
    const queueAcks = [];
    for (const item of queue) {
      const type = String(item.type || "");
      if (type === "event") {
        changes.push({ type, event: item.event });
        queueAcks.push({ queueId:item.queueId, queuedAt:item.queuedAt });
        continue;
      }
      if (type === "preference") {
        changes.push({ type, key: item.key, value: item.value });
        queueAcks.push({ queueId:item.queueId, queuedAt:item.queuedAt });
        continue;
      }
      const id = String(item.book?.id || item.annotation?.bookId || "");
      const localBook = bookMap.get(id);
      const source = localBook?.cloudSource || {};
      const book = {
        id,
        sourceId: String(source.sourceId || item.book?.sourceId || ""),
        library: String(source.library || item.book?.library || ""),
        rootPath: String(source.rootPath || item.book?.rootPath || ""),
        path: String(source.path || item.book?.path || "")
      };
      if (!book.id || !book.sourceId || !book.library || !book.rootPath || !book.path) {
        onLog("WARN", "同步佇列保留一筆尚未對應來源的書籍資料", id || "缺少 Book ID");
        continue;
      }
      if (type === "state") {
        changes.push({ type, book, state: item.state });
      } else if (type === "annotation") {
        changes.push({ type, book, annotation: item.annotation });
      } else if (type === "annotation_delete") {
        changes.push({ type, book, id: item.id });
      } else {
        onLog("WARN", "跳過未知的本機同步資料類型", type);
        continue;
      }
      queueAcks.push({ queueId:item.queueId, queuedAt:item.queuedAt });
    }
    if (!changes.length) return 0;
    const result = await request("POST", API.push, { changes });
    await store.acknowledgeLocalSyncQueue(queueAcks);
    onLog("INFO", "本機變更已推送至 Cloudflare", "處理 " + changes.length + " 筆；清除待同步佇列 " + queueAcks.length + " 筆");
    return Number(result.accepted) || changes.length;
  }

  async function pullRemoteChanges() {
    let cursor = Number(await store.getLocalSyncMeta("cloudSyncCursor", 0)) || 0;
    let applied = 0;
    for (let page = 0; page < 40; page++) {
      const query = new URLSearchParams({ cursor: String(cursor), limit: "250" });
      const result = await request("GET", API.pull + "?" + query.toString());
      const changes = Array.isArray(result.changes) ? result.changes : [];
      if (changes.length) {
        applied += await store.applyRemoteSyncChanges(changes);
        cursor = Number(result.cursor) || cursor;
        await store.setLocalSyncMeta("cloudSyncCursor", cursor);
      }
      if (!result.hasMore || !changes.length) break;
      if (page === 39) onLog("WARN", "增量同步仍有待處理資料", "已達單次最多 10,000 筆的保護上限，下次同步會接續游標。");
    }
    return applied;
  }

  async function performSync({ refreshCatalog = false } = {}) {
    const credentials = await nativeInvoke("cloud_sync_get_credentials");
    if (!credentials?.deviceToken) {
      onStatus("尚未連結 Cloudflare 帳號");
      return { linked: false, pushed: 0, pulled: 0, catalog: 0 };
    }
    onStatus("正在連線 Cloudflare…");
    let initialized = !!(await store.getLocalSyncMeta("cloudSyncInitialized", false));
    let sourceMap = await store.getLocalSyncMeta("cloudSyncSourceMap", null);
    const profiles = await loadProfiles();
    const enriched = await store.ensureLocalSourceIds(profiles);
    if (enriched) onLog("INFO", "已補齊舊 WebDAV 書籍的跨設備來源識別碼", enriched + " 本");

    if (!initialized || !sourceMap) {
      onStatus("首次同步：讀取雲端資料快照…");
      const snapshot = await request("GET", API.snapshot);
      const truncated = Object.entries(snapshot.truncated || {}).filter(([, value]) => value);
      if (truncated.length) {
        throw new Error("雲端首次同步資料超過安全快照上限：" + truncated.map(([key]) => key).join("、") + "。暫停合併，避免只同步部分資料。");
      }
      sourceMap = snapshot.sourceMap || {};
      const imported = await fetchCloudCatalog(sourceMap, profiles, true);
      const merged = await store.mergeCloudSnapshot(snapshot);
      await store.setLocalSyncMeta("cloudSyncSourceMap", sourceMap);
      initialized = true;
      onLog("INFO", "首次雲端資料合併完成",
        "書架索引 " + imported + " 筆；閱讀狀態 " + merged.states + " 筆；註釋 " + merged.annotations + " 筆；閱讀事件 " + merged.events + " 筆；本機待推送 " + merged.queued + " 筆");
    } else if (refreshCatalog) {
      const imported = await fetchCloudCatalog(sourceMap, profiles, true);
      onLog("INFO", "已手動更新雲端書架索引", imported + " 筆");
    }

    let current = await store.getLocalSyncSnapshot();
    let pushed = 0;
    for (let batch = 0; batch < 20; batch++) {
      const count = await pushPendingChanges(current);
      pushed += count;
      if (!count) break;
      current = await store.getLocalSyncSnapshot();
      const remaining = await store.getLocalSyncQueue(1);
      if (!remaining.length) break;
      if (batch === 19) onLog("WARN", "本機仍有待推送資料", "已達單次最多 1,000 筆的保護上限。");
    }
    const pulled = await pullRemoteChanges();
    const result = { linked: true, pushed, pulled, catalog: 0, completedAt: Date.now() };
    await store.setLocalSyncMeta("cloudSyncLastSuccessAt", result.completedAt);
    lastResult = result;
    onStatus("Cloudflare 已同步 · 推送 " + pushed + " · 拉取 " + pulled);
    onLog("INFO", "多設備同步完成", "推送 " + pushed + " 筆、拉取 " + pulled + " 筆");
    return result;
  }

  function syncNow(options = {}) {
    if (stopped) return Promise.resolve(null);
    if (inFlight) return inFlight;
    inFlight = performSync(options).catch(error => {
      onStatus("雲端同步暫時失敗");
      onLog("ERROR", "Cloudflare 多設備同步失敗", error.message || String(error));
      throw error;
    }).finally(() => { inFlight = null; });
    return inFlight;
  }

  async function refreshStatus() {
    try {
      const credentials = await nativeInvoke("cloud_sync_get_credentials");
      if (!credentials?.deviceToken) return onStatus("尚未連結 Cloudflare 帳號");
      const last = Number(await store.getLocalSyncMeta("cloudSyncLastSuccessAt", 0)) || 0;
      onStatus(last ? "Cloudflare 已連結 · 上次同步 " + new Date(last).toLocaleTimeString("zh-TW", { hour12: false }) : "Cloudflare 已連結 · 尚未初次同步");
    } catch (_) {}
  }

  async function tick() {
    if (stopped || document.visibilityState === "hidden") return;
    try { await syncNow(); } catch (_) {}
  }

  intervalId = setInterval(tick, SYNC_INTERVAL_MS);
  window.addEventListener("online", tick);
  window.addEventListener("pageshow", tick);
  void refreshStatus();
  void tick();

  const manager = {
    syncNow,
    refreshStatus,
    getLastResult: () => lastResult,
    stop() {
      stopped = true;
      if (intervalId) clearInterval(intervalId);
      window.removeEventListener("online", tick);
      window.removeEventListener("pageshow", tick);
    }
  };
  window.__FRAME_MAC_SYNC_STARTED = true;
  window.__FRAME_MAC_SYNC_MANAGER = manager;
  return manager;
}
