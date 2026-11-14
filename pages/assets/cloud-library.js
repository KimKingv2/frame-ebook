import { importBookFile } from "/assets/library-store.js?v=20261114-shelf-classification1";
import { ZipReader, BlobWriter, TextWriter } from "/vendor/foliate-js/vendor/zip.js";

const $ = id => document.getElementById(id);
const ACTIVE_PROVIDER_KEY = "frame-reader-active-openlist-provider";
const ROOT_SELECTIONS_KEY = "frame-reader-cloud-root-selections-v2";
const ACTIVE_LIBRARY_KEY = "frame-reader-active-library";
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
  scanAllRunning:false,
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
function readRootSelections(provider=state.activeProvider) {
  let saved={};
  try { saved=JSON.parse(localStorage.getItem(ROOT_SELECTIONS_KEY)||"{}"); } catch (_) {}
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root":"cloud-comics-root";
    const defaultPath=$(id).getAttribute("value")||"/";
    const candidate=normalizePath(saved?.[provider]?.[library]||defaultPath||"/");
    state.selectedRoots[library]=candidate||"/";
    $(id).value=state.selectedRoots[library];
  }
  renderRootStatus();
}
function persistRootSelections(provider=state.activeProvider) {
  let saved={};
  try { saved=JSON.parse(localStorage.getItem(ROOT_SELECTIONS_KEY)||"{}"); } catch (_) {}
  saved[provider]={books:state.selectedRoots.books||"/",comics:state.selectedRoots.comics||"/"};
  try { localStorage.setItem(ROOT_SELECTIONS_KEY,JSON.stringify(saved)); }
  catch (_) { throw new Error("無法保存書庫根目錄，請檢查瀏覽器本機儲存空間權限。"); }
}
function renderRootStatus() {
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root-status":"cloud-comics-root-status";
    const selected=state.selectedRoots[library]||"/";
    $(id).textContent="目前已保存於這台裝置："+selected;
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
  persistRootSelections(state.activeProvider);
  renderRootStatus();
  clearListing("目錄設定已套用");
  setSourceStatus("電子書與漫畫根目錄已保存於這台裝置；重新進入或重新整理後仍會沿用。不同 OpenList 來源可保存各自的路徑。");
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
    "格式不符而略過："+Number(scanState.skippedCount||0)+" 筆",
    "累計失敗："+Number(scanState.failedCount||0)+" 筆",
    "已完成資料夾："+Number(scanState.visitedFolderCount||0)+" 個",
    "待掃描資料夾："+(scanState.pendingFolders||[]).length+(scanState.currentFolder?"；目前："+scanState.currentFolder:""),
    "封面已保存："+Number(scanState.coverReadyCount||0)+" 本；無封面："+Number(scanState.coverMissingCount||0)+
      " 本；失敗："+Number(scanState.coverFailedCount||0)+" 本"
  ];
  if(scanState.currentFolder)lines.push("續作游標：第 "+Number(scanState.page||1)+" 頁");
  if(scanState.lastError)lines.push("最近錯誤："+String(scanState.lastError));
  if(scanState.completed)lines.push("狀態：目錄索引已完成；D1 書架已可直接載入。");
  else lines.push("狀態：掃描未完成；再次點擊對應按鈕即可續掃。");
  node.textContent=lines.join("\n");
}
async function renderAllScanSummaries() {
  const provider=state.activeProvider;
  for(const library of ["books","comics"]) {
    const rootPath=state.selectedRoots[library]||"/";
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
    "不符合書庫格式而略過："+Number(scanState.skippedCount||0)+" 筆",
    "累計失敗："+Number(scanState.failedCount||0)+" 筆",
    "已完成資料夾："+Number(scanState.visitedFolderCount||0)+" 個",
    "待掃描資料夾："+(scanState.pendingFolders||[]).length+(scanState.currentFolder?"；目前："+scanState.currentFolder:""),
    "本批檢查："+Number(batch.entries||0)+" 個；寫入／更新："+Number(batch.indexed||0)+
      " 個；略過："+Number(batch.skipped||0)+" 個；失敗："+Number(batch.failed||0)+
      " 個；完成資料夾："+Number(batch.folders||0)+" 個"
  ];
  if(batch.currentPath)lines.push("正在處理："+batch.currentPath);
  if(batch.lastCompleted)lines.push("最近完成："+batch.lastCompleted);
  if(batch.coverProcessed!=null)lines.push("本批封面：處理 "+batch.coverProcessed+" 本；無封面 "+
    Number(batch.coverMissing||0)+" 本；失敗 "+Number(batch.coverFailed||0)+" 本；待處理 "+Number(batch.coverRemaining||0)+" 本");
  if(batch.stopReason)lines.push("本批停止原因："+batch.stopReason);
  if(scanState.currentFolder)lines.push("續作游標：第 "+Number(scanState.page||1)+" 頁；每頁完成後保存至 D1。");
  if(scanState.completed)lines.push("目錄索引已完成。重新進入時會直接讀取 D1 書架；封面佇列完成後不會重複遍歷目錄。");
  else if(finished&&state.scanPauseRequested)lines.push("已要求暫停，進度已保存；可在下次進入時續掃。");
  else if(finished)lines.push("本批結束，進度已保存到 D1；可關閉頁面，之後再續掃。");
  else lines.push("掃描進行中；目錄索引與續作游標會持續保存至 D1。");
  const lastError=scanState.errors?.[scanState.errors.length-1];
  if(lastError)lines.push("最近錯誤："+String(lastError.path||"")+"｜"+String(lastError.message||""));
  return lines.join("\n");
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
  async readUint8Array(offset,length) {
    const start=Math.max(0,Number(offset)||0);
    const count=Math.max(0,Number(length)||0);
    if(!count||start>=this.size)return new Uint8Array();
    const end=Math.min(this.size,start+count)-1;
    const number=++this.rangeCount;
    const started=performance.now();
    this.onEvent("封面 Range #"+number+" 開始；bytes="+start+"-"+end);
    try {
      const bytes=await this.readRange(start,end);
      this.bytesRead+=bytes.byteLength;
      this.onEvent("封面 Range #"+number+" 完成；取得 "+formatBytes(bytes.byteLength)+"；累計 "+formatBytes(this.bytesRead)+"；耗時 "+Math.round(performance.now()-started)+" ms","success");
      return bytes;
    } catch(error) {
      this.onEvent("封面 Range #"+number+" 失敗："+(error.message||error)+"；耗時 "+Math.round(performance.now()-started)+" ms","error");
      throw error;
    }
  }
}
async function makeCoverRangeReader(item,onEvent=()=>{}) {
  const size=Number(item.size)||0;
  if(!Number.isSafeInteger(size)||size<=0)throw new Error("檔案大小無效，無法使用 HTTP Range 讀取封面。");
  if(state.activeProvider==="local") {
    const profile=getActiveProfile();
    const payload=await directOpenList("get",{path:item.path,password:""});
    const metadata=payload.data||{};
    if(metadata.is_dir||!metadata.raw_url)throw new Error("區域網路 OpenList 沒有提供檔案下載位址。");
    const target=new URL(String(metadata.raw_url),profile.baseUrl+"/");
    if(!["http:","https:"].includes(target.protocol))throw new Error("封面來源網址格式不受支援。");
    return new HttpRangeReader(size,async(start,end)=>{
      const response=await fetch(target.href,{
        method:"GET",mode:"cors",credentials:"omit",redirect:"follow",
        headers:{Range:"bytes="+start+"-"+end},
        ...localNetworkOptions(target.href)
      });
      return readRangeResponse(response,start,end,size);
    },onEvent);
  }
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
async function findEpubCover(zipEntries) {
  const byName=new Map(zipEntries.filter(entry=>!entry.directory).map(entry=>[zipPath(entry.filename),entry]));
  const container=byName.get("META-INF/container.xml");
  if(!container)return null;
  const containerText=await container.getData(new TextWriter("utf-8"));
  const containerXml=new DOMParser().parseFromString(String(containerText),"application/xml");
  const rootfile=containerXml.getElementsByTagName("rootfile")[0];
  const opfPath=zipPath(rootfile?.getAttribute("full-path")||"");
  if(!opfPath)return null;
  const opfEntry=byName.get(opfPath);
  if(!opfEntry)return null;
  const opfText=await opfEntry.getData(new TextWriter("utf-8"));
  const opfXml=new DOMParser().parseFromString(String(opfText),"application/xml");
  if(opfXml.getElementsByTagName("parsererror").length)return null;
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
  const rangeReader=await makeCoverRangeReader(item,onEvent);
  const zip=new ZipReader(rangeReader);
  const entries=await zip.getEntries();
  const found=item.format==="CBZ"?await findCbzCover(entries):await findEpubCover(entries);
  if(!found)return null;
  const sourceBlob=await found.entry.getData(new BlobWriter(found.mime));
  return resizeCover(sourceBlob);
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
          const hash=await blobSha256(cover.blob);
          await uploadCover(scope,item,hash,cover);
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
    await saveIndexScanState(scanState,scope);
  }
  appendIndexLog("封面索引本批完成：處理 "+processed+" 本，無封面 "+missing+" 本，失敗 "+failed+" 本，待處理 "+remaining.total+" 本。");
  return {processed,failed,missing,remaining:Number(remaining.total||0)};
}

async function runIndexScan(targetLibrary=state.activeLibrary,fromAll=false) {
  if(state.scanRunning||(!fromAll&&state.scanAllRunning))return {ok:false,reason:"already_running"};
  if(!["books","comics"].includes(targetLibrary))return {ok:false,reason:"invalid_library"};
  state.activeLibrary=targetLibrary;
  $("cloud-library-type").value=targetLibrary;
  state.currentPath=getActiveRoot(targetLibrary);
  if(!state.authenticated) {
    setIndexProgress("尚未通過 Cloudflare Access，無法開始索引。",true);
    return {ok:false,reason:"not_authenticated"};
  }
  if(!isActiveSourceReady()) {
    setIndexProgress("請先完成目前 OpenList 來源的網址、帳號與密碼設定。",true);
    return {ok:false,reason:"source_not_ready"};
  }
  try { saveRootSelections(); }
  catch(error) {
    setIndexProgress(error.message||"書庫根目錄設定無效。",true);
    return {ok:false,reason:"invalid_root"};
  }

  const scope=indexScope();
  const scanButtons=["cloud-scan-books","cloud-scan-comics","cloud-scan-all"];
  const pauseButton=$("cloud-scan-pause");
  let scanState=null;
  let outcome={ok:false};
  const batch={entries:0,indexed:0,skipped:0,failed:0,folders:0,currentPath:"",coverProcessed:0,coverMissing:0,coverFailed:0};

  if(scope.rootPath==="/") {
    if(!window.confirm("目前"+LIBRARY_LABELS[targetLibrary]+"根目錄是「/」，代表會遞迴掃描整個 OpenList 根目錄。\n\n建議先填入專門的書籍／漫畫資料夾，以免掃描其他雲端檔案。仍要繼續嗎？"))
      return {ok:false,cancelled:true};
  }

  state.scanRunning=true;
  state.scanPauseRequested=false;
  scanButtons.forEach(id=>{const button=$(id);if(button)button.disabled=true;});
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

    if(scanState&&scanState.rootPath===scope.rootPath&&scanState.provider===scope.provider&&
       scanState.library===scope.library&&scanState.version===1&&scanState.completed) {
      const existingQueue=await fetchPendingCovers(scope,1);
      if(existingQueue.total) {
        appendIndexLog("目錄索引已完成；本次只續做尚未完成的封面，不重新遍歷 OpenList。","warning");
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
    } else {
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
      appendIndexLog("D1 索引寫入完成："+saved+" 筆；耗時 "+writeElapsed+" ms。","success");
      if(lastBook)appendIndexLog("最近完成："+lastBook.name+"｜"+lastBook.path+"｜已寫入／更新 D1。","success");

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
      const reason=state.scanPauseRequested?"使用者暫停":
        batch.entries>=maxEntriesPerBatch?"達到每批 500 個目錄項目上限":
        batch.folders>=maxFoldersPerBatch?"達到每批 500 個資料夾上限":"達到單批 4 分鐘安全時限";
      batch.stopReason=reason;
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
    ["cloud-provider","cloud-library-type","cloud-books-root","cloud-comics-root","cloud-save-roots","cloud-save-source","cloud-test-source"].forEach(id=>{
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
async function runLibraryScanContinuous(library) {
  if(state.scanAllRunning||state.scanRunning)return;
  state.scanAllRunning=true;
  ["cloud-scan-books","cloud-scan-comics","cloud-scan-all"].forEach(id=>{const button=$(id);if(button)button.disabled=true;});
  appendIndexLog("========== 開始連續掃描："+LIBRARY_LABELS[library]+" ==========");
  let result={ok:false};
  try {
    do {
      result=await runIndexScan(library,true);
      if(!result?.ok||result.paused||result.cancelled)break;
      if(!result.completed)appendIndexLog("本批已保存；自動從 D1 游標繼續下一批。","warning");
    } while(!result.completed);
    return result;
  } finally {
    state.scanAllRunning=false;
    ["cloud-scan-books","cloud-scan-comics","cloud-scan-all"].forEach(id=>{const button=$(id);if(button)button.disabled=false;});
  }
}
async function runAllIndexScans() {
  if(state.scanAllRunning||state.scanRunning)return;
  state.scanAllRunning=true;
  ["cloud-scan-books","cloud-scan-comics","cloud-scan-all"].forEach(id=>{const button=$(id);if(button)button.disabled=true;});
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
    ["cloud-scan-books","cloud-scan-comics","cloud-scan-all"].forEach(id=>{const button=$(id);if(button)button.disabled=false;});
  }
}function pauseIndexScan() {
  if (!state.scanRunning) return;
  state.scanPauseRequested = true;
  $("cloud-scan-pause").disabled = true;
  setIndexProgress("已要求暫停；目前目錄頁或封面工作完成並保存 D1 游標後就會停止。");
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
      renderProfileStatus();
      let selectedProvider="vps",selectedLibrary="books";
      try {
        const savedProvider=localStorage.getItem(ACTIVE_PROVIDER_KEY)||"vps";
        if(Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,savedProvider))selectedProvider=savedProvider;
        const savedLibrary=localStorage.getItem(ACTIVE_LIBRARY_KEY)||"books";
        if(savedLibrary==="books"||savedLibrary==="comics")selectedLibrary=savedLibrary;
      } catch (_) {}
      state.activeProvider=selectedProvider;
      state.activeLibrary=selectedLibrary;
      $("cloud-provider").value=selectedProvider;
      $("cloud-library-type").value=selectedLibrary;
      readRootSelections(selectedProvider);
      clearListing();
      await renderAllScanSummaries();
      if(isActiveSourceReady()) {
        state.currentPath=getActiveRoot();
        setSourceStatus("私人書庫已登入，正在讀取 "+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+" 的 D1 索引……");
        await loadDirectory(state.currentPath,1);
      } else {
        setSourceStatus("私人書庫已登入。請先完成 "+PROVIDER_LABELS[state.activeProvider]+" 的帳號密碼設定，再按「讀取書架」。",true);
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
  add.textContent=state.busy.has(item.path)?"正在加入……":"加入本機書架";
  add.disabled=state.busy.has(item.path);
  add.addEventListener("click",()=>importCloudFile(item));
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
      const query=new URLSearchParams({path:item.path,root_path:getActiveRoot(),provider:state.activeProvider,library});
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
$("cloud-scan-books").addEventListener("click",()=>runLibraryScanContinuous("books"));
$("cloud-scan-comics").addEventListener("click",()=>runLibraryScanContinuous("comics"));
$("cloud-scan-all").addEventListener("click",runAllIndexScans);
$("cloud-scan-pause").addEventListener("click",pauseIndexScan);
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
$("cloud-provider").addEventListener("change",event=>{
  const previousProvider=state.activeProvider;
  try { persistRootSelections(previousProvider); } catch(error) { setSourceStatus(error.message||String(error),true); }
  const provider=event.target.value;
  state.activeProvider=provider;
  try { localStorage.setItem(ACTIVE_PROVIDER_KEY,provider); } catch (_) {}
  readRootSelections(provider);
  void renderAllScanSummaries();
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
  try { localStorage.setItem(ACTIVE_LIBRARY_KEY,library); } catch (_) {}
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
