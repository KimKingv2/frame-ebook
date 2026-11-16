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
  if (!["vps", "worker", "mobile"].includes(String(source.provider || ""))) {
    throw new Error("FRAME Reader 只允許透過已設定的伺服器端 Alist／OpenList 來源讀取書籍。");
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
