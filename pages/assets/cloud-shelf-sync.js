import { upsertCloudBooks, getReadingSetting, setReadingSetting } from "/assets/library-store.js?v=20261115-folder-shelves-r4";

const ACTIVE_PROVIDER_KEY = "frame-reader-active-openlist-provider";
const ROOT_SELECTIONS_KEY = "frame-reader-cloud-root-selections-v4";
const DEFAULT_ROOTS = {
  books: "/中國移動雲盤/Kim King/04 Boooooks/01 Books 歸檔",
  comics: "/中國移動雲盤/Kim King/11 Comic"
};
const PAGE_SIZE = 100;

function normalizeRoot(value) {
  const raw = String(value || "/").replace(/\\/g, "/");
  if (raw.includes("\0")) return null;
  const parts = raw.split("/");
  if (parts.some(part => part === "..")) return null;
  return "/" + parts.filter(part => part && part !== ".").join("/");
}

function scopeSyncKey(scope) {
  return "cloud-shelf-sync:v2:" + [scope.provider, scope.library, scope.rootPath].map(encodeURIComponent).join(":");
}

function fileSummary(item) {
  return {
    path: String(item.path || ""),
    name: String(item.name || ""),
    format: String(item.format || "").toUpperCase(),
    size: Math.max(0, Number(item.size) || 0),
    modified: item.modified || null,
    coverHash: /^[a-f0-9]{64}$/i.test(String(item.coverHash || "")) ? String(item.coverHash).toLowerCase() : null,
    coverStatus: String(item.coverStatus || "")
  };
}

export function buildShelfEntries(scope, items) {
  const rootPath = normalizeRoot(scope?.rootPath);
  const prefix = rootPath === "/" ? "/" : rootPath + "/";
  const groups = new Map();
  const standalone = [];

  for (const raw of Array.isArray(items) ? items : []) {
    if (!raw || raw.isDir) continue;
    const format = String(raw.format || "").toUpperCase();
    if (scope.library === "books" ? format !== "EPUB" : !["EPUB", "CBZ"].includes(format)) continue;
    const path = normalizeRoot(raw.path);
    if (!path || !(path === rootPath || path.startsWith(prefix))) continue;
    const relative = path.slice(prefix.length);
    const parts = relative.split("/").filter(Boolean);
    const file = { ...raw, path, format };
    if (parts.length <= 1) {
      standalone.push(file);
      continue;
    }
    const folderPath = prefix + parts[0];
    if (!groups.has(folderPath)) groups.set(folderPath, []);
    groups.get(folderPath).push(file);
  }

  const output = standalone.map(item => ({
    ...item,
    groupPath: "",
    groupTitle: "",
    groupFiles: [fileSummary(item)],
    groupCoverHashes: item.coverStatus === "ready" && item.coverHash ? [String(item.coverHash).toLowerCase()] : []
  }));

  for (const [folderPath, files] of groups) {
    files.sort((a, b) => String(a.path).localeCompare(String(b.path), "zh-Hant", { numeric: true, sensitivity: "base" }));
    const folderName = folderPath.slice(prefix.length).replace(/^\/+/, "");
    const summaries = files.map(fileSummary);
    const coverHashes = [...new Set(summaries
      .filter(file => file.coverStatus === "ready" && file.coverHash)
      .map(file => file.coverHash))].slice(0, 8);
    for (const file of files) {
      output.push({
        ...file,
        groupPath: folderPath,
        groupTitle: folderName || file.name,
        groupFiles: summaries,
        groupCoverHashes: coverHashes,
        groupFileCount: files.length
      });
    }
  }

  return output.sort((a, b) => String(a.path || a.name).localeCompare(String(b.path || b.name), "zh-Hant", { numeric: true, sensitivity: "base" }));
}

async function fetchCatalogPage(scope, page) {
  const query = new URLSearchParams({
    provider: scope.provider,
    library: scope.library,
    root_path: scope.rootPath,
    path: scope.rootPath,
    recursive: "1",
    page: String(page),
    per_page: String(PAGE_SIZE)
  });
  const response = await fetch("/api/cloud/books?" + query.toString(), {
    method: "GET",
    credentials: "same-origin",
    cache: "no-store"
  });
  let data = {};
  try { data = await response.json(); } catch (_) {}
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || "讀取雲端書架索引失敗（HTTP " + response.status + "）。");
  }
  return data;
}

export async function syncCloudShelfItems(scope, items, options = {}) {
  const records = buildShelfEntries(scope, items);
  return upsertCloudBooks(scope, records, { replaceGroups: options.replaceGroups === true });
}

export async function syncCloudShelf(scope, options = {}) {
  const provider = String(scope?.provider || "");
  const library = scope?.library === "comics" ? "comics" : "books";
  const rootPath = normalizeRoot(scope?.rootPath);
  if (!provider || !rootPath) throw new Error("雲端書架同步範圍無效。");
  const normalizedScope = { provider, library, rootPath };

  const first = await fetchCatalogPage(normalizedScope, 1);
  const complete = !!(first.indexed && first.scanState?.completed);
  if (!complete && options.allowPartial !== true) {
    return { changed: false, ready: false, count: 0, reason: "index_incomplete" };
  }

  const total = Math.max(0, Number(first.total) || 0);
  const version = String(first.scanState?.updatedAt || first.scanState?.completedAt || "") + ":" + total;
  const syncKey = scopeSyncKey(normalizedScope);
  if (complete && !options.force) {
    const previous = await getReadingSetting(syncKey, "");
    if (previous === version) {
      return { changed: false, ready: true, count: 0, total, reason: "already_synced" };
    }
  }

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const allItems = [];
  for (let page = 1; page <= pageCount; page++) {
    const data = page === 1 ? first : await fetchCatalogPage(normalizedScope, page);
    allItems.push(...(Array.isArray(data.items) ? data.items : []));
    if (typeof options.onProgress === "function") {
      options.onProgress({ provider, library, page, pageCount, synced: allItems.length, total });
    }
  }

  const records = await syncCloudShelfItems(normalizedScope, allItems, { replaceGroups: complete });
  if (complete) await setReadingSetting(syncKey, version);
  const removedCount = Number(records.removedCount) || 0;
  return {
    changed: records.length > 0 || removedCount > 0,
    ready: complete,
    count: records.length,
    removedCount,
    total,
    version,
    partial: !complete
  };
}

export async function syncSavedCloudShelves(options = {}) {
  let provider = "";
  let saved = {};
  try {
    provider = String(localStorage.getItem(ACTIVE_PROVIDER_KEY) || "vps");
    saved = JSON.parse(localStorage.getItem(ROOT_SELECTIONS_KEY) || "{}");
  } catch (_) {}
  if (!provider) return { changed: false, count: 0, skipped: true };

  const providerRoots = saved?.[provider] || {};
  const results = [];
  for (const library of ["books", "comics"]) {
    const rootPath = normalizeRoot(providerRoots[library] || DEFAULT_ROOTS[library]);
    if (!rootPath) continue;
    try {
      const result = await syncCloudShelf({ provider, library, rootPath }, options);
      results.push({ ...result, provider, library });
    } catch (error) {
      results.push({ changed: false, provider, library, error: String(error?.message || error) });
    }
  }
  return {
    changed: results.some(result => result.changed),
    count: results.reduce((sum, result) => sum + Number(result.count || 0), 0),
    removedCount: results.reduce((sum, result) => sum + Number(result.removedCount || 0), 0),
    results
  };
}
