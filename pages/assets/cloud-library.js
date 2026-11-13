import { importBookFile } from "/assets/library-store.js";

const $ = id => document.getElementById(id);
const ACTIVE_PROVIDER_KEY = "frame-reader-active-openlist-provider";
const LOCAL_PROFILE_KEY = "frame-reader-local-openlist-profile-v1";
const PROVIDER_LABELS = {
  vps: "VPS Alist",
  worker: "OpenList Worker",
  mobile: "Mobile Device Alist",
  local: "區域網路 OpenList"
};
const state = {
  authenticated:false,
  databaseConfigured:false,
  rootPath:"",
  currentPath:"/",
  items:[],
  query:"",
  busy:new Set(),
  page:1,
  perPage:80,
  total:0,
  serverProfiles:{},
  activeProvider:"vps",
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
function breadcrumb(path) {
  const root=state.rootPath.replace(/\/+$/,"")||"/";
  const rel=path===root?"":path.slice(root==="/"?1:root.length+1);
  return rel?root.replace(/\/$/,"")+" / "+rel.replace(/\//g," / "):root;
}
function fileKind(item) {
  const ext=String(item.name||"").split(".").pop().toLowerCase();
  return ext==="epub"?"EPUB":ext==="cbz"?"CBZ":"";
}
function readLocalProfile() {
  try {
    const parsed=JSON.parse(localStorage.getItem(LOCAL_PROFILE_KEY)||"{}");
    state.localProfile={
      baseUrl:String(parsed.baseUrl||""),
      token:String(parsed.token||"")
    };
  } catch (_) {
    state.localProfile={baseUrl:"",token:""};
  }
  $("cloud-local-url").value=state.localProfile.baseUrl;
  $("cloud-local-token").value=state.localProfile.token;
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
function persistActiveProvider(provider) {
  const changed=state.activeProvider!==provider;
  state.activeProvider=provider;
  try { localStorage.setItem(ACTIVE_PROVIDER_KEY,provider); } catch (_) {}
  $("cloud-provider").value=provider;
  $("cloud-connection-status").textContent="尚未測試 · "+PROVIDER_LABELS[provider];
  state.connected=false;
  if(changed) {
    state.items=[];
    state.total=0;
    state.currentPath=state.rootPath||"/";
    $("cloud-items").replaceChildren();
    $("cloud-item-count").textContent="0 個項目";
    $("cloud-breadcrumb").textContent=state.rootPath||"尚未設定根目錄";
    $("cloud-page-label").textContent="尚未連線";
    $("cloud-prev-page").disabled=true;
    $("cloud-next-page").disabled=true;
    $("cloud-empty").hidden=true;
  }
}
function saveSourceSettings() {
  const provider=$("cloud-provider").value;
  if(!Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,provider))throw new Error("請選擇有效的書庫來源。");
  if(!state.rootPath)throw new Error("尚未設定共用 OPENLIST_ROOT_PATH，請先完成 Cloudflare Pages 設定。");
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
      method:"POST",
      mode:"cors",
      credentials:"omit",
      redirect:"error",
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
    if(!itemPath||!isWithinRoot(itemPath,state.rootPath))return null;
    const isDir=!!item.is_dir;
    const format=isDir?"":fileKind(item);
    if(!isDir&&!format)return null;
    return {name:String(item.name||""),path:itemPath,isDir,format,size:Number(item.size)||0,modified:item.modified||item.created||null,supported:true};
  }).filter(Boolean);
  return {path,rootPath:state.rootPath,page:Number(data.page)||page,perPage:Number(data.per_page)||state.perPage,total:Number(data.total)||items.length,items};
}
async function downloadLocalFile(path) {
  if(!isWithinRoot(path,state.rootPath)||!/\.(epub|cbz)$/i.test(path))throw new Error("檔案路徑無效或超出設定的書庫根目錄。");
  const payload=await directOpenList("get",{path,password:""});
  const metadata=payload.data||{};
  if(metadata.is_dir||!metadata.raw_url)throw new Error("OpenList 沒有提供這個檔案的下載位址。");
  const profile=getActiveProfile();
  let target;
  try { target=new URL(String(metadata.raw_url),profile.baseUrl+"/"); }
  catch (_) { throw new Error("OpenList 回傳的檔案位址無效。"); }
  if(!["http:","https:"].includes(target.protocol))throw new Error("OpenList 回傳了不支援的下載協定。");
  let response;
  try {
    response=await fetch(target.href,{method:"GET",mode:"cors",credentials:"omit",redirect:"follow",...localNetworkOptions(target.href)});
  } catch (_) {
    throw new Error("已取得檔案資訊，但瀏覽器無法讀取檔案內容。請檢查下載來源主機的 CORS；原始雲端檔案未被修改。");
  }
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
    state.rootPath=data.rootPath||"";
    if(state.authenticated) {
      $("cloud-login-panel").hidden=true;
      $("cloud-browser").hidden=false;
      readLocalProfile();
      renderProfileStatus();
      let selected="vps";
      try {
        const saved=localStorage.getItem(ACTIVE_PROVIDER_KEY)||"vps";
        if(Object.prototype.hasOwnProperty.call(PROVIDER_LABELS,saved))selected=saved;
      } catch (_) {}
      state.activeProvider=selected;
      $("cloud-provider").value=selected;
      $("cloud-connection-status").textContent="尚未測試 · "+PROVIDER_LABELS[selected];
      setSourceStatus(state.rootPath
        ?"已登入。選擇四路來源之一，按「測試目前來源」後才會連線。共用根目錄："+state.rootPath
        :"尚未設定共用 OPENLIST_ROOT_PATH。完成 Cloudflare 設定後才能使用雲端來源。",!state.rootPath);
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
async function loadDirectory(path=state.currentPath,page=1) {
  state.page=Math.max(1,Number(page)||1);
  const safePath=normalizePath(path);
  if(!safePath||!isWithinRoot(safePath,state.rootPath))throw new Error("目錄路徑無效或超出設定的書庫根目錄。");
  $("cloud-browser-status").textContent="正在連接 "+PROVIDER_LABELS[state.activeProvider]+"……";
  $("cloud-refresh").disabled=true;
  $("cloud-test-source").disabled=true;
  try {
    let data;
    if(state.activeProvider==="local") {
      data=await listLocalDirectory(safePath,state.page);
    } else {
      const query=new URLSearchParams({path:safePath,page:String(state.page),per_page:String(state.perPage),provider:state.activeProvider});
      const response=await fetch("/api/cloud/books?"+query.toString(),{credentials:"same-origin"});
      data=await response.json();
      if(!response.ok)throw new Error(data.error||"OpenList 目錄讀取失敗。");
    }
    state.currentPath=data.path||safePath;
    state.items=Array.isArray(data.items)?data.items:[];
    state.total=Number(data.total)||0;
    state.page=Number(data.page)||state.page;
    state.connected=true;
    $("cloud-connection-status").textContent="已連線 · "+PROVIDER_LABELS[state.activeProvider];
    $("cloud-breadcrumb").textContent=breadcrumb(state.currentPath);
    $("cloud-item-count").textContent="顯示 "+state.items.length+" / "+state.total+" 個項目";
    $("cloud-page-label").textContent="第 "+state.page+" 頁 · 共 "+Math.max(1,Math.ceil(state.total/state.perPage))+" 頁";
    $("cloud-prev-page").disabled=state.page<=1;
    $("cloud-next-page").disabled=state.page*state.perPage>=state.total;
    renderItems();
    $("cloud-browser-status").textContent="已連接 "+PROVIDER_LABELS[state.activeProvider]+"。書籍內容只會在你選擇加入本機書架時下載。";
    setSourceStatus("連線成功："+PROVIDER_LABELS[state.activeProvider]+" · "+safePath);
  } catch(error) {
    state.connected=false;
    $("cloud-items").replaceChildren();
    $("cloud-page-label").textContent="目錄尚未載入";
    $("cloud-prev-page").disabled=true;
    $("cloud-next-page").disabled=true;
    $("cloud-connection-status").textContent="連線失敗 · "+PROVIDER_LABELS[state.activeProvider];
    $("cloud-browser-status").textContent=error.message||String(error);
    setSourceStatus((error.message||String(error))+". 請檢查這一路來源的網址、Token、權限及 CORS。",true);
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
  state.busy.add(item.path);renderItems();
  $("cloud-browser-status").textContent="正在讀取 "+item.name+"……";
  try {
    let blob;
    if(state.activeProvider==="local") {
      blob=await downloadLocalFile(item.path);
    } else {
      const query=new URLSearchParams({path:item.path,provider:state.activeProvider});
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
    const record=await importBookFile(file);
    $("cloud-browser-status").textContent="已加入本機書架："+record.title+"。正在開啟閱讀室……";
    location.href="/epub-lab/?book="+encodeURIComponent(record.id);
  } catch(error) {
    $("cloud-browser-status").textContent=(error.message||String(error))+"。原始雲端檔案沒有被修改。";
    state.busy.delete(item.path);renderItems();
  }
}
$("cloud-login-form").addEventListener("submit",login);
$("cloud-refresh").addEventListener("click",()=>loadDirectory(state.currentPath,state.page));
$("cloud-prev-page").addEventListener("click",()=>loadDirectory(state.currentPath,state.page-1));
$("cloud-next-page").addEventListener("click",()=>loadDirectory(state.currentPath,state.page+1));
$("cloud-root").addEventListener("click",()=>loadDirectory(state.rootPath,1));
$("cloud-up").addEventListener("click",()=>{
  if(state.currentPath===state.rootPath)return;
  const trimmed=state.currentPath;
  const slash=trimmed.lastIndexOf("/");
  const parent=slash<=0?"/":trimmed.slice(0,slash);
  loadDirectory(parent==="/"&&state.rootPath!=="/"?state.rootPath:parent,1);
});
$("cloud-logout").addEventListener("click",logout);
$("cloud-search").addEventListener("input",event=>{state.query=event.target.value||"";renderItems();});
$("cloud-provider").addEventListener("change",event=>{
  const provider=event.target.value;
  state.connected=false;
  $("cloud-connection-status").textContent="尚未測試 · "+PROVIDER_LABELS[provider];
  setSourceStatus("已選擇 "+PROVIDER_LABELS[provider]+"。尚未連線；按「測試目前來源」後才會呼叫該來源。");
});
$("cloud-save-source").addEventListener("click",()=>{
  try { saveSourceSettings(); }
  catch(error) { setSourceStatus(error.message||String(error),true); }
});
$("cloud-test-source").addEventListener("click",async()=>{
  try {
    saveSourceSettings();
    state.currentPath=state.rootPath;
    state.query="";
    $("cloud-search").value="";
    await loadDirectory(state.rootPath,1);
  } catch(error) {
    setSourceStatus(error.message||String(error),true);
  }
});
checkSession();
