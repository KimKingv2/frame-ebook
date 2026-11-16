import { ZipReader, BlobWriter, TextWriter } from "/vendor/foliate-js/vendor/zip.js";

const $ = id => document.getElementById(id);
const isManagerEmbed = new URLSearchParams(window.location.search).get("manager") === "1" && window.parent !== window;
let embeddedManagerVisible = false;
if (isManagerEmbed) document.documentElement.classList.add("cloud-manager-embed");
const DEFAULT_ROOTS = {
  books: "/中國移動雲盤/Kim King/04 Boooooks/01 Books 歸檔",
  comics: "/中國移動雲盤/Kim King/11 Comic"
};
const PROVIDER_LABELS = {
  vps: "VPS Alist",
  worker: "OpenList Worker",
  mobile: "Mobile Device Alist"
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
  editProvider:"vps",
  editRoots:{books:"/",comics:"/"},
  activeLibrary:"books",
  remotePreferences:{},
  connected:false,
  scanRunning:false,
  scanAllRunning:false,
  scanPauseRequested:false,
  scanPauseReason:"",
  scanState:null,
  scanLogEntries:[],
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
function zipPath(value) {
  const parts=[];
  String(value||"").replace(/\\/g,"/").split("/").forEach(part=>{
    if(!part||part===".")return;
    if(part===".."){parts.pop();return;}
    parts.push(part);
  });
  return parts.join("/");
}
function archiveRelativePath(base,href) {
  let value=String(href||"").split(/[?#]/,1)[0];
  try { value=decodeURIComponent(value); } catch (_) {}
  return zipPath(value.startsWith("/")?value:(base?base+"/":"")+value);
}
function mimeFromCoverName(name) {
  const ext=String(name||"").split(".").pop().toLowerCase();
  return ({jpg:"image/jpeg",jpeg:"image/jpeg",png:"image/png",webp:"image/webp",gif:"image/gif",bmp:"image/bmp",avif:"image/avif"})[ext]||"";
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
async function loadRemotePreferences() {
  const response = await fetch("/api/reading/preferences", { credentials: "same-origin", cache: "no-store" });
  const data = await readJsonResponse(response, "無法讀取雲端偏好設定。請先套用 0005 雲端資料 migration。");
  state.remotePreferences = data.preferences || {};
  return state.remotePreferences;
}
async function saveRemotePreference(key, value) {
  const response = await fetch("/api/reading/preferences", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key, value })
  });
  const data = await readJsonResponse(response, "保存雲端偏好設定失敗。請確認 D1 migration 已套用。");
  state.remotePreferences = { ...state.remotePreferences, [key]: data.value };
  return data.value;
}
function readRootSelections(provider=state.activeProvider) {
  const saved = state.remotePreferences.roots || {};
  const source = saved?.[provider] || {};
  const roots = {};
  for (const library of ["books", "comics"]) {
    const id = library === "books" ? "cloud-books-root" : "cloud-comics-root";
    const fallback = DEFAULT_ROOTS[library];
    const candidate = normalizePath(source[library] || fallback);
    roots[library] = candidate || fallback;
    $(id).value = roots[library];
  }
  state.editProvider = provider;
  state.editRoots = roots;
  if (provider === state.activeProvider) state.selectedRoots = { ...roots };
  renderRootStatus();
}
async function persistRootSelections(provider=state.editProvider || state.activeProvider, roots=state.editRoots) {
  const saved = { ...(state.remotePreferences.roots || {}) };
  saved[provider] = {
    books: normalizePath(roots?.books) || DEFAULT_ROOTS.books,
    comics: normalizePath(roots?.comics) || DEFAULT_ROOTS.comics
  };
  await saveRemotePreference("roots", saved);
}
function renderRootStatus() {
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root-status":"cloud-comics-root-status";
    const selected=state.editRoots[library]||"/";
    $(id).textContent="目前已保存至雲端 D1："+selected;
  }
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
async function persistActiveProvider(provider) {
  state.activeProvider = provider;
  await saveRemotePreference("activeProvider", provider);
  $("cloud-provider").value = provider;
  clearListing();
}
async function saveRootSelections() {
  const provider = state.editProvider || state.activeProvider;
  const values = {
    books: String($("cloud-books-root").value || "").trim() || DEFAULT_ROOTS.books,
    comics: String($("cloud-comics-root").value || "").trim() || DEFAULT_ROOTS.comics
  };
  for (const library of ["books", "comics"]) {
    const candidate = normalizePath(values[library]);
    if (!candidate) throw new Error(LIBRARY_LABELS[library] + "路徑無效，請使用絕對路徑且不要包含 ..。");
    values[library] = candidate;
    $(library === "books" ? "cloud-books-root" : "cloud-comics-root").value = candidate;
  }
  state.editRoots = { ...values };
  await persistRootSelections(provider, values);
  if (provider === state.activeProvider) state.selectedRoots = { ...values };
  renderRootStatus();
  if (provider === state.activeProvider) clearListing("書籍與漫畫目錄設定已套用");
  setSourceStatus("已將 " + PROVIDER_LABELS[provider] + " 的電子書與漫畫根目錄保存至雲端 D1。");
}
async function saveSourceSettings() {
  const provider = state.editProvider || $("cloud-provider").value;
  if (!Object.prototype.hasOwnProperty.call(PROVIDER_LABELS, provider)) throw new Error("請選擇有效的 Alist／OpenList 來源。");
  if (!state.serverProfiles[provider]?.configured) {
    throw new Error(PROVIDER_LABELS[provider] + " 尚未在 Cloudflare Pages Variables／Secrets 完成伺服器端設定。");
  }
  await persistActiveProvider(provider);
  state.editProvider = provider;
  readRootSelections(provider);
  setSourceStatus("已保存並切換雲端來源：" + PROVIDER_LABELS[provider] + "。帳號密碼只由 Pages Functions 使用。");
  return provider;
}
function isActiveSourceReady() {
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
function indexScope(library=state.activeLibrary,provider=state.activeProvider) {
  return {
    provider,
    library,
    rootPath: getActiveRoot(library)
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
    output.textContent = state.scanLogEntries.join("\n");
    output.scrollTop = output.scrollHeight;
  }
  const count = $("cloud-index-log-count");
  if (count) count.textContent = state.scanLogEntries.length + " 筆";
}
function renderIndexStatus(summary) {
  const node=$("cloud-index-status");
  if(!node)return;
  if(!summary) {
    node.textContent="尚未建立索引";
    setIndexProgress("電子書與漫畫各自保存根目錄和掃描進度。可分別掃描，也可一鍵依序掃描兩個書庫。");
    return;
  }
  state.scanState=summary;
  if(summary.completed) {
    const date=summary.updatedAt?new Date(summary.updatedAt).toLocaleString("zh-TW"):"時間未知";
    node.textContent="索引已完成 · "+Number(summary.indexedCount||0)+" 個項目";
    setIndexProgress("最近完成："+date+"；已檢查 "+Number(summary.scannedCount||0)+
      " 個目錄項目，寫入／更新 "+Number(summary.indexedCount||0)+" 個，略過 "+
      Number(summary.skippedCount||0)+" 個，失敗 "+Number(summary.failedCount||0)+
      " 個；已完成資料夾 "+Number(summary.visitedFolderCount||0)+" 個。");
  } else {
    node.textContent="索引未完成 · 可續掃";
    setIndexProgress("目前已檢查 "+Number(summary.scannedCount||0)+" 個目錄項目，寫入／更新 "+
      Number(summary.indexedCount||0)+" 個；略過 "+Number(summary.skippedCount||0)+
      " 個；失敗 "+Number(summary.failedCount||0)+" 個；已完成資料夾 "+
      Number(summary.visitedFolderCount||0)+" 個。可從 D1 保存的游標續掃。");
  }
}
function renderLibraryScanSummary(library,scanState,rootPath) {
  const node=$(library==="books"?"cloud-books-scan-summary":"cloud-comics-scan-summary");
  const status=$(library==="books"?"cloud-books-scan-status":"cloud-comics-scan-status");
  if(!node)return;
  if(!scanState) {
    node.textContent="掃描根目錄："+(rootPath||"/")+"\n尚未開始掃描。";
    if(status)status.textContent="尚未掃描";
    return;
  }
  const complete=!!scanState.completed;
  if(status)status.textContent=complete?"索引完成":"可續掃";
  const lines=[
    "掃描根目錄："+String(scanState.rootPath||rootPath||"/"),
    "掃描模式："+String(scanState.scanMode||"完整遞迴掃描"),
    "已檢查："+Number(scanState.scannedCount||0)+" 個目錄項目",
    "已寫入／更新："+Number(scanState.indexedCount||0)+" 筆",
    "未變更而跳過：0 筆（完整重掃模式，不跳過既有項目）",
    "格式不符／範圍外而略過："+Number(scanState.skippedCount||0)+" 筆",
    "累計失敗："+Number(scanState.failedCount||0)+" 筆",
    "已完成資料夾："+Number(scanState.visitedFolderCount||0)+" 個",
    "待掃描資料夾："+(scanState.pendingFolders||[]).length+(scanState.currentFolder?"；目前："+scanState.currentFolder:""),
    "封面已保存："+Number(scanState.coverReadyCount||0)+" 本；無封面："+Number(scanState.coverMissingCount||0)+
      " 本；失敗："+Number(scanState.coverFailedCount||0)+" 本"
  ];
  if(scanState.currentFolder)lines.push("續作游標：第 "+Number(scanState.page||1)+" 頁");
  if(scanState.lastCompletedName)lines.push("最近完成："+String(scanState.lastCompletedName)+"｜"+String(scanState.lastCompletedPath||""));
  if(scanState.lastError)lines.push("最近錯誤："+String(scanState.lastError));
  if(scanState.completed)lines.push("狀態：目錄索引已完成；D1 書架已可直接載入。");
  else lines.push("狀態：掃描未完成；再次點擊對應按鈕即可續掃。");
  node.textContent=lines.join("\n");
}
async function renderAllScanSummaries(provider=state.activeProvider,roots=state.selectedRoots) {
  for(const library of ["books","comics"]) {
    const rootPath=roots[library]||"/";
    const scope={provider,library,rootPath};
    try {
      const summary=await loadIndexScanState(scope);
      renderLibraryScanSummary(library,summary,rootPath);
      if(library===state.activeLibrary)renderIndexStatus(summary);
    } catch(error) {
      const node=$(library==="books"?"cloud-books-scan-summary":"cloud-comics-scan-summary");
      if(node)node.textContent="讀取掃描進度失敗："+(error.message||String(error));
    }
  }
}

async function scanStateRequest(method="GET", scanState=null, scopeOverride=null) {
  const scope = scopeOverride || indexScope();
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
async function loadIndexScanState(scopeOverride=null) {
  return (await scanStateRequest("GET",null,scopeOverride)).state || null;
}
async function saveIndexScanState(scanState,scopeOverride=null) {
  scanState.updatedAt = new Date().toISOString();
  await scanStateRequest("POST",scanState,scopeOverride);
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
    skippedCount: 0,
    failedCount: 0,
    visitedFolderCount: 0,
    coverReadyCount: 0,
    coverMissingCount: 0,
    coverFailedCount: 0,
    pausedByUser: false,
    resumeOnNextOpen: false,
    errors: [],
    completed: false,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString()
  };
}
function indexScanProgressText(scanState,batch,finished=false) {
  const lines=[
    "掃描根目錄："+scanState.rootPath,
    "掃描來源／分類："+PROVIDER_LABELS[scanState.provider]+" · "+LIBRARY_LABELS[scanState.library],
    "掃描模式：完整遞迴掃描（每頁同步 D1；不下載原始 EPUB／CBZ）",
    "已檢查目錄項目："+Number(scanState.scannedCount||0),
    "已寫入／更新："+Number(scanState.indexedCount||0)+" 筆",
    "未變更而跳過：0 筆（完整重掃模式，不跳過既有項目）",
    "格式不符／範圍外而略過："+Number(scanState.skippedCount||0)+" 筆",
    "累計失敗："+Number(scanState.failedCount||0)+" 筆",
    "已完成資料夾："+Number(scanState.visitedFolderCount||0)+" 個",
    "待掃描資料夾："+(scanState.pendingFolders||[]).length+(scanState.currentFolder?"；目前："+scanState.currentFolder:""),
    "本批檢查："+Number(batch.entries||0)+" 個；寫入／更新："+Number(batch.indexed||0)+
      " 個；略過："+Number(batch.skipped||0)+" 個；失敗："+Number(batch.failed||0)+
      " 個；完成資料夾："+Number(batch.folders||0)+" 個"
  ];
  if(batch.currentPath)lines.push("正在處理："+batch.currentPath);
  if(batch.lastCompleted)lines.push("最近完成："+batch.lastCompleted);
  else if(scanState.lastCompletedName)lines.push("最近完成："+scanState.lastCompletedName+"｜"+String(scanState.lastCompletedPath||""));
  if(batch.coverProcessed!=null)lines.push("本批封面：處理 "+batch.coverProcessed+" 本；無封面 "+
    Number(batch.coverMissing||0)+" 本；失敗 "+Number(batch.coverFailed||0)+" 本；待處理 "+Number(batch.coverRemaining||0)+" 本");
  if(batch.stopReason)lines.push("本批停止原因："+batch.stopReason);
  if(scanState.currentFolder)lines.push("續作游標：第 "+Number(scanState.page||1)+" 頁；每頁完成後保存至 D1。");
  if(scanState.completed)lines.push("目錄索引已完成。重新進入時會直接讀取 D1 書架；封面佇列完成後不會重複遍歷目錄。");
  else if(finished&&state.scanPauseRequested)lines.push("已要求暫停，進度已保存；下次開啟後按「掃描／續掃」即可手動繼續。");
  else if(finished)lines.push("本批結束，進度已保存到 D1；可關閉頁面，之後再續掃。");
  else lines.push("掃描進行中；目錄索引與續作游標會持續保存至 D1。");
  const lastError=scanState.errors?.[scanState.errors.length-1];
  if(lastError)lines.push("最近錯誤："+String(lastError.path||"")+"｜"+String(lastError.message||""));
  return lines.join("\n");
}

async function fetchScanDirectory(path, page, perPage) {
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

class HttpRangeReader {
  constructor(size,readRange,onEvent=()=>{}) {
    this.size=Number(size)||0;
    this.readRange=readRange;
    this.onEvent=onEvent;
    this.initialized=false;
    this.rangeCount=0;
    this.bytesRead=0;
  }
  async init() { this.initialized=true; }
  get readable() {
    const reader=this;
    let stream;
    let chunkOffset=0;
    stream=new ReadableStream({
      async pull(controller) {
        try {
          const offset=Math.max(0,Number(stream.offset)||0);
          const size=Number(stream.size);
          if(!Number.isSafeInteger(size)||size<0) {
            throw new Error("ZIP 封面串流缺少有效的壓縮資料長度。");
          }
          const remaining=size-chunkOffset;
          if(remaining<=0) {
            reader.onEvent("ZIP 解壓串流結束：已讀取 "+chunkOffset+"/"+size+" bytes。");
            controller.close();
            return;
          }
          const length=Math.min(65536,remaining);
          const absoluteOffset=offset+chunkOffset;
          reader.onEvent("ZIP 解壓串流讀取：offset="+absoluteOffset+"；本段 "+length+" bytes；進度 "+chunkOffset+"/"+size+"。");
          const bytes=await reader.readUint8Array(absoluteOffset,length,Number(stream.diskNumberStart)||0);
          if(!(bytes instanceof Uint8Array)||!bytes.byteLength) {
            throw new Error("ZIP 封面資料 Range 回傳空資料，讀取中止。");
          }
          if(bytes.byteLength>length)throw new Error("ZIP 封面資料 Range 回傳長度超出要求。");
          controller.enqueue(bytes);
          chunkOffset+=bytes.byteLength;
          if(chunkOffset>=size) {
            reader.onEvent("ZIP 解壓串流結束：已讀取 "+chunkOffset+"/"+size+" bytes。");
            controller.close();
          }
        } catch(error) {
          reader.onEvent("ZIP 解壓串流失敗："+String(error?.message||error),"error");
          controller.error(error);
        }
      }
    });
    return stream;
  }
  async readUint8Array(offset,length) {
    const start=Math.max(0,Number(offset)||0);
    const count=Math.max(0,Number(length)||0);
    if(!count||start>=this.size)return new Uint8Array();
    const end=Math.min(this.size,start+count)-1;
    const number=++this.rangeCount;
    const started=performance.now();
    const maxAttempts=3;
    this.onEvent("封面 Range #"+number+" 開始；bytes="+start+"-"+end);
    for(let attempt=1;attempt<=maxAttempts;attempt++) {
      try {
        const bytes=await this.readRange(start,end);
        if(!(bytes instanceof Uint8Array)||bytes.byteLength!==end-start+1) {
          throw new Error("HTTP Range 回傳長度不完整；預期 "+(end-start+1)+" bytes，實際 "+Number(bytes?.byteLength||0)+" bytes。");
        }
        this.bytesRead+=bytes.byteLength;
        this.onEvent("封面 Range #"+number+" 完成；取得 "+bytes.byteLength+" bytes；累計 "+this.bytesRead+" bytes；耗時 "+Math.round(performance.now()-started)+" ms","success");
        return bytes;
      } catch(error) {
        const message=String(error?.message||error);
        const retryable=/HTTP (?:429|500|502|503|504)\b|failed to fetch|networkerror|network request failed/i.test(message);
        if(retryable&&attempt<maxAttempts) {
          const delay=400*attempt;
          this.onEvent("封面 Range #"+number+" 暫時性錯誤（第 "+attempt+"/"+maxAttempts+" 次）："+message+"；"+delay+" ms 後重試。","warning");
          await new Promise(resolve=>setTimeout(resolve,delay));
          continue;
        }
        this.onEvent("封面 Range #"+number+" 失敗："+message+"；嘗試 "+attempt+"/"+maxAttempts+" 次；耗時 "+Math.round(performance.now()-started)+" ms","error");
        throw error;
      }
    }
    throw new Error("封面 Range 讀取重試次數已用盡。");
  }
}
async function makeCoverRangeReader(item,onEvent=()=>{}) {
  const size=Number(item.size)||0;
  if(!Number.isSafeInteger(size)||size<=0)throw new Error("檔案大小無效，無法使用 HTTP Range 讀取封面。");
  const query=new URLSearchParams({
    provider:state.activeProvider,
    library:state.activeLibrary,
    root_path:getActiveRoot(),
    path:item.path
  });
  const url="/api/cloud/file?"+query.toString();
  return new HttpRangeReader(size,async(start,end)=>{
    const response=await fetch(url,{
      method:"GET",credentials:"same-origin",
      headers:{Range:"bytes="+start+"-"+end}
    });
    return readRangeResponse(response,start,end,size);
  },onEvent);
}
async function readRangeResponse(response,start,end,totalSize) {
  if(response.status===206) {
    const bytes=new Uint8Array(await response.arrayBuffer());
    if(!bytes.length||bytes.length>end-start+1)throw new Error("HTTP Range 回傳長度不正確。");
    const contentRange=response.headers.get("Content-Range");
    if(contentRange) {
      const match=contentRange.match(/^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/i);
      if(match&&(Number(match[1])!==start||Number(match[2])<end||match[3]!=="*"&&Number(match[3])!==totalSize)) {
        throw new Error("HTTP Range Content-Range 與請求不一致。");
      }
    }
    return bytes;
  }
  if(response.status===200&&totalSize<=6*1024*1024) {
    const bytes=new Uint8Array(await response.arrayBuffer());
    if(bytes.length!==totalSize)throw new Error("來源伺服器沒有正確回應 Range，完整檔案大小不符。");
    return bytes.slice(start,Math.min(end+1,bytes.length));
  }
  try { await response.body?.cancel(); } catch (_) {}
  if(!response.ok)throw new Error("讀取封面資料失敗：HTTP "+response.status);
  throw new Error("來源未支援 HTTP Range，為避免下載整本書，已停止封面擷取。");
}
async function findEpubCover(zipEntries,onEvent=()=>{}) {
  const byName=new Map(zipEntries.filter(entry=>!entry.directory).map(entry=>[zipPath(entry.filename),entry]));
  const container=byName.get("META-INF/container.xml");
  if(!container) {
    onEvent("EPUB 封面解析：ZIP 中沒有 META-INF/container.xml。","warning");
    return null;
  }
  const containerStarted=performance.now();
  onEvent("EPUB 封面解析：container.xml 解壓開始；壓縮 "+Number(container.compressedSize||0)+" bytes，原始 "+Number(container.uncompressedSize||0)+" bytes。");
  const containerText=await container.getData(new TextWriter("utf-8"));
  onEvent("EPUB 封面解析：container.xml 解壓完成；文字 "+String(containerText||"").length+" 字元；耗時 "+Math.round(performance.now()-containerStarted)+" ms。","success");
  const containerXml=new DOMParser().parseFromString(String(containerText),"application/xml");
  const rootfile=containerXml.getElementsByTagName("rootfile")[0];
  const opfPath=zipPath(rootfile?.getAttribute("full-path")||"");
  if(!opfPath) {
    onEvent("EPUB 封面解析：container.xml 沒有有效 rootfile 路徑。","warning");
    return null;
  }
  onEvent("EPUB 封面解析：找到 OPF 路徑 "+opfPath+"。");
  const opfEntry=byName.get(opfPath);
  if(!opfEntry) {
    onEvent("EPUB 封面解析：ZIP 中找不到 OPF 項目 "+opfPath+"。","warning");
    return null;
  }
  const opfStarted=performance.now();
  onEvent("EPUB 封面解析：OPF 解壓開始；壓縮 "+Number(opfEntry.compressedSize||0)+" bytes，原始 "+Number(opfEntry.uncompressedSize||0)+" bytes。");
  const opfText=await opfEntry.getData(new TextWriter("utf-8"));
  onEvent("EPUB 封面解析：OPF 解壓完成；文字 "+String(opfText||"").length+" 字元；耗時 "+Math.round(performance.now()-opfStarted)+" ms。","success");
  const opfXml=new DOMParser().parseFromString(String(opfText),"application/xml");
  if(opfXml.getElementsByTagName("parsererror").length) {
    onEvent("EPUB 封面解析：OPF XML 格式錯誤。","warning");
    return null;
  }
  const manifest=Array.from(opfXml.getElementsByTagName("item"));
  const metaItems=Array.from(opfXml.getElementsByTagName("meta"));
  let coverId="";
  for(const meta of metaItems) {
    const name=String(meta.getAttribute("name")||"").toLowerCase();
    const property=String(meta.getAttribute("property")||"").toLowerCase();
    if(name==="cover"||property==="cover-image") {
      coverId=String(meta.getAttribute("content")||"").trim();
      if(coverId)break;
    }
  }
  let coverItem=coverId?manifest.find(item=>item.getAttribute("id")===coverId):null;
  if(!coverItem)coverItem=manifest.find(item=>(item.getAttribute("properties")||"").split(/\s+/).includes("cover-image"));
  if(!coverItem)coverItem=manifest.find(item=>/^image\//i.test(item.getAttribute("media-type")||"")&&/cover|front/i.test(item.getAttribute("href")||""));
  if(!coverItem)return null;
  const base=opfPath.includes("/")?opfPath.slice(0,opfPath.lastIndexOf("/")):"";
  const coverPath=archiveRelativePath(base,coverItem.getAttribute("href"));
  const entry=byName.get(coverPath);
  if(!entry)return null;
  const mime=String(coverItem.getAttribute("media-type")||mimeFromCoverName(coverPath)||"").toLowerCase();
  if(!mime.startsWith("image/")||mime==="image/svg+xml")return null;
  return {entry,mime};
}
async function findCbzCover(zipEntries) {
  const candidates=zipEntries.filter(entry=>!entry.directory&&
    /\.(jpe?g|png|webp|gif|bmp|avif)$/i.test(entry.filename)&&
    !/(^|\/)(__MACOSX|\.AppleDouble)\//i.test(entry.filename)&&
    !/(^|\/)\._/.test(entry.filename));
  if(!candidates.length)return null;
  candidates.sort((a,b)=>a.filename.localeCompare(b.filename,undefined,{numeric:true,sensitivity:"base"}));
  const selected=candidates.find(entry=>/(^|[/_-])(cover|front)([/_.-]|$)/i.test(entry.filename))||candidates[0];
  return {entry:selected,mime:mimeFromCoverName(selected.filename)||"image/jpeg"};
}
async function resizeCover(blob) {
  if(!(blob instanceof Blob)||!blob.size||blob.size>15*1024*1024)throw new Error("原始封面不存在或超過 15 MiB。");
  let bitmap;
  try {
    if(typeof createImageBitmap==="function")bitmap=await createImageBitmap(blob);
    else {
      const url=URL.createObjectURL(blob);
      try {
        const image=new Image();
        image.src=url;
        await image.decode();
        const canvas=document.createElement("canvas");
        const scale=Math.min(1,512/Math.max(image.naturalWidth,image.naturalHeight));
        canvas.width=Math.max(1,Math.round(image.naturalWidth*scale));
        canvas.height=Math.max(1,Math.round(image.naturalHeight*scale));
        canvas.getContext("2d",{alpha:false}).drawImage(image,0,0,canvas.width,canvas.height);
        let output=await new Promise(resolve=>canvas.toBlob(resolve,"image/webp",0.84));
        let mime="image/webp";
        if(!output){output=await new Promise(resolve=>canvas.toBlob(resolve,"image/jpeg",0.86));mime="image/jpeg";}
        if(output)return {blob:output,mime};
      } finally { URL.revokeObjectURL(url); }
      throw new Error("封面圖片無法轉換。");
    }
  } catch(error) { throw new Error("封面圖片解碼失敗："+(error.message||error)); }
  try {
    const width=bitmap.width||bitmap.displayWidth;
    const height=bitmap.height||bitmap.displayHeight;
    if(!width||!height||width*height>150000000)throw new Error("封面圖片尺寸異常。");
    const scale=Math.min(1,512/Math.max(width,height));
    const canvas=document.createElement("canvas");
    canvas.width=Math.max(1,Math.round(width*scale));
    canvas.height=Math.max(1,Math.round(height*scale));
    const context=canvas.getContext("2d",{alpha:false});
    if(!context)throw new Error("無法建立封面縮圖畫布。");
    context.drawImage(bitmap,0,0,canvas.width,canvas.height);
    let output=await new Promise(resolve=>canvas.toBlob(resolve,"image/webp",0.84));
    let mime="image/webp";
    if(!output) {
      output=await new Promise(resolve=>canvas.toBlob(resolve,"image/jpeg",0.86));
      mime="image/jpeg";
    }
    if(!output||!output.size)throw new Error("瀏覽器無法產生封面縮圖。");
    if(output.size>2*1024*1024)throw new Error("封面縮圖仍超過 2 MiB。");
    return {blob:output,mime};
  } finally {
    try { bitmap.close(); } catch (_) {}
  }
}
async function extractCloudCover(item,onEvent=()=>{}) {
  const started=performance.now();
  const rangeReader=await makeCoverRangeReader(item,onEvent);
  // zip.js defaults to Web Workers and resolves its worker URI relative to
  // vendor/zip.js. This project vendors zip.js but does not ship
  // vendor/core/web-worker-wasm.js or its WASM assets. A Worker can therefore
  // fail to load while zip.js waits forever for a worker response.
  // Run extraction on the main thread using the browser's native
  // DecompressionStream instead.
  onEvent("ZIP 解壓模式：停用未隨專案部署的 Web Worker，使用瀏覽器內建解壓串流。");
  const zip=new ZipReader(rangeReader,{useWebWorkers:false,useCompressionStream:true});
  const entries=await zip.getEntries();
  onEvent("ZIP 中央目錄解析完成："+entries.length+" 個項目；耗時 "+Math.round(performance.now()-started)+" ms");
  const found=item.format==="CBZ"?await findCbzCover(entries):await findEpubCover(entries,onEvent);
  if(!found) {
    onEvent("封面解析完成：沒有找到可用圖片；Range "+rangeReader.rangeCount+" 次／"+formatBytes(rangeReader.bytesRead),"warning");
    return null;
  }
  onEvent("封面圖片讀取開始："+found.entry.filename+"；壓縮 "+Number(found.entry.compressedSize||0)+" bytes，原始 "+Number(found.entry.uncompressedSize||0)+" bytes。");
  const imageStarted=performance.now();
  const sourceBlob=await found.entry.getData(new BlobWriter(found.mime));
  onEvent("封面圖片資料解壓完成："+sourceBlob.size+" bytes；耗時 "+Math.round(performance.now()-imageStarted)+" ms。","success");
  const cover=await resizeCover(sourceBlob);
  onEvent("封面解析與縮圖完成："+cover.blob.size+" bytes；Range "+rangeReader.rangeCount+
    " 次／"+formatBytes(rangeReader.bytesRead)+"；總耗時 "+Math.round(performance.now()-started)+" ms","success");
  return cover;
}
async function blobSha256(blob) {
  const digest=await crypto.subtle.digest("SHA-256",await blob.arrayBuffer());
  return Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,"0")).join("");
}
async function saveCoverState(scope,item,status,details={}) {
  const response=await fetch("/api/cloud/covers",{
    method:"POST",credentials:"same-origin",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({
      provider:scope.provider,library:scope.library,rootPath:scope.rootPath,
      path:item.path,status,error:details.error||null
    })
  });
  return readJsonResponse(response,"保存封面索引狀態失敗。");
}
async function uploadCover(scope,item,hash,cover) {
  const query=new URLSearchParams({
    provider:scope.provider,library:scope.library,root_path:scope.rootPath,path:item.path
  });
  const response=await fetch("/api/cloud/covers?"+query.toString(),{
    method:"POST",credentials:"same-origin",
    headers:{"Content-Type":cover.mime,"X-Cover-Hash":hash},
    body:cover.blob
  });
  return readJsonResponse(response,"上傳封面至 R2 失敗。");
}
async function fetchPendingCovers(scope,limit=12) {
  const query=new URLSearchParams({
    provider:scope.provider,library:scope.library,root_path:scope.rootPath,limit:String(limit)
  });
  const response=await fetch("/api/cloud/covers?"+query.toString(),{credentials:"same-origin"});
  return readJsonResponse(response,"讀取封面索引佇列失敗。");
}
async function retryFailedCovers(scope) {
  const response=await fetch("/api/cloud/covers",{
    method:"POST",credentials:"same-origin",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({action:"retry-errors",provider:scope.provider,library:scope.library,rootPath:scope.rootPath})
  });
  const data=await readJsonResponse(response,"重設失敗封面佇列失敗。");
  return Number(data.retried||0);
}
async function processPendingCovers(scope,maxDurationMs=120000,scanState=null) {
  const started=Date.now();
  let processed=0,failed=0,missing=0;
  appendIndexLog("封面索引開始：使用 HTTP Range 讀取 ZIP 封面資料，不下載整本書。");
  appendIndexLog("封面分類："+LIBRARY_LABELS[scope.library]+"；根目錄："+scope.rootPath);
  while(Date.now()-started<maxDurationMs&&!state.scanPauseRequested) {
    const queue=await fetchPendingCovers(scope,8);
    if(!queue.items.length)break;
    for(const item of queue.items) {
      if(Date.now()-started>=maxDurationMs||state.scanPauseRequested)break;
      setIndexProgress("正在建立封面索引："+item.path+"（已處理 "+processed+" 本）");
      appendIndexLog("正在處理封面："+item.path);
      const coverStartedAt=performance.now();
      try {
        const cover=await extractCloudCover(item,message=>appendIndexLog(message));
        if(!cover) {
          await saveCoverState(scope,item,"missing");
          missing++;
          if(scanState)scanState.coverMissingCount=Number(scanState.coverMissingCount||0)+1;
          appendIndexLog("沒有找到可用封面："+item.path+"；耗時 "+Math.round(performance.now()-coverStartedAt)+" ms","warning");
        } else {
          appendIndexLog("封面 SHA-256 計算開始："+item.name);
          const hashStarted=performance.now();
          const hash=await blobSha256(cover.blob);
          appendIndexLog("封面 SHA-256 完成："+hash.slice(0,12)+"；耗時 "+Math.round(performance.now()-hashStarted)+" ms");
          appendIndexLog("R2 封面上傳開始："+formatBytes(cover.blob.size));
          const r2Started=performance.now();
          await uploadCover(scope,item,hash,cover);
          appendIndexLog("R2 封面上傳完成："+formatBytes(cover.blob.size)+"；含 D1 封面狀態更新耗時 "+Math.round(performance.now()-r2Started)+" ms","success");
          if(scanState)scanState.coverReadyCount=Number(scanState.coverReadyCount||0)+1;
          appendIndexLog("封面已保存至私有 R2："+item.name+" · "+hash.slice(0,12)+"；耗時 "+Math.round(performance.now()-coverStartedAt)+" ms","success");
        }
      } catch(error) {
        failed++;
        if(scanState)scanState.coverFailedCount=Number(scanState.coverFailedCount||0)+1;
        try { await saveCoverState(scope,item,"error",{error:String(error.message||error).slice(0,450)}); }
        catch(stateError) { appendIndexLog("封面狀態保存失敗："+(stateError.message||stateError),"error"); }
        appendIndexLog("封面處理失敗："+item.path+" · "+(error.message||error),"error");
      }
      processed++;
      if(scanState)scanState.coverProcessedCount=Number(scanState.coverProcessedCount||0)+1;
    }
  }
  const remaining=await fetchPendingCovers(scope,1);
  if(scanState) {
    scanState.coverPendingCount=Number(remaining.total||0);
    if(state.scanPauseRequested) {
      scanState.pausedByUser=state.scanPauseReason==="manual";
      scanState.resumeOnNextOpen=state.scanPauseReason!=="manual";
    }
    await saveIndexScanState(scanState,scope);
  }
  appendIndexLog("封面索引本批完成：處理 "+processed+" 本，無封面 "+missing+" 本，失敗 "+failed+" 本，待處理 "+remaining.total+" 本。");
  return {processed,failed,missing,remaining:Number(remaining.total||0)};
}

async function runIndexScan(targetLibrary=state.activeLibrary,fromAll=false,options={}) {
  if(state.scanRunning||(!fromAll&&state.scanAllRunning))return {ok:false,reason:"already_running"};
  if(!["books","comics"].includes(targetLibrary))return {ok:false,reason:"invalid_library"};
  state.activeLibrary=targetLibrary;
  $("cloud-library-type").value=targetLibrary;
  await saveRemotePreference("activeLibrary", targetLibrary);
  state.currentPath=getActiveRoot(targetLibrary);
  if(!state.authenticated) {
    setIndexProgress("尚未通過 Cloudflare Access，無法開始索引。",true);
    return {ok:false,reason:"not_authenticated"};
  }
  if(!isActiveSourceReady()) {
    setIndexProgress("請先完成目前 OpenList 來源的網址、帳號與密碼設定。",true);
    return {ok:false,reason:"source_not_ready"};
  }
  try { await saveRootSelections(); }
  catch(error) {
    setIndexProgress(error.message||"書庫根目錄設定無效。",true);
    return {ok:false,reason:"invalid_root"};
  }

  const scope=indexScope();
  const scanButtons=["cloud-scan-books","cloud-scan-comics","cloud-scan-all","cloud-retry-covers"];
  const pauseButton=$("cloud-scan-pause");
  let scanState=null;
  let outcome={ok:false};
  const batch={entries:0,indexed:0,skipped:0,failed:0,folders:0,currentPath:"",coverProcessed:0,coverMissing:0,coverFailed:0};

  state.scanRunning=true;
  scanButtons.forEach(id=>{const button=$(id);if(button)button.disabled=true;});
  ["cloud-provider","cloud-library-type","cloud-books-root","cloud-comics-root","cloud-save-roots","cloud-save-source","cloud-test-source"].forEach(id=>{const control=$(id);if(control)control.disabled=true;});
  if(pauseButton)pauseButton.disabled=false;
  const startedAt=Date.now();

  try {
    appendIndexLog("========== "+LIBRARY_LABELS[targetLibrary]+"掃描開始 ==========");
    appendIndexLog("掃描根目錄："+scope.rootPath);
    appendIndexLog("掃描來源："+PROVIDER_LABELS[scope.provider]);
    appendIndexLog("掃描模式：完整遞迴掃描（不跳過已存在的目錄項目；D1 執行新增／更新）");
    appendIndexLog("檔案範圍："+(targetLibrary==="books"?"EPUB":"EPUB／CBZ")+"；原始書檔不會下載或修改。");
    appendIndexLog("讀取 D1 掃描進度開始。");
    scanState=await loadIndexScanState(scope);
    appendIndexLog("D1 掃描進度讀取完成："+(scanState?"找到既有進度":"尚無進度"),scanState?"success":"info");

    if(options.forceRescan===true) {
      scanState=newIndexScanState(scope.rootPath,scope.provider,scope.library);
      scanState.scanMode="完整重掃";
      scanState.pausedByUser=false;
      scanState.resumeOnNextOpen=false;
      await saveIndexScanState(scanState,scope);
      appendIndexLog("已啟用完整重掃：從根目錄重新建立游標，完成後清理不存在的索引。","warning");
    } else if(scanState&&scanState.rootPath===scope.rootPath&&scanState.provider===scope.provider&&
       scanState.library===scope.library&&scanState.version===1&&scanState.completed) {
      const existingQueue=await fetchPendingCovers(scope,1);
      if(existingQueue.total) {
        appendIndexLog("目錄索引已完成；本次只續做尚未完成的封面，不重新遍歷 OpenList。","warning");
        scanState.pausedByUser=false;
        scanState.resumeOnNextOpen=false;
        await saveIndexScanState(scanState,scope);
        const coverResult=await processPendingCovers(scope,180000,scanState);
        batch.coverProcessed=coverResult.processed;
        batch.coverMissing=coverResult.missing;
        batch.coverFailed=coverResult.failed;
        batch.coverRemaining=coverResult.remaining;
        setIndexProgress(indexScanProgressText(scanState,batch,true),!!coverResult.failed);
        outcome={ok:true,completed:coverResult.remaining===0,paused:!!state.scanPauseRequested,coverOnly:true,coverRemaining:coverResult.remaining};
        return outcome;
      }
      if(!window.confirm("這個來源與分類的目錄索引已完成，目前沒有待處理封面。重新掃描會再次遍歷整個根目錄，更新新增、變更項目，並在完整結束後清理已不存在的索引。確定開始新一輪嗎？"))
        return {ok:false,cancelled:true};
      scanState=newIndexScanState(scope.rootPath,scope.provider,scope.library);
      scanState.scanMode="完整重掃";
      await saveIndexScanState(scanState,scope);
      appendIndexLog("建立新一輪完整掃描與 D1 進度記錄。","success");
    } else if(scanState&&scanState.rootPath===scope.rootPath&&scanState.provider===scope.provider&&
      scanState.library===scope.library&&scanState.version===1&&!scanState.completed) {
      appendIndexLog("找到未完成的掃描進度，將從上次保存的位置續掃。","warning");
      scanState.skippedCount=Number(scanState.skippedCount||0);
      scanState.failedCount=Number(scanState.failedCount||0);
      scanState.coverReadyCount=Number(scanState.coverReadyCount||0);
      scanState.coverMissingCount=Number(scanState.coverMissingCount||0);
      scanState.coverFailedCount=Number(scanState.coverFailedCount||0);
      scanState.pausedByUser=false;
      scanState.resumeOnNextOpen=false;
      await saveIndexScanState(scanState,scope);
    } else {
      if(scope.rootPath==="/"&&!window.confirm(
        "目前"+LIBRARY_LABELS[targetLibrary]+"根目錄是「/」，代表會遞迴掃描整個 OpenList 根目錄。\\n\\n建議先填入專門的書籍／漫畫資料夾，以免掃描其他雲端檔案。仍要繼續嗎？"
      ))return {ok:false,cancelled:true};
      scanState=newIndexScanState(scope.rootPath,scope.provider,scope.library);
      scanState.scanMode="首次完整掃描";
      await saveIndexScanState(scanState,scope);
      appendIndexLog("建立首次掃描工作與 D1 進度記錄。","success");
    }

    const maxEntriesPerBatch=500,maxFoldersPerBatch=500,maxDurationMs=7500000,pageSize=100;
    const seen=new Set(Array.isArray(scanState.seenFolders)?scanState.seenFolders:[scope.rootPath]);

    while(!scanState.completed&&batch.entries<maxEntriesPerBatch&&batch.folders<maxFoldersPerBatch&&
      Date.now()-startedAt<maxDurationMs&&!state.scanPauseRequested) {
      if(!scanState.currentFolder) {
        if(!scanState.pendingFolders.length)break;
        scanState.currentFolder=scanState.pendingFolders.shift();
        scanState.page=1;
        await saveIndexScanState(scanState,scope);
        appendIndexLog("進入資料夾："+scanState.currentFolder);
      }

      const currentFolder=scanState.currentFolder;
      const page=Math.max(1,Number(scanState.page)||1);
      batch.currentPath=currentFolder;
      setIndexProgress(indexScanProgressText(scanState,batch),false);
      appendIndexLog("讀取目錄列表："+currentFolder+"；第 "+page+" 頁。");
      const listStarted=performance.now();
      const listing=await fetchScanDirectory(currentFolder,page,pageSize);
      const listElapsed=Math.round(performance.now()-listStarted);
      const found=Array.isArray(listing.items)?listing.items:[];
      appendIndexLog("目錄列表完成："+currentFolder+"；第 "+page+" 頁；本頁 "+found.length+"/"+Number(listing.total||found.length)+" 項；耗時 "+listElapsed+" ms","success");

      const entries=[];
      let folderCount=0,epubCount=0,cbzCount=0;
      for(const item of found) {
        const path=normalizePath(item.path||joinPath(currentFolder,item.name));
        const name=String(item.name||"");
        if(!path||!name)continue;
        const isDir=!!item.isDir;
        const format=isDir?"":fileKind(item);
        const allowed=isDir||(scope.library==="comics"?(format==="EPUB"||format==="CBZ"):format==="EPUB");
        if(!allowed||!isWithinRoot(path,scope.rootPath))continue;
        entries.push({path,parentPath:currentFolder,name,isDir,format,size:Math.max(0,Number(item.size)||0),modified:item.modified||null});
        if(isDir) {
          folderCount++;
          if(!seen.has(path)) {
            seen.add(path);
            scanState.seenFolders.push(path);
            scanState.pendingFolders.push(path);
          }
        } else if(format==="EPUB")epubCount++;
        else if(format==="CBZ")cbzCount++;
      }

      const skipped=Math.max(0,found.length-entries.length);
      batch.skipped+=skipped;
      batch.entries+=found.length;
      appendIndexLog("本頁項目：資料夾 "+folderCount+" 個；EPUB "+epubCount+" 個；CBZ "+cbzCount+" 個；格式不符／範圍外略過 "+skipped+" 個。");
      appendIndexLog("D1 索引寫入開始："+entries.length+" 筆。");
      const writeStarted=performance.now();
      batch.currentWriteCount=entries.length;
      const saved=entries.length?await writeIndexEntries(scanState,entries):0;
      const writeElapsed=Math.round(performance.now()-writeStarted);
      batch.currentWriteCount=0;
      scanState.scannedCount=Number(scanState.scannedCount||0)+found.length;
      scanState.indexedCount=Number(scanState.indexedCount||0)+saved;
      scanState.skippedCount=Number(scanState.skippedCount||0)+skipped;
      batch.indexed+=saved;
      batch.currentPath="";
      const lastBook=[...entries].reverse().find(item=>!item.isDir);
      batch.lastCompleted=lastBook
        ?lastBook.name+"｜"+lastBook.format+"｜D1 已寫入／更新｜本頁 "+saved+" 筆｜"+writeElapsed+" ms"
        :currentFolder+"｜本頁 "+saved+" 筆｜"+writeElapsed+" ms";
      if(lastBook) {
        scanState.lastCompletedName=lastBook.name;
        scanState.lastCompletedPath=lastBook.path;
        scanState.lastCompletedAt=new Date().toISOString();
      }
      appendIndexLog("D1 索引寫入完成："+saved+" 筆；耗時 "+writeElapsed+" ms。","success");
      if(lastBook)appendIndexLog("最近完成："+lastBook.name+"｜"+lastBook.path+"｜已寫入／更新 D1；本頁 D1 "+writeElapsed+" ms。","success");

      const total=Math.max(0,Number(listing.total)||found.length);
      if(page*pageSize<total)scanState.page=page+1;
      else {
        scanState.currentFolder=null;
        scanState.page=1;
        scanState.visitedFolderCount=Number(scanState.visitedFolderCount||0)+1;
        batch.folders+=1;
      }
      await saveIndexScanState(scanState,scope);
      appendIndexLog("D1 掃描進度保存完成：已完成資料夾 "+scanState.visitedFolderCount+" 個；待掃描 "+scanState.pendingFolders.length+" 個。","success");
      renderLibraryScanSummary(scope.library,scanState,scope.rootPath);
      setIndexProgress(indexScanProgressText(scanState,batch),false);
    }

    if(!scanState.currentFolder&&scanState.pendingFolders.length===0) {
      appendIndexLog("所有資料夾已掃描，開始清理本根目錄中已不存在的索引項目。");
      const response=await fetch("/api/cloud/index/complete",{
        method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},
        body:JSON.stringify({provider:scope.provider,library:scope.library,rootPath:scope.rootPath,scanId:scanState.scanId})
      });
      const completed=await readJsonResponse(response,"清理過期索引失敗。");
      scanState.completed=true;
      scanState.completedAt=new Date().toISOString();
      scanState.removedCount=Number(completed.removed||0);
      await saveIndexScanState(scanState,scope);
      appendIndexLog("索引完成；清理已不存在項目 "+scanState.removedCount+" 筆。","success");
    }

    if(scanState.completed) {
      setIndexProgress(indexScanProgressText(scanState,batch,true),false);
      appendIndexLog("========== "+LIBRARY_LABELS[targetLibrary]+"完整索引完成 ==========","success");
    } else {
      const reason=state.scanPauseRequested?(state.scanPauseReason==="manual"?"使用者手動暫停":"使用者關閉設定視窗，保存游標"):
        batch.entries>=maxEntriesPerBatch?"達到每批 500 個目錄項目上限":
        batch.folders>=maxFoldersPerBatch?"達到每批 500 個資料夾上限":"達到單批 4 分鐘安全時限";
      batch.stopReason=reason;
      scanState.pausedByUser=!!state.scanPauseRequested;
      scanState.resumeOnNextOpen=false;
      await saveIndexScanState(scanState,scope);
      setIndexProgress(indexScanProgressText(scanState,batch,true),false);
      appendIndexLog("本批結束："+reason+"；進度已保存，可再次點擊續掃。","warning");
    }

    if(!state.scanPauseRequested) {
      const coverQueue=await fetchPendingCovers(scope,1);
      batch.coverRemaining=Number(coverQueue.total||0);
      const coverBudget=Math.min(150000,Math.max(0,7500000-(Date.now()-startedAt)));
      if(batch.coverRemaining>0&&coverBudget>10000) {
        const coverResult=await processPendingCovers(scope,coverBudget,scanState);
        batch.coverProcessed=coverResult.processed;
        batch.coverMissing=coverResult.missing;
        batch.coverFailed=coverResult.failed;
        batch.coverRemaining=coverResult.remaining;
        if(coverResult.remaining)setIndexProgress(indexScanProgressText(scanState,batch,true)+"\n尚有 "+coverResult.remaining+" 本封面待處理，會自動續做。",false);
      }
    }
    outcome={ok:true,completed:!!scanState.completed&&Number(batch.coverRemaining||0)===0,paused:!!state.scanPauseRequested,coverRemaining:Number(batch.coverRemaining||0)};
    return outcome;
  } catch(error) {
    const message=String(error.message||error).slice(0,700);
    appendIndexLog("索引發生錯誤："+message,"error");
    if(scanState) {
      scanState.failedCount=Number(scanState.failedCount||0)+Math.max(1,Number(batch.currentWriteCount||0));
      scanState.lastError=message;
      scanState.errors=Array.isArray(scanState.errors)?scanState.errors:[];
      scanState.errors.push({path:batch.currentPath||scanState.currentFolder||scope.rootPath,message,at:new Date().toISOString()});
      if(scanState.errors.length>20)scanState.errors=scanState.errors.slice(-20);
      try { await saveIndexScanState(scanState,scope); }
      catch(saveError) { appendIndexLog("錯誤後保存 D1 進度失敗："+(saveError.message||saveError),"error"); }
    }
    setIndexProgress((error.message||"索引失敗。")+"\n目前游標已盡可能保存；修復問題後可再次點擊續掃。",true);
    outcome={ok:false,error:message};
    return outcome;
  } finally {
    state.scanRunning=false;
    state.scanPauseRequested=false;
    if(pauseButton)pauseButton.disabled=true;
    if(!state.scanAllRunning)scanButtons.forEach(id=>{const button=$(id);if(button)button.disabled=false;});
    if(!state.scanAllRunning)["cloud-provider","cloud-library-type","cloud-books-root","cloud-comics-root","cloud-save-roots","cloud-save-source","cloud-test-source"].forEach(id=>{
      const control=$(id);
      if(control)control.disabled=false;
    });
    try {
      const latest=await loadIndexScanState(scope);
      renderLibraryScanSummary(scope.library,latest,scope.rootPath);
      if(state.activeLibrary===scope.library)renderIndexStatus(latest);
    } catch(_) {}
    try {
      state.currentPath=scope.rootPath;
      if(isActiveSourceReady()) {
        await loadDirectory(scope.rootPath,1);
        if(outcome.ok&&outcome.completed)setSourceStatus(LIBRARY_LABELS[scope.library]+"索引已完成，已自動載入雲端書架："+scope.rootPath);
        else if(outcome.ok)setSourceStatus(LIBRARY_LABELS[scope.library]+"本批索引已保存；再次掃描可接續："+scope.rootPath);
      }
    } catch(refreshError) {
      appendIndexLog("掃描後自動載入書架失敗："+(refreshError.message||refreshError),"error");
    }
  }
}
async function runLibraryScan(library,options={}) {
  if(state.scanAllRunning||state.scanRunning)return;
  const continueFullRescan=options.forceRescan===true;
  state.scanAllRunning=true;
  state.scanPauseRequested=false;
  state.scanPauseReason="";
  ["cloud-scan-books","cloud-scan-comics","cloud-scan-all","cloud-retry-covers","cloud-scan-books-full","cloud-scan-comics-full"].forEach(id=>{const button=$(id);if(button)button.disabled=true;});
  appendIndexLog("========== 開始"+(continueFullRescan?"完整重掃":"掃描／續掃")+"："+LIBRARY_LABELS[library]+" ==========");
  let result={ok:false};
  let firstPass=true;
  try {
    do {
      result=await runIndexScan(library,true,{forceRescan:firstPass&&continueFullRescan});
      firstPass=false;
      if(!result?.ok||result.paused||result.cancelled||!continueFullRescan)break;
      if(!result.completed)appendIndexLog("完整重掃本批已保存；自動從 D1 游標接續下一批。","warning");
    } while(!result.completed);
    if(result?.ok&&!result.completed&&!result.paused&&!result.cancelled&&!continueFullRescan) {
      appendIndexLog("本批已結束，D1 游標已保存。再次按「掃描／續掃」即可繼續；開啟網站或管理視窗時不會自動索引。","info");
    }
    return result;
  } finally {
    state.scanAllRunning=false;
    ["cloud-scan-books","cloud-scan-comics","cloud-scan-all","cloud-retry-covers","cloud-scan-books-full","cloud-scan-comics-full"].forEach(id=>{const button=$(id);if(button)button.disabled=false;});
    ["cloud-provider","cloud-library-type","cloud-books-root","cloud-comics-root","cloud-save-roots","cloud-save-source","cloud-test-source"].forEach(id=>{const control=$(id);if(control)control.disabled=false;});
  }
}
async function runAllIndexScans() {
  if(state.scanAllRunning||state.scanRunning)return;
  state.scanAllRunning=true;
  state.scanPauseRequested=false;
  state.scanPauseReason="";
  ["cloud-scan-books","cloud-scan-comics","cloud-scan-all","cloud-retry-covers"].forEach(id=>{const button=$(id);if(button)button.disabled=true;});
  appendIndexLog("========== 依序連續掃描電子書與漫畫 ==========");
  let stopped=false;
  try {
    for(const library of ["books","comics"]) {
      if(stopped)break;
      appendIndexLog("開始："+LIBRARY_LABELS[library]+"；根目錄："+(state.selectedRoots[library]||"/"));
      let result={ok:false};
      do {
        result=await runIndexScan(library,true);
        if(!result?.ok||result.paused||result.cancelled) {
          stopped=true;
          break;
        }
        if(!result.completed)appendIndexLog(LIBRARY_LABELS[library]+"本批已保存；自動續作下一批。","warning");
      } while(!result.completed);
      if(!stopped)appendIndexLog(LIBRARY_LABELS[library]+"索引與封面佇列已完成。","success");
    }
    if(!stopped)appendIndexLog("========== 電子書與漫畫兩個書庫均已完成 ==========","success");
    else appendIndexLog("連續掃描已停止；已完成項目及 D1 進度保留，可稍後續作。","warning");
  } finally {
    state.scanAllRunning=false;
    ["cloud-scan-books","cloud-scan-comics","cloud-scan-all","cloud-retry-covers"].forEach(id=>{const button=$(id);if(button)button.disabled=false;});
    ["cloud-provider","cloud-library-type","cloud-books-root","cloud-comics-root","cloud-save-roots","cloud-save-source","cloud-test-source"].forEach(id=>{const control=$(id);if(control)control.disabled=false;});
  }
}
async function retryCurrentLibraryCovers() {
  if(state.scanRunning||state.scanAllRunning)return;
  if(!state.authenticated) {
    setIndexProgress("尚未通過 Cloudflare Access，無法重試封面。",true);
    return;
  }
  if(!isActiveSourceReady()) {
    setIndexProgress("請先完成目前 OpenList 來源的連線設定。",true);
    return;
  }
  const scope=indexScope();
  const button=$("cloud-retry-covers");
  if(button)button.disabled=true;
  try {
    const count=await retryFailedCovers(scope);
    appendIndexLog("已將 "+count+" 本"+LIBRARY_LABELS[scope.library]+"失敗封面重新排入待處理佇列。",count?"warning":"info");
    if(!count) {
      setIndexProgress("目前 "+LIBRARY_LABELS[scope.library]+"沒有可重試的失敗封面。");
      return;
    }
    await runLibraryScan(scope.library);
  } catch(error) {
    appendIndexLog("重試失敗封面時發生錯誤："+(error.message||error),"error");
    setIndexProgress("重試失敗封面失敗："+(error.message||error),true);
  } finally {
    if(button)button.disabled=state.scanRunning||state.scanAllRunning;
  }
}
function pauseIndexScan(reason="manual") {
  if(!state.scanRunning&&!state.scanAllRunning)return;
  if(!state.scanPauseRequested)state.scanPauseReason=reason==="manual"?"manual":"close";
  state.scanPauseRequested=true;
  const button=$("cloud-scan-pause");
  if(button)button.disabled=true;
  setIndexProgress(reason==="manual"
    ?"已要求手動暫停；目前目錄頁或封面工作完成並保存 D1 游標後就會停止。"
    :"已關閉掃描視窗；目前工作完成後會保存 D1 游標。下次開啟後，按「掃描／續掃」手動繼續。");
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
      await loadRemotePreferences();
      renderProfileStatus();
      const savedProvider = state.remotePreferences.activeProvider;
      const savedLibrary = state.remotePreferences.activeLibrary;
      const selectedProvider = Object.prototype.hasOwnProperty.call(PROVIDER_LABELS, savedProvider) ? savedProvider : "vps";
      const selectedLibrary = savedLibrary === "books" || savedLibrary === "comics" ? savedLibrary : "books";
      state.activeProvider = selectedProvider;
      state.editProvider = selectedProvider;
      state.activeLibrary = selectedLibrary;
      $("cloud-provider").value = selectedProvider;
      $("cloud-library-type").value = selectedLibrary;
      readRootSelections(selectedProvider);
      clearListing();
      await renderAllScanSummaries();
      if(!isManagerEmbed||embeddedManagerVisible)openCloudSettings(selectedLibrary);
      if(isActiveSourceReady()) {
        state.currentPath=getActiveRoot();
        setSourceStatus("私人書庫已登入，正在讀取 "+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+" 的 D1 索引……");
        await loadDirectory(state.currentPath,1);
      } else {
        setSourceStatus("私人書庫已登入。請先完成 "+PROVIDER_LABELS[state.activeProvider]+" 的帳號密碼設定，再按「讀取書架」。",true);
      }
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
    if(safePath===selected)query.set("recursive","1");
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
      $("cloud-browser-status").textContent="已從 D1 載入索引目錄。掃描完成的書籍會自動加入我的書架；只有開啟閱讀時才讀取原始檔案。";
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
    setSourceStatus(error.message||String(error),true);
  } finally {
    $("cloud-refresh").disabled=false;
    $("cloud-test-source").disabled=false;
  }
}
function makeItem(item) {
  const row=document.createElement("article");
  row.className=item.isDir?"cloud-item cloud-folder-item":"cloud-item cloud-book-card";
  if(item.isDir) {
    const icon=document.createElement("span");icon.className="cloud-item-icon";icon.textContent="▰";
    const copy=document.createElement("div");copy.className="cloud-item-copy";
    const title=document.createElement("strong");title.textContent=item.name;
    const meta=document.createElement("span");meta.textContent="資料夾";
    copy.append(title,meta);
    const actions=document.createElement("div");actions.className="cloud-item-actions";
    const open=document.createElement("button");open.type="button";open.className="cloud-folder-button";open.textContent="開啟資料夾";
    open.addEventListener("click",()=>loadDirectory(item.path,1));
    actions.append(open);row.append(icon,copy,actions);
    return row;
  }

  const cover=document.createElement("div");cover.className="cloud-book-cover";
  const placeholder=document.createElement("div");placeholder.className="cloud-cover-placeholder";
  placeholder.innerHTML='<span>F</span><small>FRAME READER</small>';
  cover.append(placeholder);
  if(item.coverHash&&item.coverStatus==="ready") {
    const image=document.createElement("img");
    image.className="cloud-cover-image";
    image.alt=item.name+" 封面";
    image.loading="lazy";
    image.decoding="async";
    image.src="/api/cloud/covers?hash="+encodeURIComponent(item.coverHash);
    image.addEventListener("load",()=>placeholder.remove(),{once:true});
    image.addEventListener("error",()=>{image.remove();placeholder.classList.add("is-unavailable");},{once:true});
    cover.append(image);
  } else {
    const status=document.createElement("small");
    status.className="cloud-cover-status";
    status.textContent=item.coverStatus==="error"?"封面待重試":item.coverStatus==="missing"?"沒有內嵌封面":"封面待索引";
    cover.append(status);
  }

  const copy=document.createElement("div");copy.className="cloud-item-copy";
  const title=document.createElement("strong");title.textContent=item.name.replace(/\.(epub|cbz)$/i,"");
  title.title=item.name;
  const meta=document.createElement("span");
  const root=getActiveRoot();
  const relativeFolder=item.parentPath&&String(item.parentPath).startsWith(root)
    ?String(item.parentPath).slice(root.length).replace(/^\/+/,"")
    :String(item.parentPath||"");
  meta.textContent=(item.format||"書籍")+" · "+formatBytes(item.size)+
    (item.modified?" · "+String(item.modified).slice(0,10):"")+
    (relativeFolder?" · "+relativeFolder:"");
  copy.append(title,meta);
  const actions=document.createElement("div");actions.className="cloud-item-actions";
  const add=document.createElement("button");add.type="button";add.className="cloud-import-button";
  add.textContent=state.busy.has(item.path)?"正在準備閱讀……":"開啟閱讀室";
  add.disabled=state.busy.has(item.path);
  add.addEventListener("click",()=>openCloudBook(item));
  actions.append(add);
  row.append(cover,copy,actions);
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
async function openCloudBook(item) {
  if (state.busy.has(item.path)) return;
  const scope = indexScope();
  if (!isWithinRoot(item.path, scope.rootPath)) {
    $("cloud-browser-status").textContent = "檔案路徑超出目前書庫根目錄。";
    return;
  }
  if ((scope.library === "books" && item.format !== "EPUB") ||
      (scope.library === "comics" && item.format !== "EPUB" && item.format !== "CBZ")) {
    $("cloud-browser-status").textContent = "檔案格式與目前選擇的書庫分類不符。";
    return;
  }
  state.busy.add(item.path);
  renderItems();
  $("cloud-browser-status").textContent = "正在確認雲端索引並準備閱讀室……";
  try {
    const store = await import("/assets/library-store.js?v=20261116-cloud-only-r2");
    const id = await store.cloudBookId(scope, item.path);
    const query = new URLSearchParams({
      book: id,
      provider: scope.provider,
      library: scope.library,
      root_path: scope.rootPath,
      path: item.path
    });
    $("cloud-browser-status").textContent = "索引已確認，正在開啟閱讀室。原始檔案只會在閱讀時由伺服器讀取。";
    location.href = "/epub-lab/?" + query.toString();
  } catch (error) {
    $("cloud-browser-status").textContent = (error.message || String(error)) + "。請先完成掃描索引。";
    state.busy.delete(item.path);
    renderItems();
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
  setSourceStatus("已選擇"+LIBRARY_LABELS[library]+"根目錄："+candidate+"。請按「保存電子書／漫畫根目錄」。");
}
const settingsDialog=$("cloud-settings-dialog");
function selectCloudManagerTab(name="connection") {
  const selected=name==="library"?"library":"connection";
  document.querySelectorAll("[data-cloud-manager-tab]").forEach(button=>{
    const active=button.dataset.cloudManagerTab===selected;
    button.setAttribute("aria-selected",active?"true":"false");
  });
  const connectionPanel=$("cloud-manager-tab-connection");
  const libraryPanel=$("cloud-manager-tab-library");
  if(connectionPanel)connectionPanel.hidden=selected!=="connection";
  if(libraryPanel)libraryPanel.hidden=selected!=="library";
}
document.querySelectorAll("[data-cloud-manager-tab]").forEach(button=>{
  button.addEventListener("click",()=>selectCloudManagerTab(button.dataset.cloudManagerTab));
});
function openCloudSettings(targetLibrary=state.activeLibrary) {
  selectCloudManagerTab("connection");
  if(!settingsDialog)return;
  if(!settingsDialog.open) {
    if(typeof settingsDialog.showModal==="function")settingsDialog.showModal();
    else settingsDialog.setAttribute("open","");
  }
  if(["books","comics"].includes(targetLibrary)) {
    state.activeLibrary=targetLibrary;
    $("cloud-library-type").value=targetLibrary;
    void saveRemotePreference("activeLibrary", targetLibrary).catch(error => setSourceStatus(error.message || String(error), true));
  }
  state.editProvider=state.activeProvider;
  readRootSelections(state.activeProvider);
  $("cloud-provider").value=state.activeProvider;
  void renderAllScanSummaries(state.activeProvider,state.selectedRoots);
}
if(isManagerEmbed) {
  window.addEventListener("message",event=>{
    if(event.origin!==location.origin||event.source!==window.parent||!event.data)return;
    if(event.data.type==="frame-reader-cloud-manager-open") {
      embeddedManagerVisible=true;
      if(state.authenticated)openCloudSettings();
    } else if(event.data.type==="frame-reader-cloud-manager-close") {
      embeddedManagerVisible=false;
      if(state.scanRunning||state.scanAllRunning)pauseIndexScan("close");
      if(settingsDialog?.open)settingsDialog.close();
    }
  });
}
$("cloud-settings-open")?.addEventListener("click",openCloudSettings);
$("cloud-settings-close")?.addEventListener("click",()=>{
  if(state.scanRunning||state.scanAllRunning)pauseIndexScan("close");
  if(settingsDialog?.open)settingsDialog.close();
  state.editProvider=state.activeProvider;
  readRootSelections(state.activeProvider);
});
settingsDialog?.addEventListener("close",()=>{
  if(state.scanRunning||state.scanAllRunning)pauseIndexScan("close");
  state.editProvider=state.activeProvider;
  readRootSelections(state.activeProvider);
});
window.addEventListener("pagehide",()=>{
  if(state.scanRunning||state.scanAllRunning)pauseIndexScan("close");
});
$("cloud-scan-books").addEventListener("click",()=>runLibraryScan("books"));
$("cloud-scan-comics").addEventListener("click",()=>runLibraryScan("comics"));
$("cloud-scan-books-full").addEventListener("click",()=>{
  if(window.confirm("將完整重掃電子書根目錄：重新遍歷所有資料夾與 EPUB，更新 D1 書目及封面，完成後清理已不存在的索引。原始檔案與閱讀標註不會被修改。確定開始？"))
    void runLibraryScan("books",{forceRescan:true});
});
$("cloud-scan-comics-full").addEventListener("click",()=>{
  if(window.confirm("將完整重掃漫畫根目錄：重新遍歷所有資料夾與 EPUB／CBZ，更新 D1 書目及封面，完成後清理已不存在的索引。原始檔案與閱讀標註不會被修改。確定開始？"))
    void runLibraryScan("comics",{forceRescan:true});
});
$("cloud-scan-all").addEventListener("click",runAllIndexScans);
$("cloud-scan-pause").addEventListener("click",()=>pauseIndexScan("manual"));
$("cloud-retry-covers").addEventListener("click",retryCurrentLibraryCovers);
$("cloud-index-log-copy").addEventListener("click",async()=>{
  try {
    await navigator.clipboard.writeText(state.scanLogEntries.join("\n"));
    appendIndexLog("掃描日誌已複製到剪貼簿。","success");
  } catch(error) {
    appendIndexLog("複製日誌失敗："+(error.message||error),"error");
  }
});
$("cloud-index-log-clear").addEventListener("click",()=>{
  state.scanLogEntries.length=0;
  const output=$("cloud-index-log");
  if(output)output.textContent="日誌已清空。下一個掃描事件會顯示於此。";
  const count=$("cloud-index-log-count");
  if(count)count.textContent="0 筆";
});
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
$("cloud-provider").addEventListener("change", event => {
  const provider = event.target.value;
  if (!Object.prototype.hasOwnProperty.call(PROVIDER_LABELS, provider)) return;
  state.editProvider = provider;
  readRootSelections(provider);
  void renderAllScanSummaries(provider, state.editRoots);
  setSourceStatus("目前活動來源仍是 " + PROVIDER_LABELS[state.activeProvider] + "；按「保存來源設定」後才會切換為 " + PROVIDER_LABELS[provider] + "。");
});
$("cloud-library-type").addEventListener("change", event => {
  const library = event.target.value === "comics" ? "comics" : "books";
  state.activeLibrary = library;
  void saveRemotePreference("activeLibrary", library).catch(error => setSourceStatus(error.message || String(error), true));
  clearListing();
  if (isActiveSourceReady()) {
    state.currentPath = getActiveRoot(library);
    void loadDirectory(state.currentPath, 1);
  } else {
    setSourceStatus("已切換至" + LIBRARY_LABELS[library] + "。請先完成雲端來源設定。", true);
  }
});
$("cloud-save-source").addEventListener("click", async () => {
  try {
    await saveRootSelections();
    const provider = await saveSourceSettings();
    if (isActiveSourceReady()) {
      state.currentPath = getActiveRoot();
      await loadDirectory(state.currentPath, 1);
      await renderAllScanSummaries(provider, state.selectedRoots);
    }
  } catch (error) { setSourceStatus(error.message || String(error), true); }
});
$("cloud-save-roots").addEventListener("click", async () => {
  try { await saveRootSelections(); }
  catch (error) { setSourceStatus(error.message || String(error), true); }
});
$("cloud-use-current-books-root").addEventListener("click",()=>setCurrentFolderAsRoot("books"));
$("cloud-use-current-comics-root").addEventListener("click",()=>setCurrentFolderAsRoot("comics"));
$("cloud-test-source").addEventListener("click", async () => {
  const button = $("cloud-test-source");
  if (button) button.disabled = true;
  try {
    await saveRootSelections();
    await saveSourceSettings();
    const root = getActiveRoot();
    if (!root) throw new Error("尚未設定目前" + LIBRARY_LABELS[state.activeLibrary] + "根目錄。");
    setSourceStatus("正在測試 " + PROVIDER_LABELS[state.activeProvider] + " 伺服器端連線與目錄讀取……");
    await fetchScanDirectory(root, 1, 1);
    setSourceStatus("Alist／OpenList 連線成功，目錄可讀取。正在載入目前書庫的 D1 索引……");
    state.currentPath = root;
    await loadDirectory(root, 1);
  } catch (error) {
    setSourceStatus(error.message || String(error), true);
  } finally {
    if (button) button.disabled = false;
  }
});
checkSession();
