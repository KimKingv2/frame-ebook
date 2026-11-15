import { upsertCloudBooks, getReadingSetting, setReadingSetting } from "/assets/library-store.js?v=20261115-cloud-primary-r2";

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
  return "cloud-shelf-sync:v1:" + [scope.provider, scope.library, scope.rootPath].map(encodeURIComponent).join(":");
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

export async function syncCloudShelf(scope, options = {}) {
  const provider = String(scope?.provider || "");
  const library = scope?.library === "comics" ? "comics" : "books";
  const rootPath = normalizeRoot(scope?.rootPath);
  if (!provider || !rootPath) throw new Error("雲端書架同步範圍無效。");
  const normalizedScope = { provider, library, rootPath };

  const first = await fetchCatalogPage(normalizedScope, 1);
  if (!first.indexed || !first.scanState?.completed) {
    return { changed: false, ready: false, count: 0, reason: "index_incomplete" };
  }

  const total = Math.max(0, Number(first.total) || 0);
  const version = String(first.scanState.updatedAt || first.scanState.completedAt || "") + ":" + total;
  const syncKey = scopeSyncKey(normalizedScope);
  if (!options.force) {
    const previous = await getReadingSetting(syncKey, "");
    if (previous === version) {
      return { changed: false, ready: true, count: 0, total, reason: "already_synced" };
    }
  }

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  let synced = 0;
  for (let page = 1; page <= pageCount; page++) {
    const data = page === 1 ? first : await fetchCatalogPage(normalizedScope, page);
    const books = (Array.isArray(data.items) ? data.items : [])
      .filter(item => !item.isDir)
      .map(item => ({
        ...item,
        format: String(item.format || "").toUpperCase(),
        coverHash: item.coverHash || null,
        coverType: item.coverType || null,
        coverStatus: item.coverStatus || "pending"
      }));
    if (books.length) {
      await upsertCloudBooks(normalizedScope, books);
      synced += books.length;
    }
    if (typeof options.onProgress === "function") {
      options.onProgress({
        provider,
        library,
        page,
        pageCount,
        synced,
        total
      });
    }
  }

  await setReadingSetting(syncKey, version);
  return { changed: true, ready: true, count: synced, total, version };
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
    results
  };
}
