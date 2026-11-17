const STORAGE_KEY = "frame-reader-local-openlist-base-url";
let connection = { baseUrl: "", token: "" };
const fileInfoCache = new Map();

function addressSpace(urlValue) {
  try {
    const url = new URL(String(urlValue || ""));
    const host = url.hostname.toLowerCase();
    if (host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host.startsWith("127.")) return "loopback";
    const m = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (!m) return "";
    const [a,b] = [Number(m[1]),Number(m[2])];
    if (a===10 || (a===172 && b>=16 && b<=31) || (a===192 && b===168) || (a===169 && b===254)) return "local";
  } catch {}
  return "";
}
function fetchAddressOptions(url) {
  const targetAddressSpace = addressSpace(url);
  return targetAddressSpace ? { targetAddressSpace } : {};
}
export function normalizeLocalOpenListUrl(value) {
  let url;
  try { url = new URL(String(value || "").trim()); }
  catch { throw new Error("本地 OpenList 網址格式不正確。"); }
  if (!["https:","http:"].includes(url.protocol)) throw new Error("本地 OpenList 網址必須使用 HTTP 或 HTTPS。");
  if (url.protocol === "http:" && !addressSpace(url.href)) {
    throw new Error("HTTP 僅允許 localhost 或私有區域網路 IPv4；其他網域請使用 HTTPS。");
  }
  if (url.username || url.password || url.search || url.hash) throw new Error("OpenList 網址不可包含帳密、查詢參數或片段。");
  return url.origin + url.pathname.replace(/\/+$/,"");
}
export function getSavedLocalOpenListBaseUrl() {
  try { return normalizeLocalOpenListUrl(localStorage.getItem(STORAGE_KEY) || ""); }
  catch { return ""; }
}
function saveBaseUrl(baseUrl) {
  try { localStorage.setItem(STORAGE_KEY, baseUrl); } catch {}
}
function requireConnection() {
  if (!connection.baseUrl || !connection.token) throw new Error("本地 OpenList 尚未登入，請重新輸入帳號與密碼。");
  return connection;
}
async function parseOpenListResponse(response, operation) {
  let payload = {};
  try { payload = await response.json(); }
  catch { throw new Error("本地 OpenList " + operation + " 回應不是有效 JSON（HTTP " + response.status + "）。"); }
  if (!response.ok || Number(payload?.code) !== 200 || !payload?.data) {
    const reason = String(payload?.message || payload?.error || "");
    if (response.status === 401 || Number(payload?.code) === 401) {
      connection.token = "";
      fileInfoCache.clear();
      throw new Error("本地 OpenList 登入已失效，請重新登入。");
    }
    throw new Error("本地 OpenList " + operation + " 失敗（HTTP " + response.status + "）" + (reason ? "：" + reason : "。"));
  }
  return payload.data;
}
async function postApi(endpoint, body, timeoutMs=45000) {
  const active = requireConnection();
  const target = new URL("api/fs/" + endpoint, active.baseUrl + "/").href;
  const controller = new AbortController();
  const timeout = setTimeout(()=>controller.abort(),Math.max(1000,Math.min(180000,Number(timeoutMs)||45000)));
  try {
    const response = await fetch(target,{
      method:"POST",mode:"cors",credentials:"omit",redirect:"error",
      headers:{Authorization:active.token,"Content-Type":"application/json"},
      body:JSON.stringify(body),signal:controller.signal,
      ...fetchAddressOptions(target)
    });
    return await parseOpenListResponse(response,endpoint);
  } catch(error) {
    if(error?.name==="AbortError")throw new Error("本地 OpenList "+endpoint+" 請求逾時。");
    if(/登入已失效|失敗（HTTP|有效 JSON/.test(String(error?.message||"")))throw error;
    throw new Error("無法直接連接本地 OpenList。請檢查服務是否啟動、網址、CORS（Authorization／Content-Type）及瀏覽器本機網路存取權限。"+(error?.message?" 詳情："+String(error.message).slice(0,140):""));
  } finally { clearTimeout(timeout); }
}
export async function loginLocalOpenList({baseUrl,username,password}) {
  const normalized = normalizeLocalOpenListUrl(baseUrl);
  const user = String(username||"").trim();
  const secret = String(password||"");
  if(!user||!secret)throw new Error("請輸入本地 OpenList 帳號與密碼。");
  const target = new URL("api/auth/login",normalized+"/").href;
  const controller = new AbortController();
  const timeout=setTimeout(()=>controller.abort(),20000);
  try {
    const response=await fetch(target,{
      method:"POST",mode:"cors",credentials:"omit",redirect:"error",
      headers:{"Content-Type":"application/json"},
      body:JSON.stringify({username:user,password:secret}),signal:controller.signal,
      ...fetchAddressOptions(target)
    });
    let payload={};
    try{payload=await response.json();}catch{throw new Error("本地 OpenList 登入回應不是有效 JSON。");}
    const token=String(payload?.data?.token||"");
    if(!response.ok||Number(payload?.code)!==200||!token) {
      throw new Error("本地 OpenList 登入失敗（HTTP "+response.status+"）"+(payload?.message?"："+String(payload.message):"。請檢查帳號與密碼。"));
    }
    connection={baseUrl:normalized,token};
    fileInfoCache.clear();
    saveBaseUrl(normalized);
    return {baseUrl:normalized};
  }catch(error){
    if(error?.name==="AbortError")throw new Error("本地 OpenList 登入逾時。");
    if(/登入失敗|不是有效 JSON/.test(String(error?.message||"")))throw error;
    throw new Error("無法連接本地 OpenList 登入 API。請檢查網址、CORS、本機網路權限及 HTTPS／VPN 設定。"+(error?.message?" 詳情："+String(error.message).slice(0,140):""));
  }finally{clearTimeout(timeout);}
}
export function isLocalOpenListReady(){return !!(connection.baseUrl&&connection.token);}
export function logoutLocalOpenList(){connection={baseUrl:"",token:""};fileInfoCache.clear();}
export async function listLocalOpenListDirectory(path,page=1,perPage=100){
  const safePath=String(path||"/");
  if(!safePath.startsWith("/")||safePath.includes("\0"))throw new Error("本地 OpenList 目錄路徑無效。");
  const data=await postApi("list",{path:safePath,password:"",page:Math.max(1,Number(page)||1),per_page:Math.max(1,Math.min(500,Number(perPage)||100)),refresh:false},45000);
  const content=Array.isArray(data.content)?data.content:[];
  return {
    provider:"local",path:safePath,page:Number(data.page)||page,perPage:Number(data.per_page)||perPage,
    total:Math.max(0,Number(data.total)||content.length),
    items:content.map(item=>({
      name:String(item?.name||""),path:(safePath.replace(/\/+$/,"")+"/"+String(item?.name||"")).replace(/^$/,"/"),
      parentPath:safePath,isDir:!!item?.is_dir,size:Math.max(0,Number(item?.size)||0),
      modified:item?.modified||item?.created||null
    })).filter(item=>item.name&&!item.name.includes("/")&&!item.name.includes("\\"))
  };
}
async function getLocalFileInfo(path){
  const key=String(path||"");
  if(fileInfoCache.has(key))return fileInfoCache.get(key);
  const data=await postApi("get",{path:key,password:"",page:1,per_page:0,refresh:false},45000);
  if(!data||data.is_dir||!data.raw_url)throw new Error("本地 OpenList 沒有提供檔案下載位址。");
  const rawUrl=new URL(String(data.raw_url),connection.baseUrl+"/");
  if(!["http:","https:"].includes(rawUrl.protocol)||rawUrl.username||rawUrl.password)throw new Error("本地 OpenList 回傳的檔案位址無效。");
  const info={...data,rawUrl:rawUrl.href};
  fileInfoCache.set(key,info);
  return info;
}
export async function fetchLocalFileRange(path,start,end){
  const info=await getLocalFileInfo(path);
  const response=await fetch(info.rawUrl,{
    method:"GET",mode:"cors",credentials:"omit",redirect:"follow",
    headers:{Range:"bytes="+start+"-"+end},
    ...fetchAddressOptions(info.rawUrl)
  });
  return response;
}
export async function fetchLocalFileBlob(path){
  const info=await getLocalFileInfo(path);
  const response=await fetch(info.rawUrl,{
    method:"GET",mode:"cors",credentials:"omit",redirect:"follow",
    ...fetchAddressOptions(info.rawUrl)
  });
  if(!response.ok)throw new Error("本地 OpenList 檔案下載失敗（HTTP "+response.status+"）。");
  return response.blob();
}
