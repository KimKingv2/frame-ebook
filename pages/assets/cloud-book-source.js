function makeFile(blob, record, deliveryMode) {
  const fileName = String(record.fileName || "book." + String(record.format || "epub").toLowerCase());
  const mime = String(record.format || "").toUpperCase() === "CBZ"
    ? "application/vnd.comicbook+zip"
    : "application/epub+zip";
  const modified = Number(record.lastModified) || Date.now();
  const file = new File([blob], fileName, { type: mime, lastModified: modified });
  file.frameDeliveryMode = String(deliveryMode || "stream");
  return file;
}

async function responseError(response) {
  let data = {};
  try { data = await response.json(); } catch (_) {}
  return new Error(data.error || "雲端書檔讀取失敗：HTTP " + response.status);
}

export async function fetchCloudBookFile(record) {
  if (!record || !record.cloudSource) throw new Error("這筆書籍沒有 Alist／OpenList 雲端來源資訊。");
  const source = record.cloudSource;
  if (String(source.provider || "") === "webdav") {
    const tauri = window.__TAURI__;
    if (!tauri || !tauri.core || !tauri.core.invoke || !tauri.core.convertFileSrc) {
      throw new Error("Mac 原生 WebDAV 通道尚未啟動，請重新開啟 FRAME Ebook。");
    }
    const downloaded = await tauri.core.invoke("webdav_download_file", {
      profileId: String(source.profileId || ""),
      path: String(source.path || "")
    });
    if (!downloaded || !downloaded.path) throw new Error("WebDAV 沒有提供可讀取的本機暫存檔。");
    try {
      const localUrl = tauri.core.convertFileSrc(downloaded.path);
      const response = await fetch(localUrl, { cache: "no-store" });
      if (!response.ok) throw new Error("讀取本機暫存書檔失敗（HTTP " + response.status + "）。");
      const blob = await response.blob();
      return makeFile(blob, record, downloaded.redirected ? "webdav-302-direct" : "webdav-native");
    } finally {
      try { await tauri.core.invoke("delete_cached_file", { path: downloaded.path }); } catch (_) {}
    }
  }
  if (String(source.provider || "") === "local") {
    const local = await import("/assets/local-openlist.js?v=20261116-local-r2");
    const blob = await local.fetchLocalFileBlob(String(source.path || ""));
    return makeFile(blob, record, "local-direct");
  }
  if (!["vps", "worker", "mobile"].includes(String(source.provider || ""))) {
    throw new Error("FRAME Reader 不支援這個 Alist／OpenList 來源。");
  }

  const baseParams = {
    provider: String(source.provider),
    library: String(source.library || record.shelf || "books"),
    root_path: String(source.rootPath || ""),
    path: String(source.path || "")
  };
  const sourceLibrary = String(source.library || record.shelf || "books").toLowerCase();
  const isComicLibrary = sourceLibrary === "comics";
  let directError = null;

  // Comic archives can be very large. First let the browser follow the Pages
  // Function's 302 directly to OpenList's signed file URL, avoiding a second
  // full-file hop through Pages. The final host must allow CORS for fetch().
  if (isComicLibrary) {
    const redirectQuery = new URLSearchParams({ ...baseParams, delivery: "redirect" });
    try {
      const directResponse = await fetch("/api/cloud/file?" + redirectQuery.toString(), {
        method: "GET",
        mode: "cors",
        credentials: "same-origin",
        cache: "no-store",
        redirect: "follow"
      });
      if (directResponse.ok) {
        return makeFile(await directResponse.blob(), record, "redirect");
      }
      directError = await responseError(directResponse);
      try { await directResponse.body?.cancel(); } catch (_) {}
    } catch (error) {
      // A CORS rejection at the final signed URL is expected on some storage
      // providers. Fall back to the same-origin Pages stream so reading still
      // works without requiring provider-side CORS configuration.
      directError = error;
    }
    console.info("[FRAME Reader] Comic direct redirect unavailable; falling back to Pages stream.",
      String(directError && directError.message || directError || "unknown error").slice(0, 180));
  }

  const streamQuery = new URLSearchParams({ ...baseParams, delivery: "stream" });
  const response = await fetch("/api/cloud/file?" + streamQuery.toString(), {
    method: "GET",
    mode: "same-origin",
    credentials: "same-origin",
    cache: "no-store"
  });
  if (!response.ok) throw await responseError(response);
  return makeFile(await response.blob(), record, isComicLibrary ? "stream-fallback" : "stream");
}
