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

function makeWebDavRangeFile(record, profileId, size) {
  const tauri = window.__TAURI__;
  const CHUNK_SIZE = 1024 * 1024;
  const fileName = String(record.fileName || "comic.cbz");
  const file = {
    name: fileName,
    type: "application/vnd.comicbook+zip",
    size: Number(size),
    lastModified: Number(record.lastModified) || Date.now(),
    frameDeliveryMode: "webdav-native-range",
    async arrayBuffer() {
      return readBytes(0, file.size);
    },
    slice(start = 0, end = file.size) {
      const normalize = (value, fallback) => {
        const number = value === undefined ? fallback : Math.trunc(Number(value) || 0);
        return number < 0 ? Math.max(0, file.size + number) : Math.min(file.size, Math.max(0, number));
      };
      const from = normalize(start, 0);
      const to = Math.max(from, normalize(end, file.size));
      return {
        size: to - from,
        async arrayBuffer() { return readBytes(from, to); }
      };
    }
  };

  async function readBytes(start, end) {
    const length = end - start;
    const output = new Uint8Array(length);
    let offset = 0;
    while (offset < length) {
      const count = Math.min(CHUNK_SIZE, length - offset);
      const raw = await tauri.core.invoke("webdav_read_range", {
        profileId: String(profileId),
        path: String(record.cloudSource.path || ""),
        start: start + offset,
        length: count
      });
      let chunk;
      if (raw instanceof ArrayBuffer) {
        chunk = new Uint8Array(raw);
      } else if (ArrayBuffer.isView(raw)) {
        chunk = new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
      } else {
        throw new Error("WebDAV Range 通道沒有回傳二進位資料。");
      }
      if (chunk.byteLength !== count) {
        throw new Error("漫畫 Range 資料長度不符：預期 " + count + " bytes，實際 " + chunk.byteLength + " bytes。");
      }
      output.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return output.buffer;
  }

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
    const profileId = String(source.profileId || "");
    const isCbz = String(record.format || "").toLowerCase() === "cbz"
      || /\.cbz$/i.test(String(record.fileName || source.path || ""));
    if (isCbz) {
      const size = await tauri.core.invoke("webdav_get_file_size", {
        profileId,
        path: String(source.path || "")
      });
      if (!Number.isSafeInteger(Number(size)) || Number(size) <= 0) {
        throw new Error("WebDAV 回報的 CBZ 檔案大小不正確。");
      }
      return makeWebDavRangeFile(record, profileId, Number(size));
    }

    const downloaded = await tauri.core.invoke("webdav_download_file", {
      profileId,
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
