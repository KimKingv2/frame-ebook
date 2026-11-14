import { importBookFile } from "/assets/library-store.js";

const $ = id => document.getElementById(id);
const ACTIVE_PROVIDER_KEY = "frame-reader-active-openlist-provider";
const LOCAL_PROFILE_KEY = "frame-reader-local-openlist-profile-v1";
const ROOT_SELECTIONS_KEY = "frame-reader-cloud-root-selections-v1";
const PROVIDER_LABELS = {
  vps: "VPS Alist",
  worker: "OpenList Worker",
  mobile: "Mobile Device Alist",
  local: "區域網路 OpenList"
};
const LIBRARY_LABELS = { books: "電子書", comics: "漫畫" };
const state = {
  authenticated:false,
  databaseConfigured:false,
  allowedRoots:{books:"",comics:""},
  selectedRoots:{books:"",comics:""},
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
  localProfile:{baseUrl:"",token:""},
  connected:false
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
  return state.allowedRoots[library]||"";
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
  try {
    const parsed=JSON.parse(localStorage.getItem(LOCAL_PROFILE_KEY)||"{}");
    state.localProfile={baseUrl:String(parsed.baseUrl||""),token:String(parsed.token||"")};
  } catch (_) {
    state.localProfile={baseUrl:"",token:""};
  }
  $("cloud-local-url").value=state.localProfile.baseUrl;
  $("cloud-local-token").value=state.localProfile.token;
}
function readRootSelections() {
  let saved={};
  try { saved=JSON.parse(localStorage.getItem(ROOT_SELECTIONS_KEY)||"{}"); } catch (_) {}
  for(const library of ["books","comics"]) {
    const allowed=getAllowedRoot(library);
    const candidate=normalizePath(saved[library]||allowed);
    state.selectedRoots[library]=candidate&&isWithinRoot(candidate,allowed)?candidate:allowed;
  }
  $("cloud-books-root").value=state.selectedRoots.books||"";
  $("cloud-comics-root").value=state.selectedRoots.comics||"";
  renderRootStatus();
}
function renderRootStatus() {
  for(const library of ["books","comics"]) {
    const id=library==="books"?"cloud-books-root-status":"cloud-comics-root-status";
    const selected=state.selectedRoots[library];
    const allowed=getAllowedRoot(library);
    $(id).textContent=allowed
      ?"最大允許範圍："+allowed+(selected&&selected!==allowed?" · 本機目前使用："+selected:"")
      :"尚未設定 OPENLIST_"+(library==="books"?"BOOKS":"COMICS")+"_ROOT_PATH";
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
    const allowed=getAllowedRoot(library);
    if(!allowed) {
      if(values[library])throw new Error(LIBRARY_LABELS[library]+"尚未設定伺服器端允許範圍。請先設定 OPENLIST_"+(library==="books"?"BOOKS":"COMICS")+"_ROOT_PATH。");
      state.selectedRoots[library]="";
      continue;
    }
    const candidate=normalizePath(values[library]||allowed);
    if(!candidate||!isWithinRoot(candidate,allowed))throw new Error(LIBRARY_LABELS[library]+"路徑必須位於伺服器允許範圍內："+allowed);
    state.selectedRoots[library]=candidate;
  }
  try { localStorage.setItem(ROOT_SELECTIONS_KEY,JSON.stringify(state.selectedRoots)); }
  catch (_) { throw new Error("無法保存目錄設定。請檢查瀏覽器的網站儲存空間。"); }
  renderRootStatus();
  clearListing("目錄設定已保存");
  setSourceStatus("電子書與漫畫目錄設定已保存在這台裝置。伺服器仍會強制限制在 Cloudflare 設定的最大允許範圍內。");
}
function saveSourceSettings() {
  const provider=$("cloud-provider").value;
  if(!Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,provider))throw new Error("請選擇有效的書庫來源。");
  if(provider==="local") {
    const baseUrl=normalizeLocalBase($("cloud-local-url").value);
    const token=String($("cloud-local-token").value||"").trim();
    if(!token)throw new Error("請填入這台裝置的區域網路 OpenList API Token。");
    state.localProfile={baseUrl,token};
    try { localStorage.setItem(LOCAL_PROFILE_KEY,JSON.stringify(state.localProfile)); }
    catch (_) { throw new Error("無法將本機來源設定保存在瀏覽器。請檢查網站儲存空間權限。"); }
  } else if(!state.serverProfiles[provider]?.configured) {
    throw new Error(PROVIDER_LABELS[provider]+" 尚未在 Cloudflare Pages Variables／Secrets 完成設定。");
  }
  persistActiveProvider(provider);
  setSourceStatus("已保存來源設定："+PROVIDER_LABELS[provider]+"。尚未發出 OpenList 請求；按「測試目前來源」後才會讀取目錄。");
  return provider;
}
function getActiveProfile() {
  if(state.activeProvider==="local") {
    const profile=state.localProfile;
    if(!profile.baseUrl||!profile.token)throw new Error("尚未保存區域網路 OpenList 網址與 Token。");
    return {baseUrl:normalizeLocalBase(profile.baseUrl),token:profile.token};
  }
  if(!state.serverProfiles[state.activeProvider]?.configured)throw new Error(PROVIDER_LABELS[state.activeProvider]+" 尚未完成 Cloudflare Pages 伺服器端設定。");
  return null;
}
async function directOpenList(endpoint,payload) {
  const profile=getActiveProfile();
  const url=new URL("api/fs/"+endpoint,profile.baseUrl+"/").href;
  let response;
  try {
    response=await fetch(url,{
      method:"POST",mode:"cors",credentials:"omit",redirect:"error",
      headers:{Authorization:profile.token,"Content-Type":"application/json",Accept:"application/json"},
      body:JSON.stringify(payload),
      ...localNetworkOptions(url)
    });
  } catch (cause) {
    throw new Error("無法直接連接區域網路 OpenList。請確認服務、網址、CORS（Authorization／Content-Type）及本機網路權限。"+(cause?.message?" 詳情："+String(cause.message).slice(0,140):""));
  }
  let data;
  try { data=await response.json(); } catch (_) { throw new Error("區域網路 OpenList 回應不是有效 JSON（HTTP "+response.status+"）。"); }
  if(!response.ok)throw new Error(data?.message||data?.error||"OpenList HTTP "+response.status);
  if(Number(data?.code)!==200)throw new Error("區域網路 OpenList API "+(data?.code||"unknown")+"："+String(data?.message||"未知錯誤"));
  return data;
}
async function listLocalDirectory(path,page) {
  const payload=await directOpenList("list",{path,password:"",page,per_page:state.perPage,refresh:false});
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
async function checkSession() {
  try {
    const response=await fetch("/api/auth/session",{credentials:"same-origin"});
    const data=await response.json();
    state.authenticated=!!(response.ok&&data.authenticated);
    state.databaseConfigured=!!data.databaseConfigured;
    state.serverProfiles=data.openListProfiles||{};
    state.allowedRoots={
      books:data.rootPaths?.books?normalizePath(data.rootPaths.books)||"": "",
      comics:data.rootPaths?.comics?normalizePath(data.rootPaths.comics)||"": ""
    };
    if(state.authenticated) {
      $("cloud-login-panel").hidden=true;
      $("cloud-browser").hidden=false;
      readLocalProfile();
      readRootSelections();
      renderProfileStatus();
      let selectedProvider="vps";
      let selectedLibrary="books";
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
      const configuredRoots=["books","comics"].filter(key=>!!state.allowedRoots[key]).length;
      setSourceStatus(
        "已登入。請選擇來源及電子書／漫畫分類，再按「測試目前來源」讀取目錄。已配置 "+configuredRoots+"/2 個伺服器目錄範圍。",
        configuredRoots===0
      );
      try {
        const tracker=await import("/assets/reading-tracker.js");
        await tracker.syncPending(true);
      } catch (_) {}
    } else {
      $("cloud-login-panel").hidden=false;
      $("cloud-browser").hidden=true;
      const loginButton=$("cloud-login-form").querySelector("button");
      loginButton.disabled=!state.databaseConfigured;
      $("cloud-login-error").textContent=state.databaseConfigured
        ?""
        :"Cloudflare D1 尚未綁定，請先完成專案設定再登入。詳見 docs/CLOUDFLARE-SETUP.md。";
    }
  } catch(error) {
    $("cloud-browser-status").textContent="無法確認登入狀態："+(error.message||String(error));
  }
}
async function login(event) {
  event.preventDefault();
  const button=$("cloud-login-form").querySelector("button");
  button.disabled=true;
  $("cloud-browser-status").textContent="正在驗證私人密碼……";
  try {
    const response=await fetch("/api/auth/login",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:$("cloud-password").value})});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error||"登入失敗。");
    $("cloud-login-error").textContent="";
    $("cloud-password").value="";
    await checkSession();
  } catch(error) {
    $("cloud-login-error").textContent=error.message||String(error);
  } finally {
    button.disabled=!state.databaseConfigured;
  }
}
async function logout() {
  try { await fetch("/api/auth/logout",{method:"POST",credentials:"same-origin"}); } catch (_) {}
  state.authenticated=false;
  state.connected=false;
  $("cloud-login-panel").hidden=false;
  $("cloud-browser").hidden=true;
}
async function loadDirectory(path=getActiveRoot(),page=1) {
  state.page=Math.max(1,Number(page)||1);
  const allowed=getAllowedRoot();
  const selected=getActiveRoot();
  const safePath=normalizePath(path);
  if(!allowed) {
    const message="尚未設定 "+(state.activeLibrary==="books"?"OPENLIST_BOOKS_ROOT_PATH":"OPENLIST_COMICS_ROOT_PATH")+"。";
    $("cloud-browser-status").textContent=message;
    setSourceStatus(message,true);
    return;
  }
  if(!selected||!isWithinRoot(selected,allowed)) {
    const message="目前"+LIBRARY_LABELS[state.activeLibrary]+"根目錄不在伺服器允許範圍內。";
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
  $("cloud-browser-status").textContent="正在連接 "+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+"……";
  $("cloud-refresh").disabled=true;
  $("cloud-test-source").disabled=true;
  try {
    let data;
    if(state.activeProvider==="local") {
      data=await listLocalDirectory(safePath,state.page);
    } else {
      const query=new URLSearchParams({path:safePath,page:String(state.page),per_page:String(state.perPage),provider:state.activeProvider,library:state.activeLibrary});
      const response=await fetch("/api/cloud/books?"+query.toString(),{credentials:"same-origin"});
      data=await response.json();
      if(!response.ok)throw new Error(data.error||"OpenList 目錄讀取失敗。");
    }
    state.currentPath=data.path||safePath;
    state.items=Array.isArray(data.items)?data.items:[];
    state.total=Number(data.total)||0;
    state.page=Number(data.page)||state.page;
    state.connected=true;
    $("cloud-connection-status").textContent="已連線 · "+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary];
    $("cloud-breadcrumb").textContent=breadcrumb(state.currentPath);
    $("cloud-item-count").textContent="顯示 "+state.items.length+" / "+state.total+" 個項目";
    $("cloud-page-label").textContent="第 "+state.page+" 頁 · 共 "+Math.max(1,Math.ceil(state.total/state.perPage))+" 頁";
    $("cloud-prev-page").disabled=state.page<=1;
    $("cloud-next-page").disabled=state.page*state.perPage>=state.total;
    renderItems();
    $("cloud-browser-status").textContent="已連接 "+PROVIDER_LABELS[state.activeProvider]+" 的"+LIBRARY_LABELS[state.activeLibrary]+"目錄。只有選擇書籍後才會下載內容。";
    setSourceStatus("連線成功："+PROVIDER_LABELS[state.activeProvider]+" · "+LIBRARY_LABELS[state.activeLibrary]+" · "+safePath);
  } catch(error) {
    state.connected=false;
    $("cloud-items").replaceChildren();
    $("cloud-page-label").textContent="目錄尚未載入";
    $("cloud-prev-page").disabled=true;
    $("cloud-next-page").disabled=true;
    $("cloud-connection-status").textContent="連線失敗 · "+PROVIDER_LABELS[state.activeProvider];
    $("cloud-browser-status").textContent=error.message||String(error);
    setSourceStatus((error.message||String(error))+". 請檢查來源設定及對應根目錄。",true);
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
  const allowed=getAllowedRoot(library);
  if(!state.currentPath||!isWithinRoot(state.currentPath,allowed)) {
    setSourceStatus("目前瀏覽位置不在"+LIBRARY_LABELS[library]+"的伺服器允許範圍內。",true);
    return;
  }
  const id=library==="books"?"cloud-books-root":"cloud-comics-root";
  $(id).value=state.currentPath;
  setSourceStatus("已選擇"+LIBRARY_LABELS[library]+"根目錄："+state.currentPath+"。請按「保存兩個目錄設定」。");
}
$("cloud-login-form").addEventListener("submit",login);
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
  setSourceStatus("已選擇 "+PROVIDER_LABELS[provider]+"。尚未連線；按「測試目前來源」後才會呼叫該來源。");
});
$("cloud-library-type").addEventListener("change",event=>{
  const library=event.target.value==="comics"?"comics":"books";
  state.activeLibrary=library;
  try { localStorage.setItem("frame-reader-active-library",library); } catch (_) {}
  clearListing();
  setSourceStatus("已切換至"+LIBRARY_LABELS[library]+"。按「測試目前來源」讀取對應根目錄。");
});
$("cloud-save-source").addEventListener("click",()=>{
  try { saveSourceSettings(); }
  catch(error) { setSourceStatus(error.message||String(error),true); }
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
