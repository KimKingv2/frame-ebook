import { importBookFile } from "/assets/library-store.js?v=20261114-shelf-classification1";

const $ = id => document.getElementById(id);
const ACTIVE_PROVIDER_KEY = "frame-reader-active-openlist-provider";
const LOCAL_PROFILE_KEY = "frame-reader-local-openlist-profile-v2";
const LEGACY_LOCAL_PROFILE_KEY = "frame-reader-local-openlist-profile-v1";
const LOCAL_PASSWORD_SESSION_KEY = "frame-reader-local-openlist-password-v1";
const PROVIDER_LABELS = {
  vps: "VPS Alist",
  worker: "OpenList Worker",
  mobile: "Mobile Device Alist",
  local: "區域網路 OpenList"
};
const LIBRARY_LABELS = { books: "電子書", comics: "漫畫" };
const state = {
  authenticated:false,
  accessEnabled:false,
  allowedRoots:{books:"/",comics:"/"},
  selectedRoots:{books:"/",comics:"/"},
  currentPath:"/",
  items:[],
  query:"",
  busy:new Set(),
  page:1,
  perPage:80,
  total:0,
  serverProfiles:{},
  activeProvider:"vps",
  activeLibrary:"books",
  localProfile:{baseUrl:"",username:"",password:""},
  connected:false,
  scanRunning:false,
  scanPauseRequested:false,
  scanState:null,
  scanLogEntries:[]
};

function formatBytes(bytes) {
  const value=Number(bytes)||0;
  if(value<1024*1024)return Math.round(value/1024)+" KB";
  if(value<1024*1024*1024)return (value/(1024*1024)).toFixed(1)+" MB";
  return (value/(1024*1024*1024)).toFixed(2)+" GB";
}
function joinPath(parent,name) {
  return (String(parent||"/").replace(/\/+$/,"")+"/"+String(name||"")).replace(/^$/,"/");
}
function normalizePath(value) {
  const raw=String(value||"/").replace(/\\/g,"/");
  if(raw.includes("\0"))return null;
  const parts=raw.split("/");
  if(parts.some(part=>part===".."))return null;
  return "/"+parts.filter(part=>part&&part!==".").join("/");
}
function isWithinRoot(path,root) {
  if(!path||!root)return false;
  const base=normalizePath(root);
  if(!base)return false;
  return base==="/"?path.startsWith("/"):path===base||path.startsWith(base+"/");
}
function fileKind(item) {
  const ext=String(item.name||"").split(".").pop().toLowerCase();
  return ext==="epub"?"EPUB":ext==="cbz"?"CBZ":"";
}
function getAllowedRoot(library=state.activeLibrary) {
  void library;
  return "/";
}
function getActiveRoot(library=state.activeLibrary) {
  return state.selectedRoots[library]||getAllowedRoot(library);
}
function breadcrumb(path) {
  const root=getActiveRoot()||"/";
  const rel=path===root?"":path.slice(root==="/"?1:root.length+1);
  return rel?root.replace(/\/$/,"")+" / "+rel.replace(/\//g," / "):root;
}
function readLocalProfile() {
  let saved={};
  let legacy={};
  try { saved=JSON.parse(localStorage.getItem(LOCAL_PROFILE_KEY)||"{}"); } catch (_) {}
  try { legacy=JSON.parse(localStorage.getItem(LEGACY_LOCAL_PROFILE_KEY)||"{}"); } catch (_) {}
  let sessionPassword="";
  try { sessionPassword=sessionStorage.getItem(LOCAL_PASSWORD_SESSION_KEY)||""; } catch (_) {}
  state.localProfile={
    baseUrl:String(saved.baseUrl||legacy.baseUrl||""),
    username:String(saved.username||""),
    password:sessionPassword
  };
  try { localStorage.removeItem(LEGACY_LOCAL_PROFILE_KEY); } catch (_) {}
  $("cloud-local-url").value=state.localProfile.baseUrl;
  $("cloud-local-username").value=state.localProfile.username;
  $("cloud-local-password").value=state.localProfile.password;
}
function readRootSelections() {
  try { localStorage.removeItem("frame-reader-cloud-root-selections-v1"); } catch (_) {}
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root":"cloud-comics-root";
    const candidate=normalizePath($(id).value||"/");
    state.selectedRoots[library]=candidate||"/";
    $(id).value=state.selectedRoots[library];
  }
  renderRootStatus();
}
function renderRootStatus() {
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root-status":"cloud-comics-root-status";
    const selected=state.selectedRoots[library]||"/";
    $(id).textContent="目前頁面使用："+selected+"（重新整理後回到 HTML 預設值）";
  }
}
function normalizeLocalBase(value) {
  const raw=String(value||"").trim();
  let url;
  try { url=new URL(raw); } catch (_) { throw new Error("區域網路 OpenList 網址格式不正確。"); }
  if(!["http:","https:"].includes(url.protocol))throw new Error("OpenList 網址必須使用 HTTP 或 HTTPS。");
  if(url.username||url.password||url.search||url.hash)throw new Error("OpenList 網址不可包含帳號、密碼、查詢參數或片段。");
  const host=url.hostname.toLowerCase();
  const octets=host.match(/^\d{1,3}(?:\.\d{1,3}){3}$/)?.[0].split(".").map(Number);
  const validIpv4=!!octets&&octets.every(v=>Number.isInteger(v)&&v>=0&&v<=255);
  const privateIpv4=validIpv4&&(octets[0]===10||(octets[0]===172&&octets[1]>=16&&octets[1]<=31)||(octets[0]===192&&octets[1]===168)||(octets[0]===169&&octets[1]===254));
  const loopback=["localhost","127.0.0.1","[::1]"].includes(host)||host.startsWith("127.");
  const tailscale=validIpv4&&octets[0]===100&&octets[1]>=64&&octets[1]<=127;
  if(url.protocol==="http:"&&!privateIpv4&&!loopback&&!tailscale)throw new Error("HTTP 僅允許私有 LAN、迴圈位址或 Tailscale 網址；其他網址請使用 HTTPS。");
  return url.origin+url.pathname.replace(/\/+$/,"");
}
function localNetworkOptions(url) {
  let host="";
  try { host=new URL(url).hostname; } catch (_) {}
  if(host==="localhost"||host==="127.0.0.1"||host.startsWith("127."))return {targetAddressSpace:"loopback"};
  if(/^(10\.|192\.168\.|169\.254\.)/.test(host)||/^172\.(1[6-9]|2\d|3[01])\./.test(host)||/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(host))return {targetAddressSpace:"local"};
  return {};
}
function setSourceStatus(message,isError=false) {
  $("cloud-source-status").textContent=message;
  $("cloud-source-status").classList.toggle("is-error",!!isError);
}
function renderProfileStatus() {
  const map={vps:"cloud-vps-status",worker:"cloud-worker-status",mobile:"cloud-mobile-status"};
  for(const [provider,id] of Object.entries(map)) {
    const configured=!!state.serverProfiles[provider]?.configured;
    $(id).textContent=configured?"已設定，可供選用":"尚未設定";
    $(id).classList.toggle("is-ready",configured);
    $(id).classList.toggle("is-missing",!configured);
  }
}
function clearListing(message="尚未連線") {
  state.items=[];
  state.total=0;
  state.connected=false;
  state.query="";
  $("cloud-search").value="";
  $("cloud-items").replaceChildren();
  $("cloud-item-count").textContent="0 個項目";
  $("cloud-breadcrumb").textContent=getActiveRoot()||"尚未設定根目錄";
  $("cloud-page-label").textContent=message;
  $("cloud-prev-page").disabled=true;
  $("cloud-next-page").disabled=true;
  $("cloud-empty").hidden=true;
  $("cloud-connection-status").textContent="尚未測試 · "+PROVIDER_LABELS[state.activeProvider];
}
function persistActiveProvider(provider) {
  state.activeProvider=provider;
  try { localStorage.setItem(ACTIVE_PROVIDER_KEY,provider); } catch (_) {}
  $("cloud-provider").value=provider;
  clearListing();
}
function saveRootSelections() {
  const values={
    books:String($("cloud-books-root").value||"").trim(),
    comics:String($("cloud-comics-root").value||"").trim()
  };
  for(const library of ["books","comics"]) {
    const candidate=normalizePath(values[library]||"/");
    if(!candidate)throw new Error(LIBRARY_LABELS[library]+"路徑無效，請使用絕對路徑且不要包含 ..。");
    state.selectedRoots[library]=candidate;
    $(library==="books"?"cloud-books-root":"cloud-comics-root").value=candidate;
  }
  renderRootStatus();
  clearListing("目錄設定已套用");
  setSourceStatus("電子書與漫畫根目錄已套用到目前頁面。切換 VPS、Worker、Mobile Device 或 LAN 時會沿用；重新整理後會回到 HTML 的 value 預設值。");
}
function saveSourceSettings() {
  const provider=$("cloud-provider").value;
  if(!Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,provider))throw new Error("請選擇有效的書庫來源。");
  if(provider==="local") {
    const baseUrl=normalizeLocalBase($("cloud-local-url").value);
    const username=String($("cloud-local-username").value||"").trim();
    const password=String($("cloud-local-password").value||"");
    if(!username||!password)throw new Error("請填入這台裝置的區域網路 OpenList 帳號與密碼。");
    state.localProfile={baseUrl,username,password};
    try {
      localStorage.setItem(LOCAL_PROFILE_KEY,JSON.stringify({baseUrl,username}));
      sessionStorage.setItem(LOCAL_PASSWORD_SESSION_KEY,password);
    } catch (_) { throw new Error("無法保存本機來源連線資料，請檢查瀏覽器儲存空間權限。"); }
  } else if(!state.serverProfiles[provider]?.configured) {
    throw new Error(PROVIDER_LABELS[provider]+" 尚未在 Cloudflare Pages Variables／Secrets 完成設定。");
  }
  persistActiveProvider(provider);
  setSourceStatus("已保存來源設定："+PROVIDER_LABELS[provider]+"。OpenList 會在連線時使用帳號密碼自動登入。");
  return provider;
}
function getActiveProfile() {
  if(state.activeProvider==="local") {
    const profile=state.localProfile;
    if(!profile.baseUrl||!profile.username||!profile.password)throw new Error("尚未保存區域網路 OpenList 網址、帳號與目前分頁密碼。");
    return {baseUrl:normalizeLocalBase(profile.baseUrl),username:profile.username,password:profile.password};
  }
  if(!state.serverProfiles[state.activeProvider]?.configured)throw new Error(PROVIDER_LABELS[state.activeProvider]+" 尚未完成 Cloudflare Pages 帳號密碼設定。");
  return null;
}
async function directOpenList(endpoint,payload) {
  const profile=getActiveProfile();
  const loginUrl=new URL("api/auth/login",profile.baseUrl+"/").href;
  let loginResponse;
  try {
    loginResponse=await fetch(loginUrl,{
      method:"POST",mode:"cors",credentials:"omit",redirect:"error",
      headers:{"Content-Type":"application/json",Accept:"application/json"},
      body:JSON.stringify({username:profile.username,password:profile.password}),
      ...localNetworkOptions(loginUrl)
    });
  } catch (cause) {
    throw new Error("無法連接區域網路 OpenList 登入端點。請確認服務、網址、CORS（Content-Type）及本機網路權限。"+(cause?.message?" 詳情："+String(cause.message).slice(0,140):""));
  }
  let loginData;
  try { loginData=await loginResponse.json(); } catch (_) { throw new Error("區域網路 OpenList 登入回應不是有效 JSON（HTTP "+loginResponse.status+"）。"); }
  if(!loginResponse.ok||Number(loginData?.code)!==200||!loginData?.data?.token) {
    throw new Error("區域網路 OpenList 帳號密碼登入失敗："+String(loginData?.message||loginData?.error||("HTTP "+loginResponse.status)));
  }
  const url=new URL("api/fs/"+endpoint,profile.baseUrl+"/").href;
  let response;
  try {
    response=await fetch(url,{
      method:"POST",mode:"cors",credentials:"omit",redirect:"error",
      headers:{Authorization:String(loginData.data.token),"Content-Type":"application/json",Accept:"application/json"},
      body:JSON.stringify(payload),
      ...localNetworkOptions(url)
    });
  } catch (cause) {
    throw new Error("無法直接連接區域網路 OpenList API。請確認服務、CORS（Authorization／Content-Type）及本機網路權限。"+(cause?.message?" 詳情："+String(cause.message).slice(0,140):""));
  }
  let data;
  try { data=await response.json(); } catch (_) { throw new Error("區域網路 OpenList 回應不是有效 JSON（HTTP "+response.status+"）。"); }
  if(!response.ok)throw new Error(data?.message||data?.error||"OpenList HTTP "+response.status);
  if(Number(data?.code)!==200)throw new Error("區域網路 OpenList API "+(data?.code||"unknown")+"："+String(data?.message||"未知錯誤"));
  return data;
}
async function listLocalDirectory(path,page,perPage=state.perPage) {
  const payload=await directOpenList("list",{path,password:"",page,per_page:perPage,refresh:false});
  const data=payload.data||{};
  const content=Array.isArray(data.content)?data.content:[];
  const items=content.map(item=>{
    const itemPath=normalizePath(joinPath(path,item.name));
    if(!itemPath||!isWithinRoot(itemPath,getActiveRoot()))return null;
    const isDir=!!item.is_dir;
    const format=isDir?"":fileKind(item);
    const allowed=state.activeLibrary==="comics"?(format==="EPUB"||format==="CBZ"):format==="EPUB";
    if(!isDir&&!allowed)return null;
    return {name:String(item.name||""),path:itemPath,isDir,format,size:Number(item.size)||0,modified:item.modified||item.created||null,supported:true};
  }).filter(Boolean);
  return {path,rootPath:getAllowedRoot(),page:Number(data.page)||page,perPage:Number(data.per_page)||state.perPage,total:Number(data.total)||items.length,items};
}
async function downloadLocalFile(path) {
  const allowedExtension=state.activeLibrary==="comics"?/\.(epub|cbz)$/i:/\.epub$/i;
  if(!isWithinRoot(path,getActiveRoot())||!allowedExtension.test(path))throw new Error("檔案格式或路徑不符合目前的"+LIBRARY_LABELS[state.activeLibrary]+"書庫。");
  const payload=await directOpenList("get",{path,password:""});
  const metadata=payload.data||{};
  if(metadata.is_dir||!metadata.raw_url)throw new Error("OpenList 沒有提供這個檔案的下載位址。");
  const profile=getActiveProfile();
  let target;
  try { target=new URL(String(metadata.raw_url),profile.baseUrl+"/"); }
  catch (_) { throw new Error("OpenList 回傳的檔案位址無效。"); }
  if(!["http:","https:"].includes(target.protocol))throw new Error("OpenList 回傳了不支援的下載協定。");
  let response;
  try { response=await fetch(target.href,{method:"GET",mode:"cors",credentials:"omit",redirect:"follow",...localNetworkOptions(target.href)}); }
  catch (_) { throw new Error("已取得檔案資訊，但瀏覽器無法讀取檔案內容。請檢查下載來源主機的 CORS。"); }
  if(!response.ok)throw new Error("檔案下載失敗：HTTP "+response.status);
  return await response.blob();
}
function isActiveSourceReady() {
  if(state.activeProvider==="local") return !!(state.localProfile.baseUrl&&state.localProfile.username&&state.localProfile.password);
  return !!state.serverProfiles[state.activeProvider]?.configured;
}
async function readJsonResponse(response, fallback) {
  let data = {};
  try { data = await response.json(); } catch (_) {}
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || fallback || ("HTTP " + response.status));
  }
  return data;
}
function indexScope() {
  return {
    provider: state.activeProvider,
    library: state.activeLibrary,
    rootPath: getActiveRoot()
  };
}
function setIndexProgress(message, isError=false) {
  const node = $("cloud-index-progress");
  if (!node) return;
  node.textContent = message;
  node.classList.toggle("is-error", !!isError);
}
function appendIndexLog(message, level="info") {
  const now = new Date();
  const timestamp = [now.getHours(),now.getMinutes(),now.getSeconds()].map(v=>String(v).padStart(2,"0")).join(":") +
    "." + String(now.getMilliseconds()).padStart(3,"0");
  const line = timestamp + "  " + String(message || "");
  state.scanLogEntries.push(line);
  if (state.scanLogEntries.length > 300) state.scanLogEntries.shift();
  const output = $("cloud-index-log");
  if (output) {
    output.textContent = state.scanLogEntries.join("\\n");
    output.scrollTop = output.scrollHeight;
  }
  const count = $("cloud-index-log-count");
  if (count) count.textContent = state.scanLogEntries.length + " 筆";
}
function renderIndexStatus(summary) {
  const node = $("cloud-index-status");
  if (!node) return;
  if (!summary) {
    node.textContent = "尚未建立索引";
    setIndexProgress("首次使用請先手動掃描電子書或漫畫目錄。掃描完成後，日常開啟會直接讀取 D1 索引。");
    return;
  }
  state.scanState = summary;
  if (summary.completed) {
    const date = summary.updatedAt ? new Date(summary.updatedAt).toLocaleString("zh-TW") : "時間未知";
    node.textContent = "索引已完成 · " + Number(summary.indexedCount || 0) + " 個項目";
    setIndexProgress("最近完成：" + date + "；已檢查 " + Number(summary.scannedCount || 0) +
      " 個目錄項目，索引 " + Number(summary.indexedCount || 0) + " 個項目，資料夾 " +
      Number(summary.visitedFolderCount || 0) + " 個。再次掃描會檢查新增、變更及已刪除項目。");
  } else {
    node.textContent = summary.currentFolder || summary.pendingFolders?.length
      ? "索引未完成 · 可續掃"
      : "索引尚未完成 · 可續掃";
    setIndexProgress("目前已檢查 " + Number(summary.scannedCount || 0) + " 個目錄項目，索引 " +
      Number(summary.indexedCount || 0) + " 個項目；已完成資料夾 " +
      Number(summary.visitedFolderCount || 0) + " 個。點擊「手動掃描／續掃」會從 D1 保存的游標繼續。");
  }
}
async function scanStateRequest(method="GET", scanState=null) {
  const scope = indexScope();
  const url = new URLSearchParams({
    provider: scope.provider,
    library: scope.library,
    root_path: scope.rootPath
  });
  const response = await fetch("/api/cloud/index/state" + (method === "GET" ? "?" + url.toString() : ""), {
    method,
    credentials: "same-origin",
    headers: method === "POST" ? { "Content-Type": "application/json" } : {},
    body: method === "POST" ? JSON.stringify({
      provider: scope.provider,
      library: scope.library,
      rootPath: scope.rootPath,
      state: scanState
    }) : undefined
  });
  return readJsonResponse(response, "讀取／保存 D1 掃描進度失敗。");
}
async function loadIndexScanState() {
  return (await scanStateRequest("GET")).state || null;
}
async function saveIndexScanState(scanState) {
  scanState.updatedAt = new Date().toISOString();
  await scanStateRequest("POST", scanState);
}
function newIndexScanState(rootPath, provider, library) {
  const scanId = typeof crypto.randomUUID === "function"
    ? crypto.randomUUID().replace(/-/g, "")
    : "scan_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2,12);
  return {
    version: 1,
    provider,
    library,
    rootPath,
    scanId,
    pendingFolders: [rootPath],
    currentFolder: null,
    page: 1,
    seenFolders: [rootPath],
    scannedCount: 0,
    indexedCount: 0,
    visitedFolderCount: 0,
    completed: false,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
}
function indexScanProgressText(scanState, batch, finished=false) {
  const lines = [
    "來源：" + PROVIDER_LABELS[scanState.provider] + " · " + LIBRARY_LABELS[scanState.library],
    "根目錄：" + scanState.rootPath,
    "已檢查：" + Number(scanState.scannedCount || 0) + " 個目錄項目",
    "已寫入／更新：" + Number(scanState.indexedCount || 0) + " 個索引項目",
    "已完成資料夾：" + Number(scanState.visitedFolderCount || 0) + " 個",
    "待掃描資料夾：" + scanState.pendingFolders.length + (scanState.currentFolder ? "；目前：" + scanState.currentFolder : ""),
    "本批檢查：" + batch.entries + " 個項目；寫入：" + batch.indexed + " 個；完成資料夾：" + batch.folders + " 個"
  ];
  if (scanState.currentFolder) lines.push("目前頁面：" + scanState.page + "；掃描游標會在每頁完成後保存。");
  if (scanState.completed) lines.push("完整索引已完成。下次開啟書庫會直接讀取 D1，不會自動重新掃描。");
  else if (finished) lines.push("本批結束，進度已保存到 D1；可以關閉頁面，之後再續掃。");
  else if (state.scanPauseRequested) lines.push("已要求暫停，當前頁完成並保存後停止。");
  else lines.push("掃描進行中；每完成一頁都會將索引資料和續掃游標保存至 D1。");
  return lines.join("\\n");
}
async function fetchScanDirectory(path, page, perPage) {
  if (state.activeProvider === "local") {
    return listLocalDirectory(path, page, perPage);
  }
  const scope = indexScope();
  const query = new URLSearchParams({
    provider: scope.provider,
    library: scope.library,
    root_path: scope.rootPath,
    path,
    page: String(page),
    per_page: String(perPage)
  });
  const response = await fetch("/api/cloud/scan-list?" + query.toString(), { credentials: "same-origin" });
  const data = await readJsonResponse(response, "讀取 OpenList 目錄失敗。");
  return data;
}
async function writeIndexEntries(scanState, entries) {
  if (!entries.length) return 0;
  const scope = indexScope();
  let saved = 0;
  for (let offset = 0; offset < entries.length; offset += 100) {
    const response = await fetch("/api/cloud/index/entries", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider: scope.provider,
        library: scope.library,
        rootPath: scope.rootPath,
        scanId: scanState.scanId,
        entries: entries.slice(offset, offset + 100)
      })
    });
    const data = await readJsonResponse(response, "寫入 D1 書庫索引失敗。");
    saved += Number(data.saved || 0);
  }
  return saved;
}
async function runIndexScan() {
  if (state.scanRunning) return;
  if (!state.authenticated) {
    setIndexProgress("尚未通過 Cloudflare Access，無法開始索引。", true);
    return;
  }
  if (!isActiveSourceReady()) {
    setIndexProgress("請先完成目前 OpenList 來源的網址、帳號與密碼設定。", true);
    return;
  }
  const scope = indexScope();
  const startButton = $("cloud-scan-start");
  const pauseButton = $("cloud-scan-pause");
  let scanState = null;
  const batch = { entries: 0, indexed: 0, folders: 0 };
  try {
    appendIndexLog("========== 雲端書庫索引開始 ==========");
    appendIndexLog("讀取 D1 掃描進度開始。");
    scanState = await loadIndexScanState();
    if (scanState && scanState.rootPath === scope.rootPath &&
        scanState.provider === scope.provider && scanState.library === scope.library &&
        scanState.version === 1 && !scanState.completed) {
      appendIndexLog("找到未完成的掃描進度，將從上次保存的位置續掃。", "warning");
    } else {
      if (scanState?.completed && !window.confirm(
        "這個來源與分類的上一輪索引已完成。重新掃描會檢查新增、變更和刪除的檔案；只有完整掃描結束後才會清理已不存在的索引。確定開始新一輪嗎？"
      )) return;
      scanState = newIndexScanState(scope.rootPath, scope.provider, scope.library);
      await saveIndexScanState(scanState);
      appendIndexLog("建立新掃描工作與 D1 進度記錄。", "success");
    }

    state.scanRunning = true;
    state.scanPauseRequested = false;
    startButton.disabled = true;
    pauseButton.disabled = false;
    const startedAt = Date.now();
    const maxEntriesPerBatch = 500;
    const maxFoldersPerBatch = 500;
    const maxDurationMs = 240000;
    const pageSize = 100;
    const seen = new Set(Array.isArray(scanState.seenFolders) ? scanState.seenFolders : [scope.rootPath]);

    while (!scanState.completed &&
      batch.entries < maxEntriesPerBatch &&
      batch.folders < maxFoldersPerBatch &&
      Date.now() - startedAt < maxDurationMs &&
      !state.scanPauseRequested) {
      if (!scanState.currentFolder) {
        if (!scanState.pendingFolders.length) break;
        scanState.currentFolder = scanState.pendingFolders.shift();
        scanState.page = 1;
        await saveIndexScanState(scanState);
        appendIndexLog("進入資料夾：" + scanState.currentFolder);
      }

      const currentFolder = scanState.currentFolder;
      const page = Math.max(1, Number(scanState.page) || 1);
      setIndexProgress(indexScanProgressText(scanState, batch), false);
      appendIndexLog("讀取目錄列表：" + currentFolder + "；第 " + page + " 頁。");
      const listing = await fetchScanDirectory(currentFolder, page, pageSize);
      const found = Array.isArray(listing.items) ? listing.items : [];
      const entries = [];
      for (const item of found) {
        const path = normalizePath(item.path || joinPath(currentFolder, item.name));
        const name = String(item.name || "");
        if (!path || !name) continue;
        const isDir = !!item.isDir;
        const format = isDir ? "" : fileKind(item);
        const allowed = isDir || (scope.library === "comics"
          ? format === "EPUB" || format === "CBZ"
          : format === "EPUB");
        if (!allowed || !isWithinRoot(path, scope.rootPath)) continue;
        entries.push({
          path,
          parentPath: currentFolder,
          name,
          isDir,
          format,
          size: Math.max(0, Number(item.size) || 0),
          modified: item.modified || null
        });
        if (isDir && !seen.has(path)) {
          seen.add(path);
          scanState.seenFolders.push(path);
          scanState.pendingFolders.push(path);
        }
      }

      const saved = await writeIndexEntries(scanState, entries);
      scanState.scannedCount += found.length;
      scanState.indexedCount += saved;
      batch.entries += found.length;
      batch.indexed += saved;
      appendIndexLog("本頁完成：" + currentFolder + "；第 " + page + " 頁；讀取 " +
        found.length + " 個項目；保存 " + saved + " 筆索引。", "success");

      const total = Math.max(0, Number(listing.total) || found.length);
      if (page * pageSize < total) {
        scanState.page = page + 1;
      } else {
        scanState.currentFolder = null;
        scanState.page = 1;
        scanState.visitedFolderCount += 1;
        batch.folders += 1;
      }
      await saveIndexScanState(scanState);
      setIndexProgress(indexScanProgressText(scanState, batch), false);
    }

    if (!scanState.currentFolder && scanState.pendingFolders.length === 0) {
      appendIndexLog("所有資料夾已掃描，開始清理本根目錄中已不存在的索引項目。");
      const response = await fetch("/api/cloud/index/complete", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          provider: scope.provider,
          library: scope.library,
          rootPath: scope.rootPath,
          scanId: scanState.scanId
        })
      });
      const completed = await readJsonResponse(response, "清理過期索引失敗。");
      scanState.completed = true;
      scanState.completedAt = new Date().toISOString();
      await saveIndexScanState(scanState);
      appendIndexLog("索引完成；清理已不存在項目 " + Number(completed.removed || 0) + " 筆。", "success");
    }

    if (scanState.completed) {
      setIndexProgress(indexScanProgressText(scanState, batch, true), false);
      appendIndexLog("========== 完整索引完成 ==========", "success");
    } else {
      const reason = state.scanPauseRequested ? "使用者暫停" :
        batch.entries >= maxEntriesPerBatch ? "達到每批 500 個項目上限" :
        batch.folders >= maxFoldersPerBatch ? "達到每批 500 個資料夾上限" :
        "達到單批 4 分鐘安全時限";
      await saveIndexScanState(scanState);
      setIndexProgress(indexScanProgressText(scanState, batch, true) + "\\n本批停止原因：" + reason, false);
      appendIndexLog("本批結束：" + reason + "；進度已保存，可再次點擊續掃。", "warning");
    }
  } catch (error) {
    appendIndexLog("索引發生錯誤：" + (error.message || error), "error");
    if (scanState) {
      scanState.lastError = String(error.message || error).slice(0, 700);
      try { await saveIndexScanState(scanState); } catch (_) {}
    }
    setIndexProgress((error.message || "索引失敗。") +
      "\\n目前游標已盡可能保存；修復問題後可再次點擊續掃。", true);
  } finally {
    state.scanRunning = false;
    state.scanPauseRequested = false;
    startButton.disabled = false;
    pauseButton.disabled = true;
    try {
      const latest = await loadIndexScanState();
      renderIndexStatus(latest);
      if (isActiveSourceReady()) await loadDirectory(state.currentPath || getActiveRoot(), state.page || 1);
    } catch (_) {}
  }
}
function pauseIndexScan() {
  if (!state.scanRunning) return;
  state.scanPauseRequested = true;
  $("cloud-scan-pause").disabled = true;
  setIndexProgress("已要求暫停；目前目錄頁完成並保存 D1 游標後就會停止。");
}

async function checkSession() {
  try {
    const response=await fetch("/api/auth/session",{credentials:"same-origin"});
    const data=await response.json();
    state.authenticated=!!(response.ok&&data.authenticated);
    state.accessEnabled=!!data.accessEnabled;
    state.serverProfiles=data.openListProfiles||{};
    state.allowedRoots={books:"/",comics:"/"};
    if(state.authenticated) {
      $("cloud-login-panel").hidden=true;
      $("cloud-browser").hidden=false;
      readLocalProfile();
      readRootSelections();
      renderProfileStatus();
      let selectedProvider="vps",selectedLibrary="books";
      try {
        const savedProvider=localStorage.getItem(ACTIVE_PROVIDER_KEY)||"vps";
        if(Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,savedProvider))selectedProvider=savedProvider;
        const savedLibrary=localStorage.getItem("frame-reader-active-library")||"books";
        if(savedLibrary==="books"||savedLibrary==="comics")selectedLibrary=savedLibrary;
      } catch (_) {}
      state.activeProvider=selectedProvider;
      state.activeLibrary=selectedLibrary;
      $("cloud-provider").value=selectedProvider;
      $("cloud-library-type").value=selectedLibrary;
      clearListing();
      if(isActiveSourceReady()) {
        state.currentPath=getActiveRoot();
        setSourceStatus("私人書庫已登入，正在讀取 "+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+" 的 D1 索引……");
        await loadDirectory(state.currentPath,1);
      } else {
        setSourceStatus("私人書庫已登入。請先完成 "+PROVIDER_LABELS[state.activeProvider]+" 的帳號密碼設定，再按「重新連線／讀取書架」。",true);
      }
      try {
        const tracker=await import("/assets/reading-tracker.js");
        await tracker.syncPending(true);
      } catch (_) {}
    } else {
      $("cloud-login-panel").hidden=false;
      $("cloud-browser").hidden=true;
      $("cloud-access-required").hidden=false;
      $("cloud-access-required").textContent=state.accessEnabled
        ?"目前請求沒有 Cloudflare Access 驗證資訊。請確認 Cloudflare Access 已保護整個網站主機，而不只是個別頁面。"
        :"尚未通過 Cloudflare Access。請確認此網站主機已啟用 Access Policy，並使用允許的登入身分。";
    }
  } catch(error) {
    $("cloud-browser-status").textContent="無法確認登入狀態："+(error.message||String(error));
  }
}
async function logout() {
  location.href=new URL("/cdn-cgi/access/logout",location.origin).href;
}
async function loadDirectory(path=getActiveRoot(),page=1) {
  state.page=Math.max(1,Number(page)||1);
  const selected=getActiveRoot();
  const safePath=normalizePath(path);
  if(!selected||!isWithinRoot(selected,"/")) {
    const message="目前"+LIBRARY_LABELS[state.activeLibrary]+"根目錄無效。";
    $("cloud-browser-status").textContent=message;
    setSourceStatus(message,true);
    return;
  }
  if(!safePath||!isWithinRoot(safePath,selected)) {
    const message="目錄路徑無效或超出目前"+LIBRARY_LABELS[state.activeLibrary]+"根目錄。";
    $("cloud-browser-status").textContent=message;
    setSourceStatus(message,true);
    return;
  }
  $("cloud-browser-status").textContent="正在讀取 D1 書庫索引……";
  $("cloud-refresh").disabled=true;
  $("cloud-test-source").disabled=true;
  try {
    const query=new URLSearchParams({
      path:safePath,
      root_path:selected,
      page:String(state.page),
      per_page:String(state.perPage),
      provider:state.activeProvider,
      library:state.activeLibrary
    });
    const response=await fetch("/api/cloud/books?"+query.toString(),{credentials:"same-origin"});
    const data=await readJsonResponse(response,"D1 書庫索引讀取失敗。");
    state.currentPath=data.path||safePath;
    state.items=Array.isArray(data.items)?data.items:[];
    state.total=Number(data.total)||0;
    state.page=Number(data.page)||state.page;
    state.connected=true;
    renderIndexStatus(data.scanState);
    $("cloud-connection-status").textContent=data.indexed
      ?"已載入 D1 索引 · "+PROVIDER_LABELS[state.activeProvider]
      :data.scanState?"索引尚未完成 · "+PROVIDER_LABELS[state.activeProvider]:"尚無索引 · "+PROVIDER_LABELS[state.activeProvider];
    $("cloud-breadcrumb").textContent=breadcrumb(state.currentPath);
    $("cloud-item-count").textContent="顯示 "+state.items.length+" / "+state.total+" 個項目";
    $("cloud-page-label").textContent="第 "+state.page+" 頁 · 共 "+Math.max(1,Math.ceil(state.total/state.perPage))+" 頁";
    $("cloud-prev-page").disabled=state.page<=1;
    $("cloud-next-page").disabled=state.page*state.perPage>=state.total;
    renderItems();
    if(data.indexed) {
      $("cloud-browser-status").textContent="已從 D1 載入索引目錄。選擇書籍時才會讀取原始檔案；開啟此頁不會重新掃描 OpenList。";
      setSourceStatus("索引讀取成功："+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+" · "+safePath);
    } else if(data.scanState) {
      $("cloud-browser-status").textContent="目前顯示已建立的部分索引。掃描尚未完成，點擊「手動掃描／續掃」可繼續。";
      setSourceStatus("已讀取部分 D1 索引；尚有目錄待掃描。",true);
    } else {
      $("cloud-browser-status").textContent="這個來源與分類尚未建立索引。請先點擊「手動掃描／續掃」。";
      setSourceStatus("尚無索引："+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+"。首次使用請手動掃描。",true);
    }
  } catch(error) {
    state.connected=false;
    $("cloud-items").replaceChildren();
    $("cloud-page-label").textContent="索引尚未載入";
    $("cloud-prev-page").disabled=true;
    $("cloud-next-page").disabled=true;
    $("cloud-connection-status").textContent="索引讀取失敗";
    $("cloud-browser-status").textContent=error.message||String(error);
    setSourceStatus((error.message||String(error))+". 請確認 FRAME_READER_DB 已綁定並執行 0002 索引資料表遷移。",true);
  } finally {
    $("cloud-refresh").disabled=false;
    $("cloud-test-source").disabled=false;
  }
}
function makeItem(item) {
  const row=document.createElement("article");row.className="cloud-item";
  const icon=document.createElement("span");icon.className="cloud-item-icon";icon.textContent=item.isDir?"▰":item.format==="EPUB"?"▤":"▣";
  const copy=document.createElement("div");copy.className="cloud-item-copy";
  const title=document.createElement("strong");title.textContent=item.name;
  const meta=document.createElement("span");meta.textContent=item.isDir?"資料夾":(item.format+" · "+formatBytes(item.size)+(item.modified?" · "+String(item.modified).slice(0,10):""));
  copy.append(title,meta);
  const actions=document.createElement("div");actions.className="cloud-item-actions";
  if(item.isDir) {
    const open=document.createElement("button");open.type="button";open.className="cloud-folder-button";open.textContent="開啟資料夾";
    open.addEventListener("click",()=>loadDirectory(item.path,1));actions.append(open);
  } else if(item.format) {
    const add=document.createElement("button");add.type="button";add.className="cloud-import-button";add.textContent=state.busy.has(item.path)?"正在加入……":"加入本機書架";add.disabled=state.busy.has(item.path);
    add.addEventListener("click",()=>importCloudFile(item));actions.append(add);
  }
  row.append(icon,copy,actions);
  return row;
}
function renderItems() {
  const root=$("cloud-items");root.replaceChildren();
  const query=state.query.trim().toLocaleLowerCase();
  const items=state.items.filter(item=>!query||String(item.name).toLocaleLowerCase().includes(query));
  items.sort((a,b)=>Number(b.isDir)-Number(a.isDir)||String(a.name).localeCompare(String(b.name),"zh-Hant",{numeric:true,sensitivity:"base"}));
  items.forEach(item=>root.appendChild(makeItem(item)));
  $("cloud-empty").hidden=items.length>0;
}
async function importCloudFile(item) {
  if(state.busy.has(item.path))return;
  const library=state.activeLibrary;
  if(!isWithinRoot(item.path,getActiveRoot())) {
    $("cloud-browser-status").textContent="檔案路徑超出目前書庫根目錄。";
    return;
  }
  if((library==="books"&&item.format!=="EPUB")||(library==="comics"&&item.format!=="EPUB"&&item.format!=="CBZ")) {
    $("cloud-browser-status").textContent="檔案格式與目前選擇的書庫分類不符。";
    return;
  }
  state.busy.add(item.path);renderItems();
  $("cloud-browser-status").textContent="正在讀取 "+item.name+"……";
  try {
    let blob;
    if(state.activeProvider==="local") {
      blob=await downloadLocalFile(item.path);
    } else {
      const query=new URLSearchParams({path:item.path,provider:state.activeProvider,library});
      const response=await fetch("/api/cloud/file?"+query.toString(),{credentials:"same-origin"});
      if(!response.ok) {
        const data=await response.json().catch(()=>({}));
        throw new Error(data.error||"下載失敗：HTTP "+response.status);
      }
      blob=await response.blob();
    }
    const mime=item.format==="EPUB"?"application/epub+zip":"application/vnd.comicbook+zip";
    const modified=Date.parse(item.modified||"")||Date.now();
    const file=new File([blob],item.name,{type:mime,lastModified:modified});
    const record=await importBookFile(file,{shelf:library});
    $("cloud-browser-status").textContent="已加入本機書架："+record.title+"。正在開啟閱讀室……";
    location.href="/epub-lab/?book="+encodeURIComponent(record.id);
  } catch(error) {
    $("cloud-browser-status").textContent=(error.message||String(error))+"。原始雲端檔案沒有被修改。";
    state.busy.delete(item.path);renderItems();
  }
}
function setCurrentFolderAsRoot(library) {
  const candidate=normalizePath(state.currentPath);
  if(!candidate) {
    setSourceStatus("目前目錄路徑無效，無法設為"+LIBRARY_LABELS[library]+"根目錄。",true);
    return;
  }
  const id=library==="books"?"cloud-books-root":"cloud-comics-root";
  $(id).value=candidate;
  setSourceStatus("已選擇"+LIBRARY_LABELS[library]+"根目錄："+candidate+"。請按「套用兩個目錄設定」。");
}
$("cloud-scan-start").addEventListener("click",runIndexScan);
$("cloud-scan-pause").addEventListener("click",pauseIndexScan);
$("cloud-refresh").addEventListener("click",()=>loadDirectory(state.currentPath,state.page));
$("cloud-prev-page").addEventListener("click",()=>loadDirectory(state.currentPath,state.page-1));
$("cloud-next-page").addEventListener("click",()=>loadDirectory(state.currentPath,state.page+1));
$("cloud-root").addEventListener("click",()=>loadDirectory(getActiveRoot(),1));
$("cloud-up").addEventListener("click",()=>{
  const root=getActiveRoot();
  if(!root||state.currentPath===root)return;
  const trimmed=state.currentPath;
  const slash=trimmed.lastIndexOf("/");
  const parent=slash<=0?"/":trimmed.slice(0,slash);
  loadDirectory(parent=== "/" && root!=="/"?root:parent,1);
});
$("cloud-logout").addEventListener("click",logout);
$("cloud-search").addEventListener("input",event=>{state.query=event.target.value||"";renderItems();});
$("cloud-provider").addEventListener("change",event=>{
  const provider=event.target.value;
  state.activeProvider=provider;
  try { localStorage.setItem(ACTIVE_PROVIDER_KEY,provider); } catch (_) {}
  clearListing();
  if(isActiveSourceReady()) {
    state.currentPath=getActiveRoot();
    void loadDirectory(state.currentPath,1);
  } else {
    setSourceStatus("已選擇 "+PROVIDER_LABELS[provider]+"。請先完成該來源的帳號密碼設定。",true);
  }
});
$("cloud-library-type").addEventListener("change",event=>{
  const library=event.target.value==="comics"?"comics":"books";
  state.activeLibrary=library;
  try { localStorage.setItem("frame-reader-active-library",library); } catch (_) {}
  clearListing();
  if(isActiveSourceReady()) {
    state.currentPath=getActiveRoot(library);
    void loadDirectory(state.currentPath,1);
  } else {
    setSourceStatus("已切換至"+LIBRARY_LABELS[library]+"。完成目前來源設定後即可讀取。",true);
  }
});
$("cloud-save-source").addEventListener("click",()=>{
  try {
    saveSourceSettings();
    if(isActiveSourceReady()) {
      state.currentPath=getActiveRoot();
      void loadDirectory(state.currentPath,1);
    }
  } catch(error) { setSourceStatus(error.message||String(error),true); }
});
$("cloud-save-roots").addEventListener("click",()=>{
  try { saveRootSelections(); }
  catch(error) { setSourceStatus(error.message||String(error),true); }
});
$("cloud-use-current-books-root").addEventListener("click",()=>setCurrentFolderAsRoot("books"));
$("cloud-use-current-comics-root").addEventListener("click",()=>setCurrentFolderAsRoot("comics"));
$("cloud-test-source").addEventListener("click",async()=>{
  try {
    saveSourceSettings();
    saveRootSelections();
    const root=getActiveRoot();
    if(!root)throw new Error("尚未設定目前"+LIBRARY_LABELS[state.activeLibrary]+"根目錄。");
    state.currentPath=root;
    await loadDirectory(root,1);
  } catch(error) {
    setSourceStatus(error.message||String(error),true);
  }
});
checkSession();
