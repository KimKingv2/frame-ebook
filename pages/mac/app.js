import * as store from "/assets/library-store.js?v=20261117-mac-cover-r1";
const $ = id => document.getElementById(id);
const LOG_LIMIT = 500;
const logState = { entries: [] };
const shelfCoverUrls = [];
const state = { profiles: [], profileId: "", editingProfileId: "", path: "/", entries: [], tab: "shelf", busy: false, lastStatus: "" };
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
  const trackSuccess = !["webdav_read_range", "take_webdav_transfer_diagnostics"].includes(name);
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
function clearShelfCoverUrls() {
  shelfCoverUrls.forEach(url => URL.revokeObjectURL(url));
  shelfCoverUrls.length = 0;
}
function makeShelfFallback(book) {
  const fallback = document.createElement("div"); fallback.className = "book-cover-fallback";
  const top = document.createElement("span"); top.className = "book-cover-fallback-top"; top.textContent = "FRAME READER";
  const title = document.createElement("strong"); title.textContent = book.title || book.fileName || "未命名書籍";
  const bottom = document.createElement("small"); bottom.textContent =
    String(book.format || "").toUpperCase() === "CBZ" ? "COMIC EDITION" : "READING EDITION";
  fallback.append(top, title, bottom);
  return fallback;
}
function renderShelf(books) {
  const grid = $("shelf-grid");
  clearShelfCoverUrls();
  grid.replaceChildren();
  $("shelf-empty").hidden = books.length > 0;
  books.forEach(book => {
    const card = document.createElement("article"); card.className = "book-card";
    const cover = document.createElement("div"); cover.className = "book-cover";
    cover.setAttribute("role", "button"); cover.setAttribute("tabindex", "0");
    cover.setAttribute("aria-label", "閱讀 " + (book.title || book.fileName || "未命名書籍"));
    const openCover = () => openBook(book);
    cover.addEventListener("click", openCover);
    cover.addEventListener("keydown", event => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); openCover(); }
    });
    if (book.coverBlob instanceof Blob && book.coverBlob.size) {
      const image = document.createElement("img");
      image.className = "book-cover-image";
      image.src = URL.createObjectURL(book.coverBlob);
      shelfCoverUrls.push(image.src);
      image.alt = (book.title || book.fileName || "書籍") + " 封面";
      image.loading = "lazy"; image.decoding = "async";
      image.addEventListener("error", () => { image.remove(); cover.prepend(makeShelfFallback(book)); }, { once: true });
      cover.appendChild(image);
    } else {
      cover.appendChild(makeShelfFallback(book));
    }
    const badge = document.createElement("span"); badge.className = "book-cover-badge";
    badge.textContent = String(book.format || "EPUB").toUpperCase();
    const affordance = document.createElement("span"); affordance.className = "book-cover-open"; affordance.textContent = "↗";
    cover.append(badge, affordance);

    const info = document.createElement("div"); info.className = "book-info";
    const heading = document.createElement("h3"); heading.textContent = book.title || book.fileName || "未命名書籍";
    const description = document.createElement("p");
    description.textContent = book.author || (String(book.format).toUpperCase() === "CBZ" ? "漫畫／圖像書" : "電子書");
    const row = document.createElement("div"); row.className = "book-meta";
    const source = document.createElement("span"); source.textContent = "WEBDAV";
    const progress = Number(book.progress && book.progress.percent) || 0;
    const size = document.createElement("span"); size.textContent = progress > 0 ? Math.round(progress) + "% 已讀" : formatSize(book.size);
    row.append(source, size);
    const actions = document.createElement("div"); actions.className = "book-actions";
    const open = document.createElement("button"); open.className = "button primary"; open.type = "button"; open.textContent = "繼續閱讀";
    open.addEventListener("click", () => openBook(book));
    const remove = document.createElement("button"); remove.className = "button subtle"; remove.type = "button"; remove.textContent = "移除";
    remove.addEventListener("click", async () => {
      await store.removeLocalBook(book.id);
      await refreshShelf();
      setStatus("已從本機書架移除");
    });
    actions.append(open, remove);
    info.append(heading, description, row, actions); card.append(cover, info); grid.appendChild(card);
  });
}
async function refreshShelf() {
  try { renderShelf(await store.listBooks()); }
  catch (error) { setStatus(error.message || String(error), true); }
}
function readerUrl(book) {
  const source = book.cloudSource || {};
  const query = new URLSearchParams({
    book: String(book.id), provider: String(source.provider || "webdav"),
    library: String(source.library || book.shelf || "books"),
    root_path: String(source.rootPath || "/"), path: String(source.path || ""),
    profile_id: String(source.profileId || "")
  });
  return "/epub-lab/?" + query.toString();
}
function openBook(book) { window.location.href = readerUrl(book); }
async function addBook(entry, openAfter = false) {
  const profile = selectedProfile();
  if (!profile || !entry || entry.isDir) return;
  const ext = extension(entry.path);
  if (!BOOK_EXTENSIONS.has(ext)) return;
  const library = ext === "cbz" ? "comics" : "books";
  const scope = { provider: "webdav", profileId: profile.id, library };
  appendLog("INFO", "準備加入書籍", entry.path);
  const id = await store.cloudBookId(scope, entry.path);
  const record = {
    id, sourceType: "cloud", provider: "webdav", library, rootPath: "/",
    path: entry.path, fileName: entry.name, title: baseTitle(entry.name),
    author: "", format: ext.toUpperCase(), shelf: library,
    size: Number(entry.size) || 0,
    progress: { percent: 0, label: "尚未閱讀", cfi: "", index: null },
    appearance: {},
    cloudSource: { provider: "webdav", profileId: profile.id, library, rootPath: "/", path: entry.path }
  };
  await store.addLocalBook(record);
  appendLog("INFO", "書籍已加入本機書架", entry.path);
  await refreshShelf();
  setStatus("已加入書架 · " + entry.name);
  if (openAfter) openBook(record);
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
  if (state.busy) return;
  const profile = selectedProfile();
  if (!profile) { setStatus("請先新增 WebDAV 來源", true); return; }
  state.busy = true;
  setStatus("正在讀取 WebDAV…");
  $("file-list").replaceChildren();
  $("current-path").textContent = state.path;
  try {
    const authenticated = await invoke("webdav_has_password", { profileId: profile.id });
    if (!authenticated) {
      openProfileDialog(profile);
      setStatus("請重新輸入「" + profile.name + "」的密碼；密碼只保留在 RAM。");
      return;
    }
    state.entries = await invoke("webdav_list_directory", { profileId: profile.id, path: state.path });
    renderEntries(state.entries);
    appendLog("INFO", "目錄讀取成功", state.path + " · " + state.entries.length + " 個項目");
    setStatus("WebDAV 已連線 · " + profile.name);
  } catch (error) {
    setStatus(error.message || String(error), true);
    $("browser-empty").hidden = false;
    $("browser-empty").querySelector("h3").textContent = "無法讀取這個資料夾";
    $("browser-empty").querySelector("p").textContent = error.message || String(error);
  } finally { state.busy = false; }
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
    await invoke("webdav_list_directory", { profileId: profile.id, path: "/" });
    $("profile-dialog").close();
    state.path = "/";
    localStorage.setItem(pathStorageKey(), state.path);
    await refreshShelf();
    showTab("browser");
    await loadDirectory();
    setStatus("WebDAV 連線成功 · " + profile.name);
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

$("add-profile").addEventListener("click", openProfileDialog);
$("close-profile").addEventListener("click", () => $("profile-dialog").close());
$("cancel-profile").addEventListener("click", () => $("profile-dialog").close());
$("profile-form").addEventListener("submit", saveProfile);
$("profile-select").addEventListener("change", async event => {
  state.profileId = event.target.value;
  localStorage.setItem(profileStorageKey(), state.profileId);
  state.path = localStorage.getItem(pathStorageKey()) || "/";
  await loadDirectory();
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
  for (const file of files) { await addBook(file, false); count++; }
  setStatus("已加入 " + count + " 本書籍");
});
async function boot() {
  appendLog("INFO", "FRAME Ebook 已啟動", "版本 0.2.6 · 日誌僅保存在目前 App 記憶體");
  if (!window.__TAURI__ || !window.__TAURI__.core || !window.__TAURI__.core.invoke) {
    setStatus("原生桌面通道未啟動", true);
    return;
  }
  try {
    await refreshProfiles();
    await refreshShelf();
    await pullNativeTransferDiagnostics();
    if (state.profileId) {
      await loadDirectory();
    } else {
      setStatus("本機就緒 · 請新增 WebDAV 來源");
    }
  } catch (error) { setStatus(error.message || String(error), true); }
}
window.addEventListener("pageshow", event => {
  if (event.persisted) { void refreshShelf(); void pullNativeTransferDiagnostics(); }
});
void boot();
