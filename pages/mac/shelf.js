import { ZipReader, BlobWriter, TextWriter } from "/vendor/foliate-js/vendor/zip.js";

const $ = id => document.getElementById(id);
const COVER_LIMIT = 2 * 1024 * 1024;
const IMAGE_EXT = /\.(?:jpe?g|png|webp|gif|bmp|avif)$/i;
const clean = (value, fallback = "") => String(value == null ? "" : value).trim() || fallback;
const natural = (a, b) => String(a || "").localeCompare(String(b || ""), "zh-Hant", { numeric: true, sensitivity: "base" });
const fileName = book => clean(book.fileName || book.cloudSource?.path?.split("/").pop(), "未命名檔案");
const formatOf = book => String(book.format || (fileName(book).toLowerCase().endsWith(".cbz") ? "CBZ" : "EPUB")).toUpperCase();
const kindOf = book => formatOf(book) === "CBZ" || book.shelf === "comics" || book.library === "comics" ? "comics" : "books";
const parentOf = path => {
  const value = String(path || "/").replace(/\\/g, "/").replace(/\/+$/, "");
  const index = value.lastIndexOf("/");
  return index <= 0 ? "/" : value.slice(0, index) + "/";
};
const lastPart = path => String(path || "/").split("/").filter(Boolean).pop() || "根目錄";
function sizeLabel(value) {
  const bytes = Number(value) || 0;
  if (bytes < 1024 * 1024) return Math.max(1, Math.round(bytes / 1024)) + " KB";
  if (bytes >= 1024 * 1024 * 1024) return (bytes / 1024 / 1024 / 1024).toFixed(2) + " GB";
  return (bytes / 1024 / 1024).toFixed(1) + " MB";
}
function zipPath(value) {
  let path = String(value || "").split("#")[0].split("?")[0].replace(/\\/g, "/");
  try { path = decodeURIComponent(path); } catch (_) {}
  const parts = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop(); else parts.push(part);
  }
  return parts.join("/");
}
function relativeZipPath(base, href) { return zipPath((base ? base + "/" : "") + String(href || "")); }
function mimeFromName(name) {
  const ext = String(name || "").split(".").pop().toLowerCase();
  return ({ jpg:"image/jpeg",jpeg:"image/jpeg",png:"image/png",webp:"image/webp",gif:"image/gif",bmp:"image/bmp",avif:"image/avif" })[ext] || "image/jpeg";
}
class NativeRangeReader {
  constructor(profileId, path, size, invoke) {
    this.profileId = String(profileId || "");
    this.path = String(path || "");
    this.size = Number(size) || 0;
    this.invoke = invoke;
    this.initialized = false;
    this.rangeCount = 0;
    this.bytesRead = 0;
  }
  async init() { this.initialized = true; }
  async readUint8Array(offset, length) {
    const start = Math.max(0, Number(offset) || 0);
    const count = Math.max(0, Number(length) || 0);
    if (!count || start >= this.size) return new Uint8Array();
    const expected = Math.min(count, this.size - start);
    const raw = await this.invoke("webdav_read_range", { profileId:this.profileId, path:this.path, start, length:expected });
    let bytes;
    if (raw instanceof ArrayBuffer) bytes = new Uint8Array(raw);
    else if (ArrayBuffer.isView(raw)) bytes = new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
    else throw new Error("原生 WebDAV Range 通道沒有回傳二進位資料。");
    if (bytes.byteLength !== expected) throw new Error("封面 Range 長度不符：預期 " + expected + " bytes，實際 " + bytes.byteLength + " bytes。");
    this.rangeCount++;
    this.bytesRead += bytes.byteLength;
    return bytes;
  }
  get readable() {
    const reader = this;
    let stream;
    let chunkOffset = 0;
    stream = new ReadableStream({
      async pull(controller) {
        try {
          const offset = Math.max(0, Number(stream.offset) || 0);
          const size = Number(stream.size);
          if (!Number.isSafeInteger(size) || size < 0) throw new Error("ZIP 封面串流缺少有效長度。");
          const remaining = size - chunkOffset;
          if (remaining <= 0) { controller.close(); return; }
          const length = Math.min(65536, remaining);
          const bytes = await reader.readUint8Array(offset + chunkOffset, length);
          if (!bytes.byteLength) throw new Error("ZIP 封面 Range 回傳空資料。");
          controller.enqueue(bytes);
          chunkOffset += bytes.byteLength;
          if (chunkOffset >= size) controller.close();
        } catch (error) { controller.error(error); }
      }
    });
    return stream;
  }
}
async function findEpubCover(entries) {
  const byName = new Map(entries.filter(entry => !entry.directory).map(entry => [zipPath(entry.filename), entry]));
  const container = byName.get("META-INF/container.xml");
  if (!container) return null;
  const containerText = await container.getData(new TextWriter("utf-8"));
  const containerXml = new DOMParser().parseFromString(String(containerText || ""), "application/xml");
  if (containerXml.getElementsByTagName("parsererror").length) return null;
  const rootfile = containerXml.getElementsByTagName("rootfile")[0];
  const opfPath = zipPath(rootfile?.getAttribute("full-path") || "");
  const opfEntry = opfPath ? byName.get(opfPath) : null;
  if (!opfEntry) return null;
  const opfText = await opfEntry.getData(new TextWriter("utf-8"));
  const opfXml = new DOMParser().parseFromString(String(opfText || ""), "application/xml");
  if (opfXml.getElementsByTagName("parsererror").length) return null;
  const manifest = Array.from(opfXml.getElementsByTagName("item"));
  const metas = Array.from(opfXml.getElementsByTagName("meta"));
  let coverId = "";
  for (const meta of metas) {
    const name = String(meta.getAttribute("name") || "").toLowerCase();
    const property = String(meta.getAttribute("property") || "").toLowerCase();
    if (name === "cover" || property === "cover-image") {
      coverId = String(meta.getAttribute("content") || "").trim();
      if (coverId) break;
    }
  }
  let item = coverId ? manifest.find(node => node.getAttribute("id") === coverId) : null;
  if (!item) item = manifest.find(node => (node.getAttribute("properties") || "").split(/\s+/).includes("cover-image"));
  if (!item) item = manifest.find(node => /^image\//i.test(node.getAttribute("media-type") || "") && /cover|front/i.test(node.getAttribute("href") || ""));
  const base = opfPath.includes("/") ? opfPath.slice(0, opfPath.lastIndexOf("/")) : "";
  const coverName = item ? relativeZipPath(base, item.getAttribute("href")) : "";
  const entry = coverName ? byName.get(coverName) : null;
  if (entry) {
    const mime = String(item.getAttribute("media-type") || mimeFromName(coverName)).toLowerCase();
    if (mime.startsWith("image/") && mime !== "image/svg+xml") return { entry, mime };
  }
  const images = entries.filter(entry => !entry.directory && IMAGE_EXT.test(entry.filename) &&
    !/(^|\/)(__MACOSX|\.AppleDouble)\//i.test(entry.filename) && !/(^|\/)\._/.test(entry.filename));
  images.sort((a,b) => natural(a.filename,b.filename));
  const fallback = images.find(entry => /(^|[/_-])(cover|front)([/_.-]|$)/i.test(entry.filename)) || images[0];
  return fallback ? { entry:fallback, mime:mimeFromName(fallback.filename) } : null;
}
function findCbzCover(entries) {
  const images = entries.filter(entry => !entry.directory && IMAGE_EXT.test(entry.filename) &&
    !/(^|\/)(__MACOSX|\.AppleDouble)\//i.test(entry.filename) && !/(^|\/)\._/.test(entry.filename));
  images.sort((a,b) => natural(a.filename,b.filename));
  const cover = images.find(entry => /(^|[/_-])(cover|front)([/_.-]|$)/i.test(entry.filename)) || images[0];
  return cover ? { entry:cover, mime:mimeFromName(cover.filename) } : null;
}
async function makeThumbnail(blob) {
  if (!(blob instanceof Blob) || !blob.size || blob.size > 15 * 1024 * 1024) return null;
  let bitmap;
  try {
    bitmap = await createImageBitmap(blob);
    const width = bitmap.width || bitmap.displayWidth, height = bitmap.height || bitmap.displayHeight;
    if (!width || !height || width * height > 150000000) return null;
    const scale = Math.min(1, 480 / Math.max(width,height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    const context = canvas.getContext("2d", { alpha:false });
    if (!context) return null;
    context.drawImage(bitmap,0,0,canvas.width,canvas.height);
    let output = await new Promise(resolve => canvas.toBlob(resolve,"image/webp",0.82));
    if (!output || !output.size || output.size > COVER_LIMIT) output = await new Promise(resolve => canvas.toBlob(resolve,"image/jpeg",0.82));
    return output && output.size && output.size <= COVER_LIMIT ? output : null;
  } finally { try { bitmap?.close(); } catch (_) {} }
}

export function createMacShelf({ store, invoke, appendLog, setStatus, openBook, getProfileId, isProfileUnlocked }) {
  const state = { books:[], query:"", sort:"recent", view:"grid", activeFolderKey:null };
  const objectUrls = [];
  const attemptedCovers = new Set();
  const coverJobs = new Map();
  let coverQueuePromise = null;

  function clearObjectUrls() {
    while (objectUrls.length) { try { URL.revokeObjectURL(objectUrls.pop()); } catch (_) {} }
  }
  function imageUrl(blob) {
    if (!(blob instanceof Blob) || !blob.size) return "";
    const url = URL.createObjectURL(blob); objectUrls.push(url); return url;
  }
  function fallback(title, format) {
    const node = document.createElement("div"); node.className = "book-cover-fallback";
    const top = document.createElement("span"); top.className = "book-cover-fallback-top"; top.textContent = "FRAME READER";
    const name = document.createElement("strong"); name.textContent = clean(title,"未命名書籍");
    const bottom = document.createElement("small"); bottom.textContent = String(format).toUpperCase() === "CBZ" ? "COMIC EDITION" : "READING EDITION";
    node.append(top,name,bottom); return node;
  }
  function addImage(host, book, allowFallback = true) {
    if (book.coverBlob instanceof Blob && book.coverBlob.size) {
      const image = document.createElement("img"); image.className = "book-cover-image";
      image.src = imageUrl(book.coverBlob); image.alt = fileName(book) + " 封面";
      image.loading = "lazy"; image.decoding = "async";
      image.addEventListener("error",() => { image.remove(); if (allowFallback) host.appendChild(fallback(book.title || fileName(book),formatOf(book))); },{once:true});
      host.appendChild(image);
    } else if (allowFallback) host.appendChild(fallback(book.title || fileName(book),formatOf(book)));
  }
  function folderPath(book) {
    const source = book.cloudSource || {};
    return clean(source.folderPath,parentOf(source.path || book.path || "/"));
  }
  function folderKey(book) {
    const source = book.cloudSource || {};
    return [source.provider || book.provider || "webdav",source.profileId || book.profileId || "",
      source.library || book.library || kindOf(book),source.rootPath || book.rootPath || "/",folderPath(book)].join("\n");
  }
  function groups() {
    const map = new Map();
    for (const book of state.books) {
      const key = folderKey(book), source = book.cloudSource || {};
      let group = map.get(key);
      if (!group) {
        const path = folderPath(book);
        group = { key,path,title:clean(source.folderTitle,lastPart(path)),library:kindOf(book),profileId:source.profileId || book.profileId || "",
          members:[],size:0,lastOpenedAt:0,addedAt:0,progress:0 };
        map.set(key,group);
      }
      group.members.push(book);
      group.size += Math.max(0,Number(book.size)||0);
      group.lastOpenedAt = Math.max(group.lastOpenedAt,Number(book.lastOpenedAt)||0);
      group.addedAt = Math.max(group.addedAt,Number(book.addedAt)||0);
      group.progress = Math.max(group.progress,Number(book.progress?.percent)||0);
    }
    return [...map.values()].map(group => {
      group.members.sort((a,b) => natural(fileName(a),fileName(b)));
      return group;
    });
  }
  function filteredGroups() {
    const query = state.query.trim().toLocaleLowerCase();
    const result = groups().filter(group => {
      if (!query) return true;
      const memberText = group.members.map(book => [book.title,book.author,fileName(book),formatOf(book)].join(" ")).join(" ");
      return [group.title,group.path,memberText].join(" ").toLocaleLowerCase().includes(query);
    });
    result.sort((a,b) => {
      if (state.sort === "title") return natural(a.title,b.title);
      if (state.sort === "added") return b.addedAt-a.addedAt || natural(a.title,b.title);
      if (state.sort === "progress") return b.progress-a.progress || natural(a.title,b.title);
      return b.lastOpenedAt-a.lastOpenedAt || natural(a.title,b.title);
    });
    return result;
  }
  function openFolder(group) {
    state.activeFolderKey = group.key; render();
    $("folder-detail")?.scrollIntoView({behavior:"smooth",block:"start"});
  }
  function folderCover(group) {
    const cover = document.createElement("button"); cover.type = "button"; cover.className = "book-cover folder-cover";
    cover.setAttribute("aria-label","開啟資料夾 " + group.title); cover.addEventListener("click",() => openFolder(group));
    const members = group.members.slice(0,3);
    if (members.length > 1) {
      const stack = document.createElement("div"); stack.className = "folder-cover-stack";
      const visual = members.length === 3 ? [members[1],members[0],members[2]] : [members[1],members[0]];
      visual.forEach(member => {
        const sheet = document.createElement("div"); sheet.className = "folder-cover-sheet";
        if (member.coverBlob instanceof Blob && member.coverBlob.size) {
          const image = document.createElement("img"); image.src = imageUrl(member.coverBlob);
          image.alt = fileName(member) + " 封面"; image.loading="lazy"; image.decoding="async";
          image.addEventListener("error",() => { image.remove(); sheet.classList.add("is-fallback"); },{once:true});
          sheet.appendChild(image);
        } else {
          sheet.classList.add("is-fallback");
          const label = document.createElement("span"); label.textContent = fileName(member).replace(/\.(epub|cbz)$/i,"");
          sheet.appendChild(label);
        }
        stack.appendChild(sheet);
      });
      cover.appendChild(stack);
    } else if (members.length === 1) {
      addImage(cover,members[0],false);
      if (!(members[0].coverBlob instanceof Blob)) cover.classList.add("folder-cover-empty");
    } else cover.appendChild(fallback(group.title,group.library === "comics" ? "CBZ":"EPUB"));
    const badge = document.createElement("span"); badge.className="book-cover-badge"; badge.textContent=members.length+" 冊"; cover.appendChild(badge);
    return cover;
  }
  function folderCard(group, compact = false) {
    const card = document.createElement("article"); card.className="book-card folder-card"+(compact?" is-compact":"");
    card.appendChild(folderCover(group));
    const info=document.createElement("div"); info.className="book-info";
    const title=document.createElement("h3"); title.textContent=group.title;
    const desc=document.createElement("p"); desc.textContent=group.members.length+" 本作品 · "+group.path;
    const meta=document.createElement("div"); meta.className="book-meta";
    const type=document.createElement("span"); type.textContent=group.library==="comics"?"漫畫資料夾":"電子書資料夾";
    const size=document.createElement("span"); size.textContent=sizeLabel(group.size); meta.append(type,size);
    const actions=document.createElement("div"); actions.className="book-actions";
    const open=document.createElement("button"); open.type="button"; open.className="button primary"; open.textContent="開啟資料夾 ↗";
    open.addEventListener("click",()=>openFolder(group)); actions.appendChild(open);
    info.append(title,desc,meta,actions); card.appendChild(info); return card;
  }
  function volumeCard(book) {
    const card=document.createElement("article"); card.className="book-card volume-card";
    const cover=document.createElement("button"); cover.type="button"; cover.className="book-cover volume-cover";
    cover.setAttribute("aria-label","閱讀 "+fileName(book)); cover.addEventListener("click",()=>openBook(book));
    addImage(cover,book,true);
    const badge=document.createElement("span"); badge.className="book-cover-badge"; badge.textContent=formatOf(book); cover.appendChild(badge);
    const info=document.createElement("div"); info.className="book-info";
    const title=document.createElement("h3"); title.textContent=clean(book.title,fileName(book).replace(/\.(epub|cbz)$/i,""));
    const author=document.createElement("p"); author.textContent=clean(book.author,formatOf(book)==="CBZ"?"漫畫／圖像書":"作者未提供");
    const meta=document.createElement("div"); meta.className="book-meta";
    const progress=Number(book.progress?.percent)||0;
    const progressLabel=document.createElement("span"); progressLabel.textContent=progress>0?Math.round(progress)+"% 已讀":"尚未開始";
    const size=document.createElement("span"); size.textContent=sizeLabel(book.size); meta.append(progressLabel,size);
    const file=document.createElement("small"); file.className="volume-filename"; file.textContent=fileName(book);
    const actions=document.createElement("div"); actions.className="book-actions";
    const open=document.createElement("button"); open.type="button"; open.className="button primary"; open.textContent=progress>0?"繼續閱讀":"開始閱讀";
    open.addEventListener("click",()=>openBook(book));
    const remove=document.createElement("button"); remove.type="button"; remove.className="button subtle"; remove.textContent="移除";
    remove.addEventListener("click",async()=>{
      try { await store.removeLocalBook(book.id); appendLog("INFO","書籍已從本機書架移除",fileName(book)); await refresh({prefetch:false}); setStatus("已從本機書架移除 · "+fileName(book)); }
      catch(error){setStatus(error.message||String(error),true);}
    });
    actions.append(open,remove); info.append(title,author,meta,file,actions); card.append(cover,info); return card;
  }
  function renderCategory(items,hostId,emptyId) {
    const host=$(hostId),empty=$(emptyId); host.replaceChildren(); host.classList.toggle("is-list",state.view==="list");
    items.forEach(group=>host.appendChild(folderCard(group)));
    host.hidden=items.length===0; empty.hidden=items.length!==0;
  }
  function renderFolder(groupsNow) {
    const folder=groupsNow.find(group=>group.key===state.activeFolderKey),active=!!folder;
    $("shelf-overview").hidden=active; $("folder-detail").hidden=!active;
    const hero=document.querySelector(".hero"), tabs=document.querySelector(".tabs");
    if(hero)hero.hidden=active; if(tabs)tabs.hidden=active;
    if(!active){state.activeFolderKey=null;return;}
    $("folder-detail-title").textContent=folder.title;
    $("folder-detail-path").textContent=folder.path;
    $("folder-detail-count").textContent=folder.members.length+" 冊 · "+sizeLabel(folder.size);
    $("folder-detail-status").textContent="這個資料夾共有 "+folder.members.length+" 個可閱讀檔案。封面由 WebDAV Range 擷取，原始書檔不會下載到磁碟。";
    const host=$("folder-books-grid"); host.replaceChildren();
    folder.members.forEach(book=>host.appendChild(volumeCard(book)));
    $("folder-detail-empty").hidden=folder.members.length>0;
  }
  function render() {
    clearObjectUrls();
    const all=groups(),visible=filteredGroups();
    const books=all.filter(group=>group.library==="books"),comics=all.filter(group=>group.library==="comics");
    const started=all.filter(group=>group.members.some(book=>Number(book.progress?.percent)>0)).length;
    $("shelf-folder-count").textContent=String(all.length).padStart(2,"0");
    $("shelf-started-count").textContent=String(started).padStart(2,"0");
    $("shelf-books-count").textContent=String(books.length).padStart(2,"0");
    $("shelf-comics-count").textContent=String(comics.length).padStart(2,"0");
    $("shelf-count-label").textContent=all.length+" 個資料夾";
    $("shelf-result-count").textContent="目前顯示 "+visible.filter(group=>group.library==="books").length+" 個電子書資料夾 · "+
      visible.filter(group=>group.library==="comics").length+" 個漫畫資料夾";
    $("shelf-empty").hidden=all.length>0;
    const recent=all.filter(group=>group.lastOpenedAt>0).sort((a,b)=>b.lastOpenedAt-a.lastOpenedAt).slice(0,3);
    const recentGrid=$("recent-grid"); recentGrid.replaceChildren();
    recent.forEach(group=>recentGrid.appendChild(folderCard(group,true)));
    $("recent-section").hidden=recent.length===0||!!state.activeFolderKey;
    renderCategory(visible.filter(group=>group.library==="books"),"books-grid","books-empty");
    renderCategory(visible.filter(group=>group.library==="comics"),"comics-grid","comics-empty");
    $("shelf-grid-view").setAttribute("aria-pressed",state.view==="grid"?"true":"false");
    $("shelf-list-view").setAttribute("aria-pressed",state.view==="list"?"true":"false");
    renderFolder(all);
  }
  async function extractAndSaveCover(book) {
    if(!book||book.coverBlob instanceof Blob||attemptedCovers.has(String(book.id)))return false;
    const source=book.cloudSource||{},profileId=String(source.profileId||book.profileId||"");
    if(!profileId||!isProfileUnlocked(profileId)||!String(source.path||book.path||""))return false;
    const size=Number(book.size)||0;
    if(!Number.isSafeInteger(size)||size<=0)return false;
    const path=String(source.path||book.path),format=formatOf(book);
    if(format!=="EPUB"&&format!=="CBZ")return false;
    attemptedCovers.add(String(book.id));
    const started=performance.now();let zip;
    try{
      const reader=new NativeRangeReader(profileId,path,size,invoke);
      zip=new ZipReader(reader,{useWebWorkers:false,useCompressionStream:true});
      const entries=await zip.getEntries();
      const found=format==="CBZ"?findCbzCover(entries):await findEpubCover(entries);
      if(!found){appendLog("WARN","封面索引未找到可用圖片",path+" · Range "+reader.rangeCount+" 次");return false;}
      const original=await found.entry.getData(new BlobWriter(found.mime));
      const thumbnail=await makeThumbnail(original);
      if(!thumbnail){appendLog("WARN","封面縮圖略過",path+" · 原始封面 "+sizeLabel(original.size));return false;}
      await store.saveLocalBookCover(book.id,thumbnail);
      appendLog("INFO","書架封面已預先擷取",path+"\nRange 次數："+reader.rangeCount+"\nRange 實收："+sizeLabel(reader.bytesRead)+
        "\n縮圖："+sizeLabel(thumbnail.size)+"\n耗時："+Math.round(performance.now()-started)+" ms；原始書檔未下載");
      return true;
    }catch(error){appendLog("WARN","書架封面擷取失敗",path+"\n"+(error.message||String(error)));return false;}
    finally{try{await zip?.close?.();}catch(_){}}
  }
  async function ensureCover(book){
    const id=String(book?.id||"");if(!id)return false;
    if(coverJobs.has(id))return coverJobs.get(id);
    const job=extractAndSaveCover(book).finally(()=>coverJobs.delete(id));coverJobs.set(id,job);
    const saved=await job;
    if(saved){state.books=await store.listBooks();render();}
    return saved;
  }
  async function prefetchCovers(){
    if(coverQueuePromise)return coverQueuePromise;
    coverQueuePromise=(async()=>{
      const active=String(getProfileId()||"");
      if(!active||!isProfileUnlocked(active))return;
      const missing=state.books.filter(book=>{
        const source=book.cloudSource||{},id=String(book.id||"");
        return String(source.profileId||book.profileId||"")===active&&!(book.coverBlob instanceof Blob)&&!attemptedCovers.has(id);
      });
      for(let index=0;index<missing.length;index+=2){
        await Promise.all(missing.slice(index,index+2).map(book=>ensureCover(book)));
      }
      if(missing.length)appendLog("INFO","書架封面預載完成","已檢查 "+missing.length+" 本書；封面會在閱讀前載入。");
    })().finally(()=>{coverQueuePromise=null;});
    return coverQueuePromise;
  }
  async function refresh({prefetch=true}={}){
    state.books=await store.listBooks();render();
    if(prefetch)void prefetchCovers();
    return state.books;
  }
  $("shelf-search").addEventListener("input",event=>{state.query=event.target.value||"";render();});
  $("shelf-sort").addEventListener("change",event=>{state.sort=event.target.value||"recent";render();});
  $("shelf-grid-view").addEventListener("click",()=>{state.view="grid";render();});
  $("shelf-list-view").addEventListener("click",()=>{state.view="list";render();});
  $("folder-detail-back").addEventListener("click",()=>{
    state.activeFolderKey=null;render();$("shelf-overview").scrollIntoView({behavior:"smooth",block:"start"});
  });
  $("shelf-refresh").addEventListener("click",()=>refresh({prefetch:true}).catch(error=>setStatus(error.message||String(error),true)));
  return {refresh,render,prefetchCovers};
}
