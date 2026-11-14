import {
  importBookFile, listBooks, getBook, updateBook, deleteBook
} from "/assets/library-store.js";

const $ = id => document.getElementById(id);
const state = { books: [], query: "", sort: "recent", view: "grid", dialogBookId: null };
const coverUrls = new Map();
const readerUrl = id => "/epub-lab/?book=" + encodeURIComponent(id);

function getBookShelf(book) {
  if (!book) return "books";
  if (book.format === "CBZ") return "comics";
  return book.shelf === "comics" ? "comics" : "books";
}

function formatSize(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024 * 1024) return (value / 1024).toFixed(0) + " KB";
  return (value / (1024 * 1024)).toFixed(value >= 1024 * 1024 * 1024 ? 2 : 1) + (value >= 1024 * 1024 * 1024 ? " GB" : " MB");
}

function formatDate(timestamp) {
  if (!timestamp) return "尚未閱讀";
  try {
    return new Intl.DateTimeFormat("zh-TW", { year: "numeric", month: "short", day: "numeric" }).format(new Date(timestamp));
  } catch (_) {
    return "";
  }
}

function coverUrl(book) {
  if (!book.coverBlob) return "";
  if (!coverUrls.has(book.id)) coverUrls.set(book.id, URL.createObjectURL(book.coverBlob));
  return coverUrls.get(book.id);
}

function makeCover(book, compact) {
  const frame = document.createElement("div");
  frame.className = "cover-frame library-cover" + (compact ? " library-cover-compact" : "");
  frame.setAttribute("aria-label", book.title + " 封面");
  const url = coverUrl(book);
  if (url) {
    const image = document.createElement("img");
    image.src = url;
    image.alt = book.title + " 封面";
    image.loading = "lazy";
    image.onerror = () => {
      image.remove();
      frame.appendChild(makeFallback(book));
    };
    frame.appendChild(image);
  } else {
    frame.appendChild(makeFallback(book));
  }
  const format = document.createElement("span");
  format.className = "library-format-badge";
  format.textContent = book.format;
  frame.appendChild(format);
  return frame;
}

function makeFallback(book) {
  const fallback = document.createElement("div");
  fallback.className = "library-cover-fallback";
  const top = document.createElement("span");
  top.textContent = "FRAME READER";
  const title = document.createElement("strong");
  title.textContent = book.title || "未命名書籍";
  const bottom = document.createElement("small");
  bottom.textContent = getBookShelf(book) === "comics" ? "COMIC EDITION" : "READING EDITION";
  fallback.append(top, title, bottom);
  return fallback;
}

function createCard(book, compact) {
  const article = document.createElement("article");
  article.className = "book-card library-card" + (compact ? " library-card-compact" : "");
  const open = document.createElement("a");
  open.className = "library-card-open";
  open.href = readerUrl(book.id);
  open.setAttribute("aria-label", "開啟 " + book.title);
  open.appendChild(makeCover(book, compact));

  const meta = document.createElement("div");
  meta.className = "book-meta library-book-meta";
  const copy = document.createElement("div");
  const title = document.createElement("h3");
  title.textContent = book.title || book.fileName;
  const author = document.createElement("p");
  author.textContent = book.author || (getBookShelf(book) === "comics" ? "漫畫／圖像書" : "作者未提供");
  copy.append(title, author);
  const kind = document.createElement("span");
  kind.className = "book-kind";
  kind.textContent = book.format;
  meta.append(copy, kind);

  const progress = document.createElement("div");
  progress.className = "library-progress";
  const track = document.createElement("span");
  track.className = "library-progress-track";
  const fill = document.createElement("span");
  fill.className = "library-progress-fill";
  const percent = Math.max(0, Math.min(100, Number(book.progress && book.progress.percent) || 0));
  fill.style.width = percent + "%";
  track.appendChild(fill);
  const label = document.createElement("small");
  label.textContent = percent > 0 ? Math.round(percent) + "% · " + (book.progress.label || "閱讀中") : "尚未開始";
  progress.append(track, label);

  const actions = document.createElement("div");
  actions.className = "library-card-actions";
  const continueLink = document.createElement("a");
  continueLink.href = readerUrl(book.id);
  continueLink.className = "library-open-link";
  continueLink.textContent = percent > 0 ? "繼續閱讀 ↗" : "開始閱讀 ↗";
  const details = document.createElement("button");
  details.type = "button";
  details.className = "library-details-button";
  details.textContent = "作品資訊";
  details.addEventListener("click", () => showBookDetails(book.id));
  actions.append(continueLink, details);

  article.append(open, meta, progress, actions);
  return article;
}

function filteredBooks() {
  const query = state.query.trim().toLocaleLowerCase();
  let books = state.books.filter(book => {
    if (!query) return true;
    return [book.title, book.author, book.fileName, book.format].join(" ").toLocaleLowerCase().includes(query);
  });
  books = books.slice();
  if (state.sort === "title") books.sort((a, b) => (a.title || "").localeCompare(b.title || "", "zh-Hant"));
  else if (state.sort === "added") books.sort((a, b) => (b.addedAt || 0) - (a.addedAt || 0));
  else if (state.sort === "progress") books.sort((a, b) => (Number(b.progress && b.progress.percent) || 0) - (Number(a.progress && a.progress.percent) || 0));
  else books.sort((a, b) => (b.lastOpenedAt || 0) - (a.lastOpenedAt || 0) || (b.addedAt || 0) - (a.addedAt || 0));
  return books;
}

function renderCategoryShelf(allItems, visibleItems, gridId, emptyId, searchEmptyId, countId) {
  const grid = $(gridId);
  const empty = $(emptyId);
  const searchEmpty = $(searchEmptyId);
  grid.classList.toggle("is-list", state.view === "list");
  grid.replaceChildren();
  visibleItems.forEach(book => grid.appendChild(createCard(book, false)));
  $(countId).textContent = String(allItems.length).padStart(2, "0");
  empty.hidden = allItems.length > 0;
  searchEmpty.hidden = allItems.length === 0 || visibleItems.length > 0;
  grid.hidden = visibleItems.length === 0;
}

function render() {
  const total = state.books.length;
  const started = state.books.filter(book => Number(book.progress && book.progress.percent) > 0).length;
  const allBooks = state.books.filter(book => getBookShelf(book) === "books");
  const allComics = state.books.filter(book => getBookShelf(book) === "comics");
  const epubFiles = state.books.filter(book => book.format === "EPUB");
  const cbzFiles = state.books.filter(book => book.format === "CBZ");
  $("book-count").textContent = String(total).padStart(2, "0");
  $("started-count").textContent = String(started).padStart(2, "0");
  $("epub-count").textContent = String(epubFiles.length).padStart(2, "0");
  $("comic-count").textContent = String(cbzFiles.length).padStart(2, "0");

  const recent = state.books.filter(book => Number(book.lastOpenedAt) > 0)
    .sort((a, b) => b.lastOpenedAt - a.lastOpenedAt).slice(0, 3);
  const recentSection = $("recent-section");
  const recentGrid = $("recent-grid");
  recentGrid.replaceChildren();
  recentSection.hidden = recent.length === 0;
  recent.forEach(book => recentGrid.appendChild(createCard(book, true)));

  const visible = filteredBooks();
  const visibleBooks = visible.filter(book => getBookShelf(book) === "books");
  const visibleComics = visible.filter(book => getBookShelf(book) === "comics");
  renderCategoryShelf(allBooks, visibleBooks, "books-grid", "books-empty", "books-search-empty", "books-shelf-count");
  renderCategoryShelf(allComics, visibleComics, "comics-grid", "comics-empty", "comics-search-empty", "comics-shelf-count");

  $("shelf-count-label").textContent = total + " ITEM" + (total === 1 ? "" : "S");
  $("result-count").textContent = "目前顯示 " + visibleBooks.length + " 本電子書 · " + visibleComics.length + " 部漫畫";
  $("view-grid").setAttribute("aria-pressed", state.view === "grid" ? "true" : "false");
  $("view-list").setAttribute("aria-pressed", state.view === "list" ? "true" : "false");
}

async function refresh() {
  try {
    state.books = await listBooks();
    render();
    const epubCount = state.books.filter(book => getBookShelf(book) === "books").length;
    const comicCount = state.books.filter(book => getBookShelf(book) === "comics").length;
    $("library-status").textContent = state.books.length
      ? "本機書架已就緒：電子書 " + epubCount + " 本，漫畫 " + comicCount + " 部。"
      : "電子書與漫畫書架都已就緒，匯入作品即可開始收藏。";
  } catch (error) {
    $("library-status").textContent = "無法開啟本機書庫：" + (error.message || String(error));
    document.querySelectorAll("[data-import-type]").forEach(button => { button.disabled = true; });
    $("books-files").disabled = true;
    $("comics-files").disabled = true;
  }
}

async function importFiles(files, shelf) {
  const selected = Array.from(files || []);
  if (!selected.length) return;
  const formatLabel = shelf === "comics" ? "漫畫" : "電子書";
  const input = $(shelf === "comics" ? "comics-files" : "books-files");
  const buttons = Array.from(document.querySelectorAll('[data-import-type="' + shelf + '"]'));
  $("library-status").textContent = "正在整理 " + selected.length + " 個" + formatLabel + "檔案……";
  buttons.forEach(button => { button.disabled = true; });
  input.disabled = true;
  let success = 0;
  const errors = [];
  for (const file of selected) {
    try {
      const extension = String(file.name || "").split(".").pop().toUpperCase();
      const allowed = shelf === "comics" ? (extension === "EPUB" || extension === "CBZ") : extension === "EPUB";
      if (!allowed) throw new Error(shelf === "comics" ? "漫畫書架接受 EPUB 或 CBZ 格式。" : "電子書架只接受 EPUB 格式。");
      await importBookFile(file, { shelf });
      success++;
    } catch (error) {
      errors.push(file.name + "：" + (error.message || String(error)));
    }
  }
  buttons.forEach(button => { button.disabled = false; });
  input.disabled = false;
  input.value = "";
  await refresh();
  if (errors.length) {
    $("library-status").textContent = "已加入 " + success + " 個" + formatLabel + "項目；有 " + errors.length + " 個檔案未加入：" + errors.slice(0, 2).join("；");
  } else {
    $("library-status").textContent = "完成，已將 " + success + " 個" + formatLabel + "項目加入對應書架。";
  }
}

async function showBookDetails(id) {
  const book = await getBook(id);
  if (!book) return;
  state.dialogBookId = id;
  $("detail-heading").textContent = getBookShelf(book) === "comics" ? "漫畫資訊" : "電子書資訊";
  $("detail-title").value = book.title || "";
  $("detail-shelf").value = getBookShelf(book);
  $("detail-shelf").disabled = book.format === "CBZ";
  $("detail-shelf-note").textContent = book.format === "CBZ" ? "CBZ 圖像封存固定放在漫畫書架。" : "EPUB 可依內容自由放入電子書或漫畫書架。";
  $("detail-author").value = book.author || "";
  $("detail-format").textContent = book.format;
  $("detail-file").textContent = book.fileName;
  $("detail-size").textContent = formatSize(book.size);
  $("detail-pages").textContent = book.pageCount ? book.pageCount + (book.format === "CBZ" ? " 頁" : " 個內容項目") : "未提供";
  $("detail-added").textContent = formatDate(book.addedAt);
  $("detail-progress").textContent = book.progress && book.progress.percent > 0
    ? Math.round(book.progress.percent) + "% · " + (book.progress.label || "閱讀中")
    : "尚未開始";
  const dialog = $("book-dialog");
  if (typeof dialog.showModal === "function") dialog.showModal();
  else dialog.setAttribute("open", "");
}

async function saveDetails(event) {
  event.preventDefault();
  if (!state.dialogBookId) return;
  const title = $("detail-title").value.trim();
  const author = $("detail-author").value.trim();
  if (!title) {
    $("detail-title").focus();
    return;
  }
  const currentBook = await getBook(state.dialogBookId);
  if (!currentBook) return;
  const shelf = currentBook.format === "CBZ" ? "comics" : ($("detail-shelf").value === "comics" ? "comics" : "books");
  await updateBook(state.dialogBookId, {
    title,
    author,
    shelf,
    manualTitle: true,
    manualAuthor: true
  });
  $("book-dialog").close();
  await refresh();
}

async function removeCurrentBook() {
  if (!state.dialogBookId) return;
  const book = await getBook(state.dialogBookId);
  if (!book) return;
  const confirmed = window.confirm("確定從這台設備的書架移除「" + book.title + "」？這會刪除瀏覽器保存的書檔與閱讀位置，不會影響原始檔案。");
  if (!confirmed) return;
  await deleteBook(state.dialogBookId);
  state.dialogBookId = null;
  $("book-dialog").close();
  const objectUrl = coverUrls.get(book.id);
  if (objectUrl) URL.revokeObjectURL(objectUrl);
  coverUrls.delete(book.id);
  await refresh();
  $("library-status").textContent = "已從本機書架移除書籍，原始檔案不受影響。";
}

document.querySelectorAll("[data-import-type]").forEach(button => {
  button.addEventListener("click", () => {
    const type = button.dataset.importType === "comics" ? "comics" : "books";
    $(type === "comics" ? "comics-files" : "books-files").click();
  });
});
$("books-files").addEventListener("change", event => importFiles(event.target.files, "books"));
$("comics-files").addEventListener("change", event => importFiles(event.target.files, "comics"));
$("search-books").addEventListener("input", event => {
  state.query = event.target.value || "";
  render();
});
$("sort-books").addEventListener("change", event => {
  state.sort = event.target.value;
  render();
});
$("view-grid").addEventListener("click", () => { state.view = "grid"; render(); });
$("view-list").addEventListener("click", () => { state.view = "list"; render(); });
$("detail-form").addEventListener("submit", saveDetails);
$("detail-cancel").addEventListener("click", () => $("book-dialog").close());
$("detail-delete").addEventListener("click", removeCurrentBook);
$("detail-open").addEventListener("click", () => {
  if (state.dialogBookId) location.href = readerUrl(state.dialogBookId);
});
$("book-dialog").addEventListener("click", event => {
  if (event.target === $("book-dialog")) $("book-dialog").close();
});
$("load-sample").addEventListener("click", async () => {
  try {
    $("library-status").textContent = "正在準備內建 EPUB 示範書……";
    const response = await fetch("/demo/frame-reader-sample.epub", { cache: "no-store" });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const blob = await response.blob();
    const file = new File([blob], "FRAME Reader 測試小書.epub", { type: "application/epub+zip", lastModified: Date.now() });
    const book = await importBookFile(file);
    await refresh();
    location.href = readerUrl(book.id);
  } catch (error) {
    $("library-status").textContent = "示範書載入失敗：" + (error.message || String(error));
  }
});

window.addEventListener("beforeunload", () => {
  coverUrls.forEach(url => URL.revokeObjectURL(url));
});
refresh();
