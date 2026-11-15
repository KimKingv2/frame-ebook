function localNetworkOptions(url) {
  let host = "";
  try { host = new URL(url).hostname; } catch (_) {}
  if (host === "localhost" || host === "127.0.0.1" || host.startsWith("127.")) {
    return { targetAddressSpace: "loopback" };
  }
  if (/^(10\.|192\.168\.|169\.254\.)/.test(host) ||
      /^172\.(1[6-9]|2\d|3[01])\./.test(host) ||
      /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(host)) {
    return { targetAddressSpace: "local" };
  }
  return {};
}

function makeFile(blob, record) {
  const fileName = String(record.fileName || "book." + String(record.format || "epub").toLowerCase());
  const mime = String(record.format || "").toUpperCase() === "CBZ"
    ? "application/vnd.comicbook+zip"
    : "application/epub+zip";
  const modified = Number(record.lastModified) || Date.now();
  return new File([blob], fileName, { type: mime, lastModified: modified });
}

async function fetchLocalOpenListFile(source, record) {
  let saved = {};
  let password = "";
  try {
    saved = JSON.parse(localStorage.getItem("frame-reader-local-openlist-profile-v2") || "{}");
    password = sessionStorage.getItem("frame-reader-local-openlist-password-v1") || "";
  } catch (_) {}
  const baseUrl = String(saved.baseUrl || "").replace(/\/+$/, "");
  const username = String(saved.username || "").trim();
  if (!baseUrl || !username || !password) {
    throw new Error("區域網路 OpenList 密碼不在目前分頁工作階段中。請回到雲端書庫重新保存 LAN 來源連線，再開啟這本書。");
  }

  const loginUrl = new URL("api/auth/login", baseUrl + "/").href;
  const loginResponse = await fetch(loginUrl, {
    method: "POST",
    mode: "cors",
    credentials: "omit",
    redirect: "error",
    headers: { "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ username, password }),
    ...localNetworkOptions(loginUrl)
  });
  let loginData = {};
  try { loginData = await loginResponse.json(); } catch (_) {}
  const token = String(loginData?.data?.token || "");
  if (!loginResponse.ok || Number(loginData?.code) !== 200 || !token) {
    throw new Error("區域網路 OpenList 登入失敗：" + String(loginData?.message || loginData?.error || ("HTTP " + loginResponse.status)));
  }

  const getUrl = new URL("api/fs/get", baseUrl + "/").href;
  const metadataResponse = await fetch(getUrl, {
    method: "POST",
    mode: "cors",
    credentials: "omit",
    redirect: "error",
    headers: { "Authorization": token, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({ path: source.path, password: "" }),
    ...localNetworkOptions(getUrl)
  });
  let metadataPayload = {};
  try { metadataPayload = await metadataResponse.json(); } catch (_) {}
  const metadata = metadataPayload?.data || {};
  if (!metadataResponse.ok || Number(metadataPayload?.code) !== 200 || metadata.is_dir || !metadata.raw_url) {
    throw new Error("區域網路 OpenList 無法取得書籍下載位址：" + String(metadataPayload?.message || metadataPayload?.error || ("HTTP " + metadataResponse.status)));
  }

  let target;
  try { target = new URL(String(metadata.raw_url), baseUrl + "/"); }
  catch (_) { throw new Error("區域網路 OpenList 回傳的下載位址無效。"); }
  if (target.protocol !== "http:" && target.protocol !== "https:") {
    throw new Error("區域網路 OpenList 回傳了不支援的下載協定。");
  }
  const fileResponse = await fetch(target.href, {
    method: "GET",
    mode: "cors",
    credentials: "omit",
    redirect: "follow",
    ...localNetworkOptions(target.href)
  });
  if (!fileResponse.ok) throw new Error("區域網路書檔讀取失敗：HTTP " + fileResponse.status);
  return makeFile(await fileResponse.blob(), record);
}

export async function fetchCloudBookFile(record) {
  if (!record || !record.cloudSource) throw new Error("這筆書籍沒有雲端來源資訊。");
  const source = record.cloudSource;
  if (source.provider === "local") return fetchLocalOpenListFile(source, record);

  const query = new URLSearchParams({
    provider: String(source.provider || ""),
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
