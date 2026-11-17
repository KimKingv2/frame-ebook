import * as store from "/assets/library-store.js?v=20261117-filename-id-r2";
import { createMacShelf } from "/mac/shelf.js?v=20261117-preview-shelf-r3";
import { startMacSync } from "/mac/sync.js?v=20261117-sync-r1";
const $ = id => document.getElementById(id);
const LOG_LIMIT = 500;
const logState = { entries: [] };
let webDavScanPromise = null;
let macSyncManager = null;
const state = { profiles: [], profileId: "", unlockedProfileId: "", editingProfileId: "", path: "/", entries: [], tab: "shelf", busy: false, directoryReloadPending: false, lastStatus: "" };
const BOOK_EXTENSIONS = new Set(["epub", "cbz"]);

function errorText(error) {
  if (error instanceof Error) return error.message || error.name;
  if (typeof error === "string") return error;
  try { return JSON.stringify(error); } catch (_) { return String(error); }
}
function renderLogs() {
  const output = $("log-output");
  const count = $("log-count");
  if (count) count.textContent = String(logState.entries.length);
  if (!output) return;
  output.textContent = logState.entries.map(entry =>
    "[" + entry.time + "] [" + entry.level + "] " + entry.message +
    (entry.detail ? "\n" + entry.detail : "")
  ).join("\n");
  output.scrollTop = output.scrollHeight;
}
function appendLog(level, message, detail = "") {
  const entry = {
    time: new Date().toLocaleString("zh-TW", { hour12: false }),
    level: String(level || "INFO").toUpperCase(),
    message: String(message || ""),
    detail: detail == null ? "" : String(detail)
  };
  logState.entries.push(entry);
  if (logState.entries.length > LOG_LIMIT) logState.entries.splice(0, logState.entries.length - LOG_LIMIT);
  renderLogs();
  return entry;
}
async function invoke(name, args = {}) {
  const started = performance.now();
  const trackSuccess = !["webdav_read_range", "take_webdav_transfer_diagnostics", "webdav_list_directory"].includes(name);
  if (trackSuccess) appendLog("INFO", "原生指令開始：" + name);
  try {
    const result = await window.__TAURI__.core.invoke(name, args);
    if (trackSuccess) appendLog("INFO", "原生指令完成：" + name + "（" + Math.round(performance.now() - started) + " ms）");
    return result;
  } catch (error) {
    appendLog("ERROR", "原生指令失敗：" + name, errorText(error));
    throw error;
  }
}
function setStatus(message, error = false) {
  const value = String(message || "");
  if (value !== state.lastStatus || error) {
    appendLog(error ? "ERROR" : "INFO", "狀態：" + value);
    state.lastStatus = value;
  }
  const node = $("connection-status");
  node.replaceChildren();
  const dot = document.createElement("i");
  node.appendChild(dot);
  node.appendChild(document.createTextNode(" " + value));
  node.classList.toggle("is-error", !!error);
}
window.addEventListener("error", event => {
  appendLog("ERROR", "前端 JavaScript 錯誤",
    String(event.message || "未知錯誤") +
    (event.filename ? " · " + event.filename : "") +
    (event.lineno ? ":" + event.lineno + ":" + (event.colno || 0) : ""));
});
window.addEventListener("unhandledrejection", event => {
  appendLog("ERROR", "未處理的非同步錯誤", errorText(event.reason));
});
function extension(path) {
  const match = String(path || "").match(/\.([^.\/]+)$/);
  return match ? match[1].toLowerCase() : "";
}
function baseTitle(name) { return String(name || "").replace(/\.(epub|cbz)$/i, ""); }
function selectedProfile() { return state.profiles.find(item => item.id === state.profileId) || null; }
function profileField(profile, camelName, snakeName) {
  if (!profile || typeof profile !== "object") return "";
  const value = profile[camelName] ?? profile[snakeName];
  return value == null || String(value) === "undefined" ? "" : String(value);
}
function profileStorageKey() { return "frame-ebook-mac-active-profile"; }
function pathStorageKey() { return "frame-ebook-mac-path-" + state.profileId; }
function showTab(tab) {
  state.tab = tab === "browser" ? "browser" : "shelf";
  $("shelf-panel").hidden = state.tab !== "shelf";
  $("browser-panel").hidden = state.tab !== "browser";
  document.querySelectorAll("[data-tab]").forEach(button => button.classList.toggle("is-active", button.dataset.tab === state.tab));
  if (state.tab === "browser" && state.profileId) void loadDirectory();
}
function renderProfiles() {
  const select = $("profile-select");
  select.replaceChildren();
  if (!state.profiles.length) {
    const option = document.createElement("option");
    option.value = ""; option.textContent = "尚未設定來源"; select.appendChild(option);
    return;
  }
  state.profiles.forEach(profile => {
    const option = document.createElement("option");
    option.value = profile.id;
    option.textContent = profileField(profile, "name", "name") || "未命名 WebDAV 來源";
    select.appendChild(option);
  });
  select.value = state.profileId;
}
async function refreshProfiles(preferredId = "") {
  state.profiles = await invoke("list_webdav_profiles");
  appendLog("INFO", "已載入 WebDAV 來源", state.profiles.length + " 個來源設定");
  const saved = preferredId || localStorage.getItem(profileStorageKey()) || "";
  state.profileId = state.profiles.some(item => item.id === saved) ? saved : (state.profiles[0] ? state.profiles[0].id : "");
  renderProfiles();
  if (state.profileId) {
    localStorage.setItem(profileStorageKey(), state.profileId);
    state.path = localStorage.getItem(pathStorageKey()) || "/";
  }
}
function formatSize(value) {
  const bytes = Number(value) || 0;
  if (bytes < 1024 * 1024) return Math.max(1, Math.round(bytes / 1024)) + " KB";
  return (bytes / 1024 / 1024).toFixed(bytes >= 1024 * 1024 * 1024 ? 2 : 1) + (bytes >= 1024 * 1024 * 1024 ? " GB" : " MB");
}
const shelf = createMacShelf({
  store, invoke, appendLog, setStatus, openBook,
  getProfileId: () => state.profileId,
  isProfileUnlocked: profileId => state.unlockedProfileId === String(profileId || "")
});
async function refreshShelf({ prefetch = true } = {}) {
  try { await shelf.refresh({ prefetch }); }
  catch (error) { setStatus(error.message || String(error), true); }
}
function readerUrl(book) {
  const source = book.cloudSource || {};
  const query = new URLSearchParams({
    book: String(book.id), provider: String(source.provider || "webdav"),
    library: String(source.library || book.shelf || "books"),
    root_path: String(source.rootPath || "/"), path: String(source.path || ""),
    profile_id: String(source.profileId || ""),
    source_id: String(source.sourceId || "")
  });
  return "/epub-lab/?" + query.toString();
}
function openBook(book) { window.location.href = readerUrl(book); }
async function addBook(entry, openAfter = false, refresh = true, profileOverride = null) {
  const profile = profileOverride || selectedProfile();
  if (!profile || !entry || entry.isDir) return;
  const ext = extension(entry.path);
  if (!BOOK_EXTENSIONS.has(ext)) return;
  const library = ext === "cbz" ? "comics" : "books";
  const scope = { provider: "webdav", profileId: profile.id, library };
  appendLog("INFO", "準備加入書籍", entry.path);
  const [id, sourceId] = await Promise.all([
    store.cloudBookId(scope, entry.path),
    store.webDavSourceId(profile)
  ]);
  const folderPath = parentPath(entry.path);
  const folderTitle = folderPath === "/" ? "根目錄" : folderPath.replace(/\/+$/, "").split("/").pop();
  const record = {
    id, sourceType: "cloud", provider: "webdav", library, rootPath: "/",
    path: entry.path, fileName: entry.name, title: baseTitle(entry.name), addedAt: Date.now(),
    lastModified: Date.parse(String(entry.modified || "")) || 0,
    author: "", format: ext.toUpperCase(), shelf: library,
    size: Number(entry.size) || 0,
    progress: { percent: 0, label: "尚未閱讀", cfi: "", index: null },
    appearance: {},
    cloudSource: { provider: "webdav", profileId: profile.id, sourceId, library, rootPath: "/", path: entry.path, folderPath, folderTitle }
  };
  await store.addLocalBook(record);
  appendLog("INFO", "書籍已加入本機書架", entry.path);
  if (refresh) await refreshShelf();
  setStatus("已加入書架 · " + entry.name);
  if (openAfter) openBook(record);
}
const SKIP_SCAN_FOLDERS = new Set([
  "@eadir", "#recycle", "__macosx", ".appledouble", ".trash", "lost+found"
]);
function shouldSkipScanFolder(entry) {
  const name = String(entry?.name || "").trim().toLowerCase();
  return !name || SKIP_SCAN_FOLDERS.has(name);
}
function makeScannedBookRecord(entry, profile, sourceId) {
  const ext = extension(entry.path);
  const library = ext === "cbz" ? "comics" : "books";
  const folderPath = parentPath(entry.path);
  const folderTitle = folderPath === "/" ? "根目錄" : folderPath.replace(/\\/+$/, "").split("/").pop();
  return store.cloudBookId({ provider:"webdav", profileId:profile.id, library }, entry.path).then(id => ({
    id, sourceType:"cloud", provider:"webdav", library, rootPath:"/",
    path:entry.path, fileName:entry.name, title:baseTitle(entry.name),
    addedAt:Date.now(), lastModified:Date.parse(String(entry.modified || "")) || 0,
    author:"", format:ext.toUpperCase(), shelf:library, size:Number(entry.size)||0,
    progress:{percent:0,label:"尚未閱讀",cfi:"",index:null}, appearance:{},
    cloudSource:{provider:"webdav",profileId:profile.id,sourceId,library,rootPath:"/",
      path:entry.path,folderPath,folderTitle}
  }));
}
async function listDirectoryForScan(profileId, path) {
  let lastError = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await invoke("webdav_list_directory", { profileId, path });
    } catch (error) {
      lastError = error;
      const message = errorText(error);
      if (attempt || /驗證失敗|401|403|不允許|權限/i.test(message)) break;
      await new Promise(resolve => setTimeout(resolve, 800));
    }
  }
  throw lastError || new Error("WebDAV 目錄讀取失敗。");
}
async function scanWebDavProfile(profile) {
  if (!profile) return { skipped:true };
  if (webDavScanPromise) return webDavScanPromise;
  webDavScanPromise = (async () => {
    const profileId = String(profile.id || "");
    if (!profileId) throw new Error("WebDAV 來源缺少識別碼。");
    const authenticated = await invoke("webdav_has_password", { profileId });
    if (!authenticated) {
      state.unlockedProfileId = "";
      openProfileDialog(profile);
      setStatus("請重新輸入「" + (profile.name || "WebDAV") + "」的密碼，之後會自動掃描書庫。");
      return { locked:true };
    }
    state.unlockedProfileId = profileId;
    const sourceId = await store.webDavSourceId(profile);
    const pendingDirectories = ["/"];
    const visited = new Set();
    let scannedDirectories = 0;
    let discoveredFiles = 0;
    let added = 0;
    let updated = 0;
    let unchanged = 0;
    let conflicts = 0;
    let failedDirectories = 0;
    let batch = [];
    const flush = async () => {
      if (!batch.length) return;
      const result = await store.addLocalBooks(batch);
      added += Number(result.added) || 0;
      updated += Number(result.updated) || 0;
      unchanged += Number(result.unchanged) || 0;
      conflicts += Number(result.conflicts) || 0;
      batch = [];
    };

    appendLog("INFO", "開始自動掃描 WebDAV 書庫", (profile.name || profileId) + " · 根目錄 /");
    setStatus("正在掃描 WebDAV 書庫 · " + (profile.name || ""));
    const MAX_DIRECTORIES = 20000;
    const MAX_BOOKS = 50000;

    while (pendingDirectories.length && scannedDirectories < MAX_DIRECTORIES && discoveredFiles < MAX_BOOKS) {
      const currentBatch = pendingDirectories.splice(0, 3);
      const results = await Promise.all(currentBatch.map(async path => {
        if (visited.has(path)) return { path, skipped:true };
        visited.add(path);
        try {
          const entries = await listDirectoryForScan(profileId, path);
          return { path, entries:Array.isArray(entries) ? entries : [] };
        } catch (error) {
          return { path, error };
        }
      }));
      for (const result of results) {
        if (result.skipped) continue;
        if (result.error) {
          failedDirectories++;
          appendLog("WARN", "自動掃描略過無法讀取的資料夾", result.path + "\\n" + errorText(result.error));
          if (result.path === "/") throw result.error;
          continue;
        }
        scannedDirectories++;
        for (const entry of result.entries) {
          if (entry.isDir) {
            if (!shouldSkipScanFolder(entry)) {
              const nextPath = String(entry.path || "").replace(/\\\\/g, "/").replace(/\\/$/, "") || "/";
              if (nextPath.startsWith("/") && !visited.has(nextPath) && !pendingDirectories.includes(nextPath)) {
                pendingDirectories.push(nextPath);
              }
            }
            continue;
          }
          if (!BOOK_EXTENSIONS.has(extension(entry.path))) continue;
          discoveredFiles++;
          batch.push(await makeScannedBookRecord(entry, profile, sourceId));
          if (batch.length >= 50) await flush();
          if (discoveredFiles >= MAX_BOOKS) break;
        }
        if (scannedDirectories % 10 === 0) {
          setStatus("掃描中 · " + scannedDirectories + " 個資料夾 · 找到 " + discoveredFiles + " 本書");
        }
      }
    }
    await flush();
    const limited = pendingDirectories.length > 0 || scannedDirectories >= MAX_DIRECTORIES || discoveredFiles >= MAX_BOOKS;
    await refreshShelf({ prefetch:false });
    appendLog("INFO", "WebDAV 自動掃描完成",
      "來源：" + (profile.name || profileId) +
      "\\n已掃描資料夾：" + scannedDirectories +
      "\\n找到 EPUB／CBZ：" + discoveredFiles +
      "\\n新增：" + added + "；更新：" + updated + "；未變更：" + unchanged +
      "\\n檔名衝突略過：" + conflicts + "；無權限／讀取失敗資料夾：" + failedDirectories +
      (limited ? "\\n已達安全掃描上限，下一次啟動可繼續完整掃描。" : ""));
    setStatus("書架更新完成 · " + discoveredFiles + " 本 · 新增 " + added + " 本" +
      (conflicts ? " · 檔名衝突 " + conflicts : ""));
    void shelf.prefetchCovers();
    return { scannedDirectories, discoveredFiles, added, updated, unchanged, conflicts, failedDirectories, limited };
  })().catch(error => {
    appendLog("ERROR", "WebDAV 自動掃描失敗", errorText(error));
    setStatus(errorText(error), true);
    throw error;
  }).finally(() => { webDavScanPromise = null; });
  return webDavScanPromise;
}
function startAutomaticLibraryScan(profile = selectedProfile()) {
  if (!profile) {
    setStatus("本機就緒 · 尚未設定 WebDAV 來源");
    return Promise.resolve({ skipped:true });
  }
  return scanWebDavProfile(profile);
}
function parentPath(path) {
  const pieces = String(path || "/").replace(/\/+$/, "").split("/").filter(Boolean);
  pieces.pop();
  return pieces.length ? "/" + pieces.join("/") + "/" : "/";
}
function renderEntries(entries) {
  const host = $("file-list"); host.replaceChildren();
  const visible = entries.filter(item => item.isDir || BOOK_EXTENSIONS.has(extension(item.path)));
  $("folder-count").textContent = visible.length + " 個項目";
  $("browser-empty").hidden = visible.length > 0;
  visible.forEach(item => {
    const button = document.createElement("button"); button.className = "file-row"; button.type = "button";
    const icon = document.createElement("span"); icon.className = "file-icon"; icon.textContent = item.isDir ? "▰" : (extension(item.path) === "cbz" ? "▧" : "▤");
    const name = document.createElement("span"); name.className = "file-name"; name.textContent = item.name;
    const kind = document.createElement("span"); kind.className = "file-kind"; kind.textContent = item.isDir ? "資料夾" : extension(item.path).toUpperCase();
    const size = document.createElement("span"); size.className = "file-size"; size.textContent = item.isDir ? " " : formatSize(item.size);
    const action = document.createElement("span"); action.className = "file-open"; action.textContent = item.isDir ? "開啟資料夾 ›" : "加入並閱讀 ↗";
    button.append(icon, name, kind, size, action);
    button.addEventListener("click", () => {
      if (item.isDir) {
        state.path = item.path;
        localStorage.setItem(pathStorageKey(), state.path);
        void loadDirectory();
      } else {
        void addBook(item, true).catch(error => setStatus(error.message || String(error), true));
      }
    });
    host.appendChild(button);
  });
}
async function loadDirectory() {
  if (state.busy) {
    // Keep the newest navigation request. The previous in-flight request must
    // not silently swallow a folder click made while WebDAV is still loading.
    state.directoryReloadPending = true;
    return;
  }
  const profile = selectedProfile();
  if (!profile) { setStatus("請先新增 WebDAV 來源", true); return; }
  state.busy = true;
  const requestedPath = state.path;
  const requestedProfileId = profile.id;
  setStatus("正在讀取 WebDAV…");
  $("file-list").replaceChildren();
  $("current-path").textContent = requestedPath;
  try {
    const authenticated = await invoke("webdav_has_password", { profileId: requestedProfileId });
    if (!authenticated) {
      openProfileDialog(profile);
      setStatus("請重新輸入「" + profile.name + "」的密碼；密碼只保留在 RAM。");
      return;
    }
    const entries = await invoke("webdav_list_directory", { profileId: requestedProfileId, path: requestedPath });
    // Ignore stale results if the user switched source or navigated elsewhere.
    if (requestedProfileId !== state.profileId || requestedPath !== state.path) {
      state.directoryReloadPending = true;
      return;
    }
    state.entries = Array.isArray(entries) ? entries : [];
    state.unlockedProfileId = requestedProfileId;
    renderEntries(state.entries);
    appendLog("INFO", "目錄讀取成功", requestedPath + " · " + state.entries.length + " 個項目");
    // Finish the WebDAV navigation immediately. Shelf refresh/prefetch must
    // never keep the browser in its loading state or block subsequent clicks.
    setStatus("WebDAV 已連線 · " + profile.name);
    void refreshShelf({ prefetch: false });
  } catch (error) {
    if (requestedProfileId === state.profileId && requestedPath === state.path) {
      setStatus(error.message || String(error), true);
      $("browser-empty").hidden = false;
      $("browser-empty").querySelector("h3").textContent = "無法讀取這個資料夾";
      $("browser-empty").querySelector("p").textContent = error.message || String(error);
    }
  } finally {
    state.busy = false;
    if (state.directoryReloadPending) {
      state.directoryReloadPending = false;
      if (state.tab === "browser") void loadDirectory();
    }
  }
}
function openProfileDialog(existingProfile = null) {
  $("profile-error").textContent = "";
  const isUnlock = !!existingProfile;
  state.editingProfileId = isUnlock ? profileField(existingProfile, "id", "id") : "";
  $("profile-name").value = isUnlock ? profileField(existingProfile, "name", "name") : "";
  $("profile-url").value = isUnlock ? profileField(existingProfile, "baseUrl", "base_url") : "";
  $("profile-username").value = isUnlock ? profileField(existingProfile, "username", "username") : "";
  $("profile-password").value = "";
  // Keep the saved values prefilled, but let the user repair or edit them.
  ["profile-name", "profile-url", "profile-username"].forEach(id => {
    $(id).readOnly = false;
    $(id).disabled = false;
  });
  $("profile-dialog-title").textContent = isUnlock ? "重新輸入 WebDAV 密碼" : "新增檔案來源";
  $("profile-dialog-intro").textContent = isUnlock
    ? "來源名稱、WebDAV 地址及帳號都可以修改。密碼只保留在目前 App 的 RAM，完全退出後需要重新輸入。"
    : "輸入 WebDAV 服務地址及唯讀帳號。密碼僅保留在 App 執行期間的 RAM，不會寫入鑰匙圈或磁碟。";
  $("save-profile").textContent = isUnlock ? "儲存並重新連線" : "儲存並測試連線";
  $("profile-password").setAttribute("autocomplete", isUnlock ? "current-password" : "new-password");
  $("profile-dialog").showModal();
}
async function saveProfile(event) {
  event.preventDefault();
  const button = $("save-profile");
  button.disabled = true; $("profile-error").textContent = "正在儲存並測試 WebDAV…";
  try {
    const profile = await invoke("save_webdav_profile", {
      profileId: state.editingProfileId || null,
      name: $("profile-name").value.trim(),
      baseUrl: $("profile-url").value.trim(),
      username: $("profile-username").value.trim(),
      password: $("profile-password").value
    });
    $("profile-password").value = "";
    state.editingProfileId = "";
    await refreshProfiles(profile.id);
    state.unlockedProfileId = profile.id;
    await invoke("webdav_list_directory", { profileId: profile.id, path: "/" });
    $("profile-dialog").close();
    state.path = "/";
    localStorage.setItem(pathStorageKey(), state.path);
    await refreshShelf({ prefetch:false });
    setStatus("WebDAV 已連線 · 正在自動掃描書庫");
    await scanWebDavProfile(profile);
  } catch (error) {
    $("profile-error").textContent = error.message || String(error);
  } finally { button.disabled = false; }
}

function formatTransferSize(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024 * 1024) return Math.round(value / 1024) + " KB";
  return (value / 1024 / 1024).toFixed(value >= 1024 * 1024 * 1024 ? 2 : 1) +
    (value >= 1024 * 1024 * 1024 ? " GB" : " MB");
}
async function pullNativeTransferDiagnostics() {
  try {
    const items = await invoke("take_webdav_transfer_diagnostics");
    (Array.isArray(items) ? items : []).forEach(item => {
      const redirects = Array.isArray(item.redirectStatuses) ? item.redirectStatuses : [];
      const chain = redirects.concat(Number(item.finalStatus) || 0).filter(Boolean).map(status => "HTTP " + status).join(" → ");
      const is302 = redirects.includes(302);
      appendLog("INFO", "WebDAV EPUB 傳輸完成" + (is302 ? " · 302 直連" : ""),
        String(item.path || "") +
        "\n狀態鏈：" + (chain || "無狀態資料") +
        "\n302 跳轉：" + redirects.filter(status => status === 302).length + " 次；所有 3xx 跳轉：" + redirects.length + " 次" +
        "\n來源主機：" + String(item.sourceHost || "未知") +
        "\n最終主機：" + String(item.finalHost || "未知") +
        "\n實收：" + formatTransferSize(item.bytesReceived) +
        "；耗時：" + Number(item.elapsedMs || 0) + " ms；書檔傳送到 RAM");
    });
  } catch (error) { appendLog("ERROR", "讀取 WebDAV 傳輸診斷失敗", errorText(error)); }
}


let cloudPairCancelled = false;
function parseNativeJson(raw) {
  try { return typeof raw === "string" ? JSON.parse(raw) : raw; }
  catch (_) { throw new Error("Cloudflare 回傳的資料不是有效 JSON。"); }
}
async function cloudPairRequest(path, body) {
  const raw = await invoke("cloud_sync_request", {
    method: "POST", path, body: JSON.stringify(body || {})
  });
  const data = parseNativeJson(raw);
  if (data?.ok === false || data?.error) throw new Error(data.error || ("HTTP " + data.httpStatus));
  return data;
}
async function refreshCloudSyncDialog() {
  const credentials = await invoke("cloud_sync_get_credentials");
  const linked = !!credentials?.deviceToken;
  $("sync-account-status").textContent = linked
    ? "已連結 Cloudflare · " + String(credentials.deviceName || "FRAME Ebook") + "（設備授權已保存於本機）"
    : "尚未連結雲端帳號。完成配對後，這台 Mac 才能參與多設備同步。";
  $("start-cloud-pair").hidden = linked;
  $("sync-now-button").hidden = !linked;
  $("sync-refresh-catalog-button").hidden = !linked;
  $("disconnect-cloud-sync").hidden = !linked;
  $("sync-pair-panel").hidden = true;
  if (linked) {
    try { await macSyncManager?.refreshStatus(); } catch (_) {}
  }
}
async function beginCloudPairing() {
  cloudPairCancelled = false;
  $("start-cloud-pair").disabled = true;
  $("sync-account-status").textContent = "正在建立設備配對請求……";
  $("sync-pair-panel").hidden = true;
  $("cancel-cloud-pair").hidden = false;
  try {
    const start = await cloudPairRequest("/api/device/pair/start", { deviceName: "FRAME Ebook · macOS" });
    $("sync-user-code").textContent = start.userCode;
    $("sync-verification-link").href = start.verificationUrl || "https://frame-ebook.pages.dev/device-link/";
    $("sync-pair-expiry").textContent = "請在 10 分鐘內完成核准。配對代碼只用一次。";
    $("sync-pair-panel").hidden = false;
    $("sync-account-status").textContent = "等待你在網頁版核准這台 Mac……";
    const deadline = Number(start.expiresAt) || Date.now() + 10 * 60 * 1000;
    while (!cloudPairCancelled && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 2500));
      if (cloudPairCancelled) break;
      const result = await cloudPairRequest("/api/device/pair/poll", { deviceCode: start.deviceCode });
      if (result.status === "expired") throw new Error(result.error || "設備配對已過期。");
      if (result.status === "claimed") throw new Error(result.error || "設備配對已被兌換。");
      if (result.status === "approved" && result.deviceToken && result.deviceId) {
        await invoke("cloud_sync_save_credentials", {
          deviceId: result.deviceId,
          deviceToken: result.deviceToken,
          deviceName: result.deviceName || "FRAME Ebook · macOS"
        });
        $("sync-account-status").textContent = "設備已連結，正在執行首次雲端同步……";
        if (macSyncManager) {
          try { await macSyncManager.syncNow({ refreshCatalog: true }); }
          catch (syncError) { $("sync-last-result").textContent = syncError.message || String(syncError); }
        }
        $("sync-pair-panel").hidden = true;
        $("cancel-cloud-pair").hidden = true;
        $("start-cloud-pair").hidden = true;
        $("disconnect-cloud-sync").hidden = false;
        appendLog("INFO", "Mac 已完成 Cloudflare 設備配對", "設備 ID：" + result.deviceId);
        return;
      }
    }
    if (cloudPairCancelled) {
      $("sync-account-status").textContent = "已取消設備配對。";
    } else {
      throw new Error("設備配對逾時，請重新產生代碼。");
    }
  } catch (error) {
    $("sync-account-status").textContent = error.message || String(error);
    appendLog("ERROR", "Cloudflare 設備配對失敗", error.message || String(error));
  } finally {
    $("start-cloud-pair").disabled = false;
    $("cancel-cloud-pair").hidden = true;
  }
}
async function disconnectCloudSync() {
  const credentials = await invoke("cloud_sync_get_credentials");
  if (!credentials) return;
  let revokeError = null;
  try {
    const raw = await invoke("cloud_sync_request", { method:"POST", path:"/api/device/revoke", body:JSON.stringify({}) });
    const result = parseNativeJson(raw);
    if (!result.ok) throw new Error(result.error || "撤銷設備授權失敗。");
  } catch (error) { revokeError = error; }
  await invoke("cloud_sync_clear_credentials");
  await refreshCloudSyncDialog();
  appendLog(revokeError ? "WARN" : "INFO", "已解除這台 Mac 的本機雲端連結", revokeError ? "遠端撤銷未確認：" + (revokeError.message || String(revokeError)) : "");
}

function currentLogText() {
  return logState.entries.map(entry =>
    "[" + entry.time + "] [" + entry.level + "] " + entry.message +
    (entry.detail ? "\n" + entry.detail : "")
  ).join("\n");
}
$("open-logs").addEventListener("click", () => {
  renderLogs();
  $("logs-dialog").showModal();
});
$("close-logs").addEventListener("click", () => $("logs-dialog").close());
$("clear-logs").addEventListener("click", () => {
  logState.entries.length = 0;
  appendLog("INFO", "日誌已清空");
});
$("copy-logs").addEventListener("click", async () => {
  const text = currentLogText();
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      throw new Error("Clipboard API unavailable");
    }
    appendLog("INFO", "已複製目前日誌");
  } catch (_) {
    const helper = document.createElement("textarea");
    helper.value = text;
    helper.setAttribute("readonly", "");
    helper.style.position = "fixed";
    helper.style.opacity = "0";
    document.body.appendChild(helper);
    helper.select();
    const copied = document.execCommand("copy");
    helper.remove();
    appendLog(copied ? "INFO" : "ERROR", copied ? "已複製目前日誌" : "複製日誌失敗");
  }
});

$("sync-now-button").addEventListener("click", async () => {
  const button = $("sync-now-button");
  button.disabled = true;
  $("sync-last-result").textContent = "正在推送本機變更並拉取其他設備資料……";
  try {
    const result = await macSyncManager?.syncNow();
    $("sync-last-result").textContent = result
      ? "完成 · 推送 " + result.pushed + " 筆、拉取 " + result.pulled + " 筆"
      : "同步管理器尚未啟動。";
  } catch (error) {
    $("sync-last-result").textContent = error.message || String(error);
  } finally { button.disabled = false; }
});
$("sync-refresh-catalog-button").addEventListener("click", async () => {
  const button = $("sync-refresh-catalog-button");
  button.disabled = true;
  $("sync-last-result").textContent = "正在重新讀取 Cloudflare 書架索引……";
  try {
    const result = await macSyncManager?.syncNow({ refreshCatalog: true });
    $("sync-last-result").textContent = result
      ? "書架索引更新完成 · 推送 " + result.pushed + " 筆、拉取 " + result.pulled + " 筆"
      : "同步管理器尚未啟動。";
    await refreshShelf();
  } catch (error) {
    $("sync-last-result").textContent = error.message || String(error);
  } finally { button.disabled = false; }
});
$("cloud-sync-button").addEventListener("click", async () => {
  await refreshCloudSyncDialog();
  $("sync-dialog").showModal();
});
$("close-sync").addEventListener("click", () => $("sync-dialog").close());
$("start-cloud-pair").addEventListener("click", () => void beginCloudPairing());
$("cancel-cloud-pair").addEventListener("click", () => { cloudPairCancelled = true; });
$("disconnect-cloud-sync").addEventListener("click", () => void disconnectCloudSync().catch(error => {
  $("sync-account-status").textContent = error.message || String(error);
}));
$("add-profile").addEventListener("click", openProfileDialog);
$("close-profile").addEventListener("click", () => $("profile-dialog").close());
$("cancel-profile").addEventListener("click", () => $("profile-dialog").close());
$("profile-form").addEventListener("submit", saveProfile);
$("profile-select").addEventListener("change", async event => {
  state.unlockedProfileId = "";
  state.profileId = event.target.value;
  localStorage.setItem(profileStorageKey(), state.profileId);
  state.path = localStorage.getItem(pathStorageKey()) || "/";
  await refreshShelf({ prefetch:false });
  void startAutomaticLibraryScan(selectedProfile()).catch(() => {});
});
document.querySelectorAll("[data-tab]").forEach(button => button.addEventListener("click", () => showTab(button.dataset.tab)));
$("go-browser").addEventListener("click", () => showTab("browser"));
document.querySelectorAll("[data-open-browser]").forEach(button => button.addEventListener("click", () => showTab("browser")));
$("parent-folder").addEventListener("click", () => {
  state.path = parentPath(state.path);
  localStorage.setItem(pathStorageKey(), state.path);
  void loadDirectory();
});
$("refresh-folder").addEventListener("click", () => void loadDirectory());
$("add-folder-books").addEventListener("click", async () => {
  const files = state.entries.filter(item => !item.isDir && BOOK_EXTENSIONS.has(extension(item.path)));
  let count = 0;
  for (const file of files) { await addBook(file, false, false); count++; }
  await refreshShelf();
  setStatus("已加入 " + count + " 本書籍");
});
$("shelf-refresh").addEventListener("click", () => {
  void startAutomaticLibraryScan(selectedProfile()).catch(() => {});
});
async function boot() {
  appendLog("INFO", "FRAME Ebook 已啟動", "版本 0.3.1 · 本機書架與 Cloudflare 多設備同步");
  if (!window.__TAURI__ || !window.__TAURI__.core || !window.__TAURI__.core.invoke) {
    setStatus("原生桌面通道未啟動", true);
    return;
  }
  try {
    await refreshProfiles();
    macSyncManager = startMacSync({
      invoke: (name, args = {}) => window.__TAURI__.core.invoke(name, args),
      getProfiles: () => state.profiles,
      onStatus: message => {
        const status = $("sync-last-result");
        if (status) status.textContent = message;
      },
      onLog: (level, message, detail) => appendLog(level, message, detail),
      onCatalogUpdated: () => { void refreshShelf(); }
    });
    await refreshShelf({ prefetch:false });
    await pullNativeTransferDiagnostics();
    // Launch on the bookshelf, then index the active WebDAV source in the background.
    // Only directory metadata is traversed; EPUB/CBZ archives are never downloaded.
    if (state.profileId) {
      setStatus("書架已開啟 · 正在檢查 WebDAV 書庫");
      void startAutomaticLibraryScan(selectedProfile()).catch(() => {});
    } else {
      setStatus("本機就緒 · 尚未設定 WebDAV 來源");
    }
  } catch (error) { setStatus(error.message || String(error), true); }
}
window.addEventListener("pageshow", event => {
  if (event.persisted) { void refreshShelf(); void pullNativeTransferDiagnostics(); }
});
void boot();
