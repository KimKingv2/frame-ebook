import * as store from "/assets/library-store.js?v=20261117-mac-local-r1";
const $ = id => document.getElementById(id);
const invoke = (name, args = {}) => window.__TAURI__.core.invoke(name, args);
const state = { profiles: [], profileId: "", path: "/", entries: [], tab: "shelf", busy: false };
const BOOK_EXTENSIONS = new Set(["epub", "cbz"]);
function setStatus(message, error = false) {
  const node = $("connection-status");
  node.replaceChildren();
  const dot = document.createElement("i");
  node.appendChild(dot);
  node.appendChild(document.createTextNode(" " + String(message || "")));
  node.classList.toggle("is-error", !!error);
}
function extension(path) {
  const match = String(path || "").match(/\.([^.\/]+)$/);
  return match ? match[1].toLowerCase() : "";
}
function baseTitle(name) { return String(name || "").replace(/\.(epub|cbz)$/i, ""); }
function selectedProfile() { return state.profiles.find(item => item.id === state.profileId) || null; }
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
    option.value = profile.id; option.textContent = profile.name;
    select.appendChild(option);
  });
  select.value = state.profileId;
}
async function refreshProfiles(preferredId = "") {
  state.profiles = await invoke("list_webdav_profiles");
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
function renderShelf(books) {
  const grid = $("shelf-grid");
  grid.replaceChildren();
  $("shelf-empty").hidden = books.length > 0;
  books.forEach(book => {
    const card = document.createElement("article"); card.className = "book-card";
    const cover = document.createElement("div"); cover.className = "book-cover";
    const label = document.createElement("span"); label.textContent = String(book.format || "EPUB").toUpperCase();
    const title = document.createElement("strong"); title.textContent = book.title || book.fileName || "未命名書籍";
    cover.append(label, title);
    const info = document.createElement("div"); info.className = "book-info";
    const heading = document.createElement("h3"); heading.textContent = book.title || book.fileName;
    const meta = document.createElement("p"); meta.textContent = (book.cloudSource && book.cloudSource.path || "") + (book.progress && book.progress.percent ? " · " + Math.round(book.progress.percent) + "% 已讀" : "");
    const row = document.createElement("div"); row.className = "book-meta";
    const source = document.createElement("span"); source.textContent = "WEBDAV";
    const size = document.createElement("span"); size.textContent = formatSize(book.size);
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
    info.append(heading, meta, row, actions); card.append(cover, info); grid.appendChild(card);
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
    state.entries = await invoke("webdav_list_directory", { profileId: profile.id, path: state.path });
    renderEntries(state.entries);
    setStatus("WebDAV 已連線 · " + profile.name);
  } catch (error) {
    setStatus(error.message || String(error), true);
    $("browser-empty").hidden = false;
    $("browser-empty").querySelector("h3").textContent = "無法讀取這個資料夾";
    $("browser-empty").querySelector("p").textContent = error.message || String(error);
  } finally { state.busy = false; }
}
function openProfileDialog() {
  $("profile-error").textContent = "";
  $("profile-name").value = "";
  $("profile-url").value = "";
  $("profile-username").value = "";
  $("profile-password").value = "";
  $("profile-dialog").showModal();
}
async function saveProfile(event) {
  event.preventDefault();
  const button = $("save-profile");
  button.disabled = true; $("profile-error").textContent = "正在儲存並測試 WebDAV…";
  try {
    const profile = await invoke("save_webdav_profile", {
      name: $("profile-name").value.trim(),
      baseUrl: $("profile-url").value.trim(),
      username: $("profile-username").value.trim(),
      password: $("profile-password").value
    });
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
  if (!window.__TAURI__ || !window.__TAURI__.core || !window.__TAURI__.core.invoke) {
    setStatus("原生桌面通道未啟動", true);
    return;
  }
  try {
    await refreshProfiles();
    await refreshShelf();
    if (state.profileId) {
      await loadDirectory();
    } else {
      setStatus("本機就緒 · 請新增 WebDAV 來源");
    }
  } catch (error) { setStatus(error.message || String(error), true); }
}
void boot();
