function makeFile(blob, record) {
  const fileName = String(record.fileName || "book." + String(record.format || "epub").toLowerCase());
  const mime = String(record.format || "").toUpperCase() === "CBZ"
    ? "application/vnd.comicbook+zip"
    : "application/epub+zip";
  const modified = Number(record.lastModified) || Date.now();
  return new File([blob], fileName, { type: mime, lastModified: modified });
}

export async function fetchCloudBookFile(record) {
  if (!record || !record.cloudSource) throw new Error("這筆書籍沒有 Alist／OpenList 雲端來源資訊。");
  const source = record.cloudSource;
  if (String(source.provider || "") === "local") {
    const local = await import("/assets/local-openlist.js?v=20261116-local-r2");
    const blob = await local.fetchLocalFileBlob(String(source.path || ""));
    return makeFile(blob, record);
  }
  if (!["vps", "worker", "mobile"].includes(String(source.provider || ""))) {
    throw new Error("FRAME Reader 不支援這個 Alist／OpenList 來源。");
  }
  const query = new URLSearchParams({
    provider: String(source.provider),
    library: String(source.library || record.shelf || "books"),
    root_path: String(source.rootPath || ""),
    path: String(source.path || "")
  });
  const response = await fetch("/api/cloud/file?" + query.toString(), {
    method: "GET",
    credentials: "same-origin",
    cache: "no-store"
  });
  if (!response.ok) {
    let data = {};
    try { data = await response.json(); } catch (_) {}
    throw new Error(data.error || "雲端書檔讀取失敗：HTTP " + response.status);
  }
  return makeFile(await response.blob(), record);
}
