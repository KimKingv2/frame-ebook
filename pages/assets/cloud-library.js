import { importBookFile } from "/assets/library-store.js";

const $ = id => document.getElementById(id);
const state = { authenticated:false, rootPath:"/", currentPath:"/", items:[], query:"", busy:new Set() };

function formatBytes(bytes) {
  const value=Number(bytes)||0;
  if(value<1024*1024)return Math.round(value/1024)+" KB";
  if(value<1024*1024*1024)return (value/(1024*1024)).toFixed(1)+" MB";
  return (value/(1024*1024*1024)).toFixed(2)+" GB";
}
function joinPath(parent,name) {
  return (String(parent||"/").replace(/\/+$/,"")+"/"+String(name||"")).replace(/^$/,"/");
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
async function checkSession() {
  try{
    const response=await fetch("/api/auth/session",{credentials:"same-origin"});
    const data=await response.json();
    state.authenticated=!!(response.ok&&data.authenticated);
    if(state.authenticated){
      state.rootPath=data.rootPath||"/";
      state.currentPath=state.rootPath;
      $("cloud-login-panel").hidden=true;
      $("cloud-browser").hidden=false;
      $("cloud-connection-status").textContent=data.openListConfigured?"OpenList 已設定":"OpenList 尚未設定";
      await loadDirectory(state.currentPath);
    }else{
      $("cloud-login-panel").hidden=false;
      $("cloud-browser").hidden=true;
    }
  }catch(error){
    $("cloud-browser-status").textContent="無法確認登入狀態："+(error.message||String(error));
  }
}
async function login(event) {
  event.preventDefault();
  const button=$("cloud-login-form").querySelector("button");
  button.disabled=true;
  $("cloud-browser-status").textContent="正在驗證私人密碼……";
  try{
    const response=await fetch("/api/auth/login",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:$("cloud-password").value})});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error||"登入失敗。");
    $("cloud-login-error").textContent="";
    $("cloud-password").value="";
    await checkSession();
  }catch(error){
    $("cloud-login-error").textContent=error.message||String(error);
  }finally{button.disabled=false;}
}
async function logout() {
  try{await fetch("/api/auth/logout",{method:"POST",credentials:"same-origin"});}catch(_){}
  state.authenticated=false;
  $("cloud-login-panel").hidden=false;
  $("cloud-browser").hidden=true;
}
async function loadDirectory(path=state.currentPath) {
  $("cloud-browser-status").textContent="正在讀取 OpenList 目錄……";
  $("cloud-refresh").disabled=true;
  try{
    const url="/api/cloud/books?path="+encodeURIComponent(path);
    const response=await fetch(url,{credentials:"same-origin"});
    const data=await response.json();
    if(!response.ok)throw new Error(data.error||"OpenList 目錄讀取失敗。");
    state.currentPath=data.path||path;
    state.items=Array.isArray(data.items)?data.items:[];
    $("cloud-breadcrumb").textContent=breadcrumb(state.currentPath);
    $("cloud-item-count").textContent=(data.total??state.items.length)+" 個項目";
    renderItems();
    $("cloud-browser-status").textContent="已連接私人 OpenList。書籍內容只會在你選擇加入本機書架時下載。";
  }catch(error){
    $("cloud-items").replaceChildren();
    $("cloud-browser-status").textContent=error.message||String(error);
  }finally{$("cloud-refresh").disabled=false;}
}
function makeItem(item) {
  const row=document.createElement("article");row.className="cloud-item";
  const icon=document.createElement("span");icon.className="cloud-item-icon";icon.textContent=item.isDir?"▰":item.format==="EPUB"?"▤":"▣";
  const copy=document.createElement("div");copy.className="cloud-item-copy";
  const title=document.createElement("strong");title.textContent=item.name;
  const meta=document.createElement("span");meta.textContent=item.isDir?"資料夾":(item.format+" · "+formatBytes(item.size)+(item.modified?" · "+String(item.modified).slice(0,10):""));
  copy.append(title,meta);
  const actions=document.createElement("div");actions.className="cloud-item-actions";
  if(item.isDir){
    const open=document.createElement("button");open.type="button";open.className="cloud-folder-button";open.textContent="開啟資料夾";
    open.addEventListener("click",()=>loadDirectory(item.path));actions.append(open);
  }else if(item.format){
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
  $("cloud-browser-status").textContent="正在透過安全下載代理讀取 "+item.name+"……";
  try{
    const response=await fetch("/api/cloud/file?path="+encodeURIComponent(item.path),{credentials:"same-origin"});
    if(!response.ok){
      const data=await response.json().catch(()=>({}));
      throw new Error(data.error||"下載失敗：HTTP "+response.status);
    }
    const blob=await response.blob();
    const mime=item.format==="EPUB"?"application/epub+zip":"application/vnd.comicbook+zip";
    const modified=Date.parse(item.modified||"")||Date.now();
    const file=new File([blob],item.name,{type:mime,lastModified:modified});
    const record=await importBookFile(file);
    $("cloud-browser-status").textContent="已加入本機書架："+record.title+"。正在開啟閱讀室……";
    location.href="/epub-lab/?book="+encodeURIComponent(record.id);
  }catch(error){
    $("cloud-browser-status").textContent=(error.message||String(error))+"。原始雲端檔案沒有被修改。";
    state.busy.delete(item.path);renderItems();
  }
}
$("cloud-login-form").addEventListener("submit",login);
$("cloud-refresh").addEventListener("click",()=>loadDirectory(state.currentPath));
$("cloud-root").addEventListener("click",()=>loadDirectory(state.rootPath));
$("cloud-up").addEventListener("click",()=>{
  if(state.currentPath===state.rootPath)return;
  const trimmed=state.currentPath.replace(/\\/+$/,"");
  const slash=trimmed.lastIndexOf("/");
  const parent=slash<=0?"/":trimmed.slice(0,slash);
  loadDirectory(parent==="/"&&state.rootPath!=="/"?state.rootPath:parent);
});
$("cloud-logout").addEventListener("click",logout);
$("cloud-search").addEventListener("input",event=>{state.query=event.target.value||"";renderItems();});
checkSession();
