import { listBooks, getBook, updateBook } from "/assets/library-store.js?v=20261117-filename-id-r2";

const $ = id => document.getElementById(id);
const state = { books: [], query: "", sort: "recent", view: "grid", dialogBookId: null, linkTargetBookId: null, activeFolderKey: null };
const readerUrl = book => {
  const source = book?.cloudSource || {};
  const query = new URLSearchParams({
    book: String(book?.id || ""),
    provider: String(source.provider || ""),
    library: String(source.library || ""),
    root_path: String(source.rootPath || ""),
    path: String(source.path || "")
  });
  return "/epub-lab/?" + query.toString();
};

function getBookShelf(book) {
  return book?.format === "CBZ" || book?.shelf === "comics" ? "comics" : "books";
}
function formatSize(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024 * 1024) return (value / 1024).toFixed(0) + " KB";
  return (value / (1024 * 1024)).toFixed(value >= 1024 * 1024 * 1024 ? 2 : 1) +
    (value >= 1024 * 1024 * 1024 ? " GB" : " MB");
}
function formatDate(timestamp) {
  if (!timestamp) return "雲端索引";
  try { return new Intl.DateTimeFormat("zh-TW", { year: "numeric", month: "short", day: "numeric" }).format(new Date(timestamp)); }
  catch (_) { return ""; }
}
function makeFallback(book) {
  const node = document.createElement("div");
  node.className = "library-cover-fallback";
  const top = document.createElement("span"); top.textContent = "FRAME READER";
  const title = document.createElement("strong"); title.textContent = book.title || "未命名書籍";
  const bottom = document.createElement("small"); bottom.textContent = getBookShelf(book) === "comics" ? "COMIC EDITION" : "READING EDITION";
  node.append(top, title, bottom);
  return node;
}
function compareFolderFiles(a, b) {
  const nameA = String(a?.fileName || a?.name || "");
  const nameB = String(b?.fileName || b?.name || "");
  return nameA.localeCompare(nameB, "zh-Hant", { numeric: true, sensitivity: "base" });
}
function makeCover(book, compact) {
  const frame = document.createElement("div");
  frame.className = "cover-frame library-cover" + (compact ? " library-cover-compact" : "");
  const isFolderCard = Array.isArray(book._groupMembers) && book._groupMembers.length > 0;

  if (isFolderCard) {
    frame.classList.add("library-folder-cover");
    frame.setAttribute("aria-label", (book.folderTitle || book.title || "資料夾") + " 封面");
    const members = book._groupMembers.slice().sort(compareFolderFiles).slice(0, 3);
    if (members.length > 1) {
      const stack = document.createElement("div");
      stack.className = "library-cover-stack";
      stack.setAttribute("aria-label", "中央為檔名排序第一本書的封面，左右展示後續冊次");
      const visualMembers = members.length === 3
        ? [members[1], members[0], members[2]]
        : [members[1], members[0]];

      visualMembers.forEach((member, index) => {
        const sheet = document.createElement("div");
        sheet.className = "library-cover-stack-book";
        const hash = member.cloudCoverStatus === "ready" && /^[a-f0-9]{64}$/i.test(String(member.cloudCoverHash || ""))
          ? member.cloudCoverHash : "";
        if (hash) {
          const image = document.createElement("img");
          image.src = "/api/cloud/covers?hash=" + encodeURIComponent(hash);
          image.alt = member.fileName || member.title || "書籍封面";
          image.loading = "lazy";
          image.decoding = "async";
          image.addEventListener("error", () => {
            sheet.classList.add("is-fallback");
            sheet.replaceChildren();
          }, { once: true });
          sheet.appendChild(image);
        } else {
          sheet.classList.add("is-fallback");
        }
        stack.appendChild(sheet);
      });
      frame.appendChild(stack);
    } else {
      const member = members[0] || book;
      const hash = member.cloudCoverStatus === "ready" && /^[a-f0-9]{64}$/i.test(String(member.cloudCoverHash || ""))
        ? member.cloudCoverHash : "";
      if (hash) {
        const image = document.createElement("img");
        image.src = "/api/cloud/covers?hash=" + encodeURIComponent(hash);
        image.alt = member.fileName || member.title || "書籍封面";
        image.loading = "lazy";
        image.decoding = "async";
        image.addEventListener("error", () => {
          image.remove();
          frame.classList.add("library-folder-cover-empty");
        }, { once: true });
        frame.appendChild(image);
      } else {
        frame.classList.add("library-folder-cover-empty");
      }
    }
  } else {
    frame.setAttribute("aria-label", (book.title || "作品") + " 封面");
    const hash = book.cloudCoverHash && book.cloudCoverStatus === "ready"
      ? book.cloudCoverHash
      : (book.cloudCoverHashes || []).find(value => /^[a-f0-9]{64}$/i.test(String(value))) || "";
    if (hash) {
      const image = document.createElement("img");
      image.src = "/api/cloud/covers?hash=" + encodeURIComponent(hash);
      image.alt = (book.title || "作品") + " 封面";
      image.loading = "lazy";
      image.decoding = "async";
      image.addEventListener("error", () => {
        image.remove();
        frame.appendChild(makeFallback(book));
      }, { once: true });
      frame.appendChild(image);
    } else {
      frame.appendChild(makeFallback(book));
    }

    const format = document.createElement("span");
    format.className = "library-format-badge";
    format.textContent = book.format || "";
    frame.appendChild(format);
  }
  return frame;
}
function createCard(book, compact) {
  const article = document.createElement("article");
  const folderGroup = Array.isArray(book._groupMembers) && book._groupMembers.length > 0;
  article.className = "book-card library-card" + (compact ? " library-card-compact" : "") + (folderGroup ? " library-folder-card" : "");
  const open = document.createElement("a");
  open.className = "library-card-open";
  open.href = folderGroup ? "#folder-detail" : readerUrl(book);
  open.setAttribute("aria-label", folderGroup ? "開啟資料夾 " + book.title : "開啟 " + book.title);
  if (folderGroup) open.addEventListener("click", event => { event.preventDefault(); openFolderDetails(book); });
  open.appendChild(makeCover(book, compact));

  const meta = document.createElement("div"); meta.className = "book-meta library-book-meta";
  const copy = document.createElement("div");
  const title = document.createElement("h3"); title.textContent = book.title || book.fileName;
  const author = document.createElement("p"); author.textContent = book.author || (getBookShelf(book) === "comics" ? "漫畫／圖像書" : "作者未提供");
  copy.append(title, author);
  if (book._isFolderVolume) {
    const fileName = document.createElement("small");
    fileName.className = "library-volume-filename";
    fileName.textContent = book.fileName || "";
    copy.appendChild(fileName);
  }
  const kind = document.createElement("span"); kind.className = "book-kind";
  kind.textContent = folderGroup ? (Number(book.volumeCount) || book._groupMembers.length) + " 冊" : book.format;
  meta.append(copy, kind);

  const progress = document.createElement("div"); progress.className = "library-progress";
  const track = document.createElement("span"); track.className = "library-progress-track";
  const fill = document.createElement("span"); fill.className = "library-progress-fill";
  const percent = Math.max(0, Math.min(100, Number(book.progress?.percent) || 0));
  fill.style.width = percent + "%"; track.appendChild(fill);
  const label = document.createElement("small");
  if (folderGroup) track.hidden = true;
  label.textContent = folderGroup
    ? (Number(book.volumeCount) || book._groupMembers.length) + " 本作品，點擊查看資料夾"
    : percent > 0 ? Math.round(percent) + "% · " + (book.progress.label || "閱讀中") : "尚未開始";
  progress.append(track, label);

  const actions = document.createElement("div"); actions.className = "library-card-actions";
  const continueLink = document.createElement("a");
  continueLink.href = folderGroup ? "#folder-detail" : readerUrl(book); continueLink.className = "library-open-link";
  continueLink.textContent = folderGroup ? "開啟資料夾 ↗" : percent > 0 ? "繼續閱讀 ↗" : "開始閱讀 ↗";
  if (folderGroup) continueLink.addEventListener("click", event => { event.preventDefault(); openFolderDetails(book); });
  const details = document.createElement("button");
  details.type = "button"; details.className = "library-details-button";
  details.textContent = folderGroup ? "查看卷冊" : "作品資訊";
  details.addEventListener("click", () => folderGroup ? openFolderDetails(book) : showBookDetails(book.id));
  actions.append(continueLink, details);
  article.append(open, meta, progress, actions);
  return article;
}
function folderGroupKey(book) {
  const source = book?.cloudSource || {};
  const folderPath = String(source.folderPath || "");
  return folderPath ? [source.provider, source.library, source.rootPath, folderPath].join("\n") : "";
}
function groupedShelfBooks() {
  const groups = new Map(), output = [];
  for (const book of state.books) {
    const source = book.cloudSource || {};
    const folderPath = String(source.folderPath || "");
    if (!folderPath) { output.push(book); continue; }
    const key = folderGroupKey(book);
    let group = groups.get(key);
    if (!group) {
      group = {
        ...book,
        _folderKey: key,
        title: book.comicMetadata?.nameCn || book.comicMetadata?.name ||
          book.folderTitle || folderPath.split("/").pop() || book.title || book.bookTitle,
        folderTitle: book.folderTitle || folderPath.split("/").pop() || "",
        cloudCoverHashes: [],
        cloudSource: { ...source, files: [] },
        _groupMembers: [], volumeCount: 0, size: 0
      };
      groups.set(key, group); output.push(group);
    }
    group._groupMembers.push(book);
    group.volumeCount += 1;
    group.size += Math.max(0, Number(book.size) || 0);
    group.lastOpenedAt = Math.max(Number(group.lastOpenedAt) || 0, Number(book.lastOpenedAt) || 0);
    group.cloudSource.files.push({
      path: String(source.path || ""), name: String(book.fileName || ""), format: String(book.format || ""),
      size: Math.max(0, Number(book.size) || 0), coverHash: book.cloudCoverHash || null,
      coverStatus: book.cloudCoverStatus || "pending"
    });
  }
  for (const group of groups.values()) {
    group._groupMembers.sort(compareFolderFiles);
    group.cloudCoverHashes = [...new Set(group._groupMembers
      .filter(member => member.cloudCoverStatus === "ready" && /^[a-f0-9]{64}$/i.test(String(member.cloudCoverHash || "")))
      .map(member => member.cloudCoverHash))].slice(0, 8);
    const fileMap = new Map();
    for (const file of group.cloudSource.files) if (file.path) fileMap.set(file.path, file);
    group.cloudSource.files = [...fileMap.values()].sort((a,b) =>
      String(a.name || "").localeCompare(String(b.name || ""), "zh-Hant", { numeric: true, sensitivity: "base" }));
  }
  return output;
}
function filteredBooks() {
  const query = state.query.trim().toLocaleLowerCase();
  let books = groupedShelfBooks().filter(book => {
    if (!query) return true;
    const memberText = Array.isArray(book._groupMembers)
      ? book._groupMembers.map(item => [item.fileName,item.title,item.format].join(" ")).join(" ") : "";
    const bangumiText = book.comicMetadata ? [book.comicMetadata.name,book.comicMetadata.nameCn,book.comicMetadata.author,
      ...(book.comicMetadata.tags || []).map(tag => tag?.name || tag)].join(" ") : "";
    return [book.title,book.author,book.fileName,book.format,memberText,bangumiText].join(" ").toLocaleLowerCase().includes(query);
  }).slice();
  if (state.sort === "title") books.sort((a,b) => (a.title || "").localeCompare(b.title || "", "zh-Hant"));
  else if (state.sort === "added") books.sort((a,b) => (b.addedAt || 0) - (a.addedAt || 0));
  else if (state.sort === "progress") books.sort((a,b) => (Number(b.progress?.percent)||0) - (Number(a.progress?.percent)||0));
  else books.sort((a,b) => (b.lastOpenedAt || 0) - (a.lastOpenedAt || 0));
  return books;
}
function folderVolumeTitle(volume) {
  if (volume.manualTitle && volume.title) return volume.title;
  const fileName = String(volume.fileName || volume.title || "未命名檔案");
  const fileStem = fileName.replace(/\.(epub|cbz)$/i, "");
  if (getBookShelf(volume) === "comics") return fileStem;
  return volume.bookTitle || fileStem;
}
function folderVolumeAuthor(volume) {
  if (volume.manualAuthor) return volume.author || "";
  return volume.bookCreator || volume.author || "";
}
function openFolderDetails(book) {
  const key = book?._folderKey || folderGroupKey(book);
  if (!key || !Array.isArray(book?._groupMembers)) return;
  state.activeFolderKey = key;
  render();
  $("folder-detail").scrollIntoView({ behavior: "smooth", block: "start" });
}
function renderFolderDetail() {
  const shelves = groupedShelfBooks();
  const folder = state.activeFolderKey ? shelves.find(item => item._folderKey === state.activeFolderKey) : null;
  if (state.activeFolderKey && !folder) state.activeFolderKey = null;
  const active = !!folder;
  $("library-hero").hidden = active;
  $("library-stats").hidden = active;
  $("recent-section").hidden = active || $("recent-grid").childElementCount === 0;
  $("library").hidden = active;
  $("library-privacy").hidden = active;
  $("library-bottom-banner").hidden = active;
  $("folder-detail").hidden = !active;
  if (!active) return;

  const source = folder.cloudSource || {};
  const volumes = [...folder._groupMembers].sort((a, b) =>
    String(a.fileName || "").localeCompare(String(b.fileName || ""), "zh-Hant", { numeric: true, sensitivity: "base" }) ||
    String(a.cloudSource?.path || "").localeCompare(String(b.cloudSource?.path || ""), "zh-Hant", { numeric: true, sensitivity: "base" }));
  const totalSize = volumes.reduce((sum, volume) => sum + Math.max(0, Number(volume.size) || 0), 0);
  $("folder-detail-title").textContent = folder.title || folder.folderTitle || "未命名資料夾";
  $("folder-detail-path").textContent = source.folderPath || "雲端資料夾";
  $("folder-detail-count").textContent = volumes.length + " 冊 · " + formatSize(totalSize);
  $("folder-detail-status").textContent = "這個資料夾共有 " + volumes.length + " 個可閱讀檔案。選擇下方任一本作品即可進入閱讀室。";
  const grid = $("folder-books-grid");
  grid.replaceChildren();
  volumes.forEach(volume => grid.appendChild(createCard({
    ...volume,
    title: folderVolumeTitle(volume),
    author: folderVolumeAuthor(volume),
    _isFolderVolume: true
  }, false)));
  $("folder-detail-empty").hidden = volumes.length > 0;
}
function renderCategoryShelf(allItems, visibleItems, gridId, emptyId, searchEmptyId, countId) {
  const grid = $(gridId), empty = $(emptyId), searchEmpty = $(searchEmptyId);
  grid.classList.toggle("is-list", state.view === "list");
  grid.replaceChildren();
  visibleItems.forEach(book => grid.appendChild(createCard(book, false)));
  $(countId).textContent = String(allItems.length).padStart(2, "0");
  empty.hidden = allItems.length > 0;
  searchEmpty.hidden = allItems.length === 0 || visibleItems.length > 0;
  grid.hidden = visibleItems.length === 0;
}
function render() {
  const shelves = groupedShelfBooks(), total = shelves.length;
  const started = shelves.filter(book => Number(book.progress?.percent) > 0).length;
  const allBooks = shelves.filter(book => getBookShelf(book) === "books");
  const allComics = shelves.filter(book => getBookShelf(book) === "comics");
  $("book-count").textContent = String(total).padStart(2, "0");
  $("started-count").textContent = String(started).padStart(2, "0");
  $("epub-count").textContent = String(allBooks.length).padStart(2, "0");
  $("comic-count").textContent = String(allComics.length).padStart(2, "0");
  const recent = shelves.filter(book => Number(book.lastOpenedAt) > 0)
    .sort((a,b) => b.lastOpenedAt - a.lastOpenedAt).slice(0,3);
  $("recent-grid").replaceChildren();
  $("recent-section").hidden = recent.length === 0;
  recent.forEach(book => $("recent-grid").appendChild(createCard(book, true)));
  const visible = filteredBooks();
  renderCategoryShelf(allBooks, visible.filter(book => getBookShelf(book) === "books"), "books-grid", "books-empty", "books-search-empty", "books-shelf-count");
  renderCategoryShelf(allComics, visible.filter(book => getBookShelf(book) === "comics"), "comics-grid", "comics-empty", "comics-search-empty", "comics-shelf-count");
  $("shelf-count-label").textContent = total + " ITEM" + (total === 1 ? "" : "S");
  $("result-count").textContent = "目前顯示 " + visible.filter(book => getBookShelf(book) === "books").length +
    " 本電子書 · " + visible.filter(book => getBookShelf(book) === "comics").length + " 部漫畫";
  $("view-grid").setAttribute("aria-pressed", state.view === "grid" ? "true" : "false");
  $("view-list").setAttribute("aria-pressed", state.view === "list" ? "true" : "false");
  renderFolderDetail();
}
async function refresh() {
  $("library-status").textContent = "正在讀取雲端書架索引……";
  try {
    state.books = await listBooks();
    render();
    const books = groupedShelfBooks().filter(book => getBookShelf(book) === "books").length;
    const comics = groupedShelfBooks().filter(book => getBookShelf(book) === "comics").length;
    $("library-status").textContent = "雲端書架已載入：電子書 " + books + " 本、漫畫 " + comics + " 部。書目及閱讀記憶由 D1 同步保存。";
  } catch (error) {
    $("library-status").textContent = "雲端書架載入失敗：" + (error.message || String(error));
    $("books-grid").hidden = true; $("comics-grid").hidden = true;
  }
}
async function showBookDetails(id) {
  const book = await getBook(id);
  if (!book) return;
  state.dialogBookId = id;
  state.linkTargetBookId = id;
  $("detail-heading").textContent = getBookShelf(book) === "comics" ? "漫畫資訊" : "電子書資訊";
  $("detail-title").value = book.title || "";
  $("detail-shelf").value = getBookShelf(book);
  $("detail-shelf").disabled = book.format === "CBZ";
  $("detail-shelf-note").textContent = book.format === "CBZ"
    ? "CBZ 圖像封存固定放在漫畫書架。" : "分類與自訂資訊會保存在你的雲端帳戶。";
  $("detail-author").value = book.author || "";
  $("detail-format").textContent = book.format;
  $("detail-file").textContent = book.fileName;
  $("detail-size").textContent = formatSize(book.size);
  $("detail-pages").textContent = book.pageCount ? book.pageCount + (book.format === "CBZ" ? " 頁" : " 個內容項目") : "未提供";
  $("detail-added").textContent = formatDate(book.addedAt);
  $("detail-progress").textContent = book.progress?.percent > 0
    ? Math.round(book.progress.percent) + "% · " + (book.progress.label || "閱讀中") : "尚未開始";
  const extraMetadata = [];
  if (book.language) extraMetadata.push("語言：" + book.language);
  if (book.publisher) extraMetadata.push("出版社：" + book.publisher);
  if (book.publishedAt) extraMetadata.push("出版日期：" + book.publishedAt);
  if (book.identifier) extraMetadata.push("識別碼：" + book.identifier);
  if (Array.isArray(book.subjects) && book.subjects.length) extraMetadata.push("主題：" + book.subjects.join("、"));
  if (book.description) extraMetadata.push("簡介：" + book.description);
  $("detail-extra-metadata").textContent = extraMetadata.join("\n") || "尚未讀取到其他內部書籍資訊。";
  $("detail-extra-metadata").hidden = getBookShelf(book) !== "books" || extraMetadata.length === 0;
  $("detail-reset-opf").hidden = getBookShelf(book) !== "books" || (!book.manualTitle && !book.manualAuthor);

  const bangumiSection = $("detail-bangumi-section");
  const bangumiStatus = $("detail-bangumi-status");
  const bangumiCurrent = $("detail-bangumi-current");
  const bangumiResults = $("detail-bangumi-results");
  const isComic = getBookShelf(book) === "comics";
  bangumiSection.hidden = !isComic;
  bangumiResults.replaceChildren();
  bangumiResults.hidden = true;
  bangumiStatus.textContent = "";
  $("detail-bangumi-query").value = book.comicMetadata?.nameCn || book.comicMetadata?.name ||
    book.folderTitle || book.title || "";
  if (book.comicMetadata) {
    const meta = book.comicMetadata;
    bangumiCurrent.hidden = false;
    bangumiCurrent.textContent = "已關聯 Bangumi：" + (meta.nameCn || meta.name || ("條目 " + meta.subjectId)) +
      (meta.author ? "\n作者：" + meta.author : "") +
      (meta.date ? "\n日期：" + meta.date : "") +
      (meta.score ? "\n評分：" + meta.score + (meta.ratingCount ? "（" + meta.ratingCount + " 人）" : "") : "") +
      "\n已套用到同資料夾卷冊。";
  } else {
    bangumiCurrent.hidden = true;
    bangumiCurrent.textContent = "";
  }
  const volumeSection = $("detail-volumes-section"), volumeList = $("detail-volume-list");
  volumeList.replaceChildren();
  const source = book.cloudSource || {};
  const siblings = source.folderPath ? state.books.filter(item => {
    const s = item.cloudSource || {};
    return s.provider === source.provider && s.library === source.library &&
      s.rootPath === source.rootPath && s.folderPath === source.folderPath;
  }).sort((a,b) => String(a.fileName).localeCompare(String(b.fileName),"zh-Hant",{numeric:true,sensitivity:"base"})) : [];
  volumeSection.hidden = siblings.length < 2;
  if (siblings.length > 1) {
    $("detail-volumes-heading").textContent = "資料夾內冊數（" + siblings.length + "）";
    siblings.forEach((volume,index) => {
      const link = document.createElement("a"); link.className = "dialog-volume-link" + (volume.id === book.id ? " is-current" : "");
      link.href = readerUrl(volume);
      const name = document.createElement("span"); name.textContent = (index + 1) + ". " + (volume.fileName || volume.title || "未命名檔案");
      const meta = document.createElement("small");
      const percent = Math.max(0,Math.min(100,Number(volume.progress?.percent)||0));
      meta.textContent = volume.format + (percent > 0 ? " · " + Math.round(percent) + "%" : "");
      link.append(name,meta); volumeList.appendChild(link);
    });
  }
  const linkTargets = siblings.length > 1 ? siblings : [book];
  const targetSelect = $("detail-link-target");
  targetSelect.replaceChildren();
  linkTargets.forEach(volume => {
    const option = document.createElement("option");
    option.value = volume.id;
    option.textContent = volume.fileName || volume.title || "未命名檔案";
    targetSelect.appendChild(option);
  });
  $("detail-link-target-wrap").hidden = linkTargets.length < 2;
  targetSelect.value = book.id;
  state.linkTargetBookId = book.id;
  $("detail-link-status").hidden = true;
  $("detail-link-status").textContent = "";
  $("detail-link-candidates").hidden = true;
  $("detail-link-candidates").replaceChildren();
  $("detail-link-open").disabled = false;
  const dialog = $("book-dialog");
  if (typeof dialog.showModal === "function") dialog.showModal(); else dialog.setAttribute("open", "");
}
function bookDescriptor(book) {
  const source = book?.cloudSource || {};
  return {
    id: String(book?.id || ""),
    provider: String(source.provider || ""),
    library: String(source.library || ""),
    rootPath: String(source.rootPath || ""),
    path: String(source.path || "")
  };
}

function formatReadingTime(seconds) {
  const total = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours) return hours + " 小時 " + minutes + " 分鐘";
  if (minutes) return minutes + " 分鐘";
  return total ? total + " 秒" : "沒有閱讀紀錄";
}

async function linkOldBookData(oldBookId, oldTitle, button) {
  const book = await getBook(state.linkTargetBookId || state.dialogBookId);
  if (!book) return;
  const confirmed = window.confirm(
    "確定將「" + oldTitle + "」的舊閱讀資料關聯到「" + book.fileName + "」嗎？\\n\\n" +
    "閱讀進度、自訂資訊、閱讀統計，以及資料庫中已有的標註都會合併。這項操作完成後不提供自動還原。"
  );
  if (!confirmed) return;

  button.disabled = true;
  const status = $("detail-link-status");
  status.hidden = false;
  status.textContent = "正在合併舊書籍資料……";
  try {
    const response = await fetch("/api/reading/link", {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ book: bookDescriptor(book), oldBookId })
    });
    let data = {};
    try { data = await response.json(); } catch (_) {}
    if (!response.ok || data.error) throw new Error(data.error || "關聯失敗，請稍後重試。");

    const moved = data.moved || {};
    const summary = [
      "閱讀狀態 " + (moved.readingState ? "已合併" : "無"),
      "閱讀事件 " + (Number(moved.readingEvents) || 0) + " 筆",
      "標註 " + (Number(moved.annotations) || 0) + " 筆"
    ].join(" · ");
    const detailsBookId = state.dialogBookId;
    $("book-dialog").close();
    await refresh();
    await showBookDetails(detailsBookId);
    const resultStatus = $("detail-link-status");
    resultStatus.hidden = false;
    resultStatus.textContent = "關聯完成。" + summary + (data.note ? " " + data.note : "");
  } catch (error) {
    status.hidden = false;
    status.textContent = "關聯失敗：" + (error.message || String(error));
    button.disabled = false;
  }
}

async function showLinkCandidates() {
  const targetId = state.linkTargetBookId || state.dialogBookId;
  const book = state.books.find(item => item.id === targetId) || await getBook(targetId);
  if (!book) return;
  const button = $("detail-link-open");
  const status = $("detail-link-status");
  const list = $("detail-link-candidates");
  button.disabled = true;
  status.hidden = false;
  status.textContent = "正在搜尋可關聯的舊書籍資料……";
  list.hidden = true;
  list.replaceChildren();
  try {
    const query = new URLSearchParams({
      book_id: book.id,
      provider: book.cloudSource?.provider || "",
      library: book.cloudSource?.library || "",
      root_path: book.cloudSource?.rootPath || "",
      path: book.cloudSource?.path || ""
    });
    const response = await fetch("/api/reading/link?" + query.toString(), {
      credentials: "same-origin",
      cache: "no-store"
    });
    let data = {};
    try { data = await response.json(); } catch (_) {}
    if (!response.ok || data.error) throw new Error(data.error || "無法搜尋舊書籍資料。");

    status.textContent = data.candidates?.length
      ? "找到 " + data.candidates.length + " 筆尚未關聯的舊書籍資料。請核對檔名和閱讀記錄後再選擇。"
      : "目前沒有可關聯的舊書籍資料。";
    if (!data.candidates?.length) return;
    for (const candidate of data.candidates) {
      const card = document.createElement("article");
      card.className = "dialog-link-candidate";
      const copy = document.createElement("div");
      copy.className = "dialog-link-candidate-copy";
      const title = document.createElement("strong");
      title.textContent = candidate.title || candidate.fileName || "未命名舊書籍";
      const details = document.createElement("small");
      const facts = [];
      if (candidate.fileName) facts.push(candidate.fileName);
      if (candidate.progress > 0) facts.push("進度 " + Math.round(candidate.progress) + "%");
      if (candidate.readingSeconds > 0) facts.push("累計 " + formatReadingTime(candidate.readingSeconds));
      if (candidate.annotationCount > 0) facts.push("標註 " + candidate.annotationCount + " 筆");
      details.textContent = facts.join(" · ") || "保留有閱讀歷史";
      copy.append(title, details);
      const action = document.createElement("button");
      action.type = "button";
      action.className = "dialog-secondary dialog-link-action";
      action.textContent = "關聯";
      action.addEventListener("click", () => {
        linkOldBookData(candidate.bookId, candidate.title || candidate.fileName || "舊書籍", action)
          .catch(error => { status.hidden = false; status.textContent = error.message || String(error); });
      });
      card.append(copy, action);
      list.appendChild(card);
    }
    list.hidden = false;
  } catch (error) {
    status.textContent = "搜尋失敗：" + (error.message || String(error));
  } finally {
    button.disabled = false;
  }
}

async function searchBangumi() {
  const book = await getBook(state.dialogBookId);
  if (!book) return;
  const keyword = $("detail-bangumi-query").value.trim();
  if (!keyword) { $("detail-bangumi-query").focus(); return; }
  const button = $("detail-bangumi-search");
  const status = $("detail-bangumi-status");
  const list = $("detail-bangumi-results");
  button.disabled = true;
  status.textContent = "正在搜尋 Bangumi 漫畫資料……";
  list.hidden = true;
  list.replaceChildren();
  try {
    const response = await fetch("/api/comics/bangumi/search", {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ keyword })
    });
    let data = {};
    try { data = await response.json(); } catch (_) {}
    if (!response.ok || data.error) throw new Error(data.error || "Bangumi 搜尋失敗。");
    const items = Array.isArray(data.items) ? data.items : [];
    status.textContent = items.length
      ? "找到 " + items.length + " 個候選條目。請核對名稱、日期與標籤，再套用正確作品。"
      : "沒有找到候選作品。可以試試日文原名或其他常用名稱。";
    for (const item of items) {
      const card = document.createElement("article");
      card.className = "dialog-link-candidate";
      const copy = document.createElement("div");
      copy.className = "dialog-link-candidate-copy";
      const title = document.createElement("strong");
      title.textContent = item.nameCn || item.name || ("Bangumi #" + item.id);
      const details = document.createElement("small");
      const facts = [];
      if (item.name && item.nameCn && item.name !== item.nameCn) facts.push(item.name);
      if (item.categoryLabel) facts.push(item.categoryLabel);
      if (item.date) facts.push(item.date);
      if (item.score) facts.push("評分 " + item.score + (item.ratingCount ? " · " + item.ratingCount + " 人" : ""));
      if (item.tags?.length) facts.push(item.tags.join("、"));
      if (item.summary) facts.push(item.summary);
      details.textContent = facts.join(" · ");
      copy.append(title, details);
      const action = document.createElement("button");
      action.type = "button";
      action.className = "dialog-secondary dialog-link-action";
      action.textContent = "套用";
      action.addEventListener("click", () => applyBangumiSubject(item, action)
        .catch(error => { status.textContent = "套用失敗：" + (error.message || String(error)); action.disabled = false; }));
      card.append(copy, action);
      list.appendChild(card);
    }
    list.hidden = !items.length;
  } finally {
    button.disabled = false;
  }
}

async function applyBangumiSubject(item, button) {
  const book = await getBook(state.dialogBookId);
  if (!book) return;
  button.disabled = true;
  const status = $("detail-bangumi-status");
  status.textContent = "正在取得 Bangumi 完整資料，並套用至同資料夾卷冊……";
  try {
    const response = await fetch("/api/comics/bangumi/link", {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ book: bookDescriptor(book), subjectId: Number(item.id) })
    });
    let data = {};
    try { data = await response.json(); } catch (_) {}
    if (!response.ok || data.error) throw new Error(data.error || "保存 Bangumi 資料失敗。");
    const bookId = state.dialogBookId;
    $("book-dialog").close();
    await refresh();
    await showBookDetails(bookId);
    $("detail-bangumi-status").textContent = "已關聯 " + (data.subject?.nameCn || data.subject?.name || "Bangumi 作品") +
      "，共套用至 " + Number(data.linkedBooks || 0) + " 個卷冊。";
  } catch (error) {
    status.textContent = "套用失敗：" + (error.message || String(error));
    button.disabled = false;
  }
}

async function restoreEpubMetadata() {
  const id = state.dialogBookId;
  const book = await getBook(id);
  if (!book) return;
  const button = $("detail-reset-opf");
  button.disabled = true;
  try {
    await updateBook(id, {
      title: book.bookTitle || "",
      author: book.bookCreator || "",
      manualTitle: false,
      manualAuthor: false
    });
    $("book-dialog").close();
    await refresh();
    await showBookDetails(id);
    $("library-status").textContent = "已恢復使用 EPUB 內部書名與作者。";
  } catch (error) {
    $("library-status").textContent = "恢復 EPUB 內部資訊失敗：" + (error.message || String(error));
  } finally {
    button.disabled = false;
  }
}

async function saveDetails(event) {
  event.preventDefault();
  if (!state.dialogBookId) return;
  const title = $("detail-title").value.trim(), author = $("detail-author").value.trim();
  if (!title) { $("detail-title").focus(); return; }
  const book = await getBook(state.dialogBookId);
  if (!book) return;
  await updateBook(book.id, {
    title, author,
    shelf: book.format === "CBZ" ? "comics" : ($("detail-shelf").value === "comics" ? "comics" : "books"),
    manualTitle: true, manualAuthor: true
  });
  $("book-dialog").close();
  await refresh();
}

$("open-cloud-manager-hero")?.addEventListener("click", () => $("open-cloud-manager")?.click());
$("folder-detail-back").addEventListener("click", () => {
  state.activeFolderKey = null;
  render();
  $("library").scrollIntoView({ behavior: "smooth", block: "start" });
});
$("search-books").addEventListener("input", event => { state.query = event.target.value || ""; render(); });
$("sort-books").addEventListener("change", event => { state.sort = event.target.value; render(); });
$("view-grid").addEventListener("click", () => { state.view = "grid"; render(); });
$("view-list").addEventListener("click", () => { state.view = "list"; render(); });
$("detail-form").addEventListener("submit", event => { saveDetails(event).catch(error => { $("library-status").textContent = "雲端保存失敗：" + error.message; }); });
$("detail-cancel").addEventListener("click", () => $("book-dialog").close());
$("detail-link-open").addEventListener("click", () => { showLinkCandidates().catch(error => { $("detail-link-status").hidden = false; $("detail-link-status").textContent = error.message || String(error); }); });
$("detail-reset-opf").addEventListener("click", () => {
  restoreEpubMetadata().catch(error => { $("library-status").textContent = "恢復 EPUB 內部資訊失敗：" + (error.message || String(error)); });
});
$("detail-bangumi-search").addEventListener("click", () => {
  searchBangumi().catch(error => { $("detail-bangumi-status").textContent = "搜尋失敗：" + (error.message || String(error)); });
});
$("detail-bangumi-query").addEventListener("keydown", event => {
  if (event.key === "Enter") { event.preventDefault(); $("detail-bangumi-search").click(); }
});
$("detail-link-target").addEventListener("change", event => { state.linkTargetBookId = event.target.value || state.dialogBookId; $("detail-link-candidates").hidden = true; $("detail-link-status").hidden = true; });
$("detail-open").addEventListener("click", () => {
  const book = state.books.find(item => item.id === state.dialogBookId);
  if (book) location.href = readerUrl(book);
});
$("book-dialog").addEventListener("click", event => { if (event.target === $("book-dialog")) $("book-dialog").close(); });
refresh();
window.addEventListener("focus", refresh);
