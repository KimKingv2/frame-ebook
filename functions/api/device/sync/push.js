import { json } from "../../../_lib/common.js";
import { getDeviceContext, getConfiguredSourceMap } from "../../../_lib/device-sync.js";
import { resolveReaderBook } from "../../../_lib/reader-data.js";
import {
  cleanReaderProgressPatch,
  mergeReaderBookState
} from "../../../_lib/reader-state.js";

const TYPES=new Set(["highlight","note","bookmark"]);
const PREFS=new Set(["activeProvider","activeLibrary","roots","goalMinutes","fontScale","lineHeight","verticalMargin","horizontalMargin","fontFamily","fontWeight","paragraphSpacing","textAlign","readingMode","pageLayout","comicReadingMode","comicPageLayout","comicImageFit","backdrop","theme"]);
function cleanState(input){
  if(!input||typeof input!=="object"||Array.isArray(input))throw new Error("閱讀狀態格式無效。");
  const output={};
  if(Object.prototype.hasOwnProperty.call(input,"progress")){
    output.progress=cleanReaderProgressPatch(input.progress);
  }
  if(input.appearance){if(typeof input.appearance!=="object"||Array.isArray(input.appearance))throw new Error("閱讀外觀設定格式無效。");
    const appearance={};for(const [key,value] of Object.entries(input.appearance))if(PREFS.has(key))appearance[key]=typeof value==="string"?value.slice(0,64):value;output.appearance=appearance;}
  if(input.metadata){const m=input.metadata;output.metadata={title:String(m.title||"").slice(0,240),author:String(m.author||"").slice(0,240),shelf:["books","comics"].includes(m.shelf)?m.shelf:undefined,manualTitle:!!m.manualTitle,manualAuthor:!!m.manualAuthor,language:String(m.language||"").slice(0,64),pageCount:Math.max(0,Math.min(1000000,Number(m.pageCount)||0))};}
  if(input.lastOpenedAt!=null){const value=Number(input.lastOpenedAt);if(!Number.isSafeInteger(value)||value<0)throw new Error("最後閱讀時間無效。");output.lastOpenedAt=value;}
  return output;
}
function validEvent(event){
  const seconds=Number(event?.seconds),start=Number(event?.startedAt),end=Number(event?.endedAt),hour=Number(event?.localHour);
  return !!event&&String(event.id||"").length>=8&&String(event.id||"").length<=120&&/^cloud:[a-f0-9]{64}$/.test(String(event.bookId||""))&&/^\d{4}-\d{2}-\d{2}$/.test(String(event.dayKey||""))&&Number.isInteger(seconds)&&seconds>=1&&seconds<=30&&Number.isSafeInteger(start)&&Number.isSafeInteger(end)&&end>=start&&end-start<=45000&&Number.isInteger(hour)&&hour>=0&&hour<=23;
}
async function resolveDeviceBook(db,sourceMap,raw){
  const provider=sourceMap[String(raw?.sourceId||"")];
  if(!provider)throw new Error("此 WebDAV 來源未對應到 Cloudflare 已設定的書庫。");
  const result=await resolveReaderBook(db,{id:raw.id,provider,library:raw.library,rootPath:raw.rootPath,path:raw.path});
  if(result.error)throw new Error("書籍不在 Cloudflare 書庫索引中，請先在網頁版完成掃描。");
  return result;
}
export async function onRequestPost({request,env}){
  const context=await getDeviceContext(request,env);if(context.error)return context.error;
  if(Number(request.headers.get("Content-Length")||0)>2*1024*1024)return json({error:"單次同步資料超過 2 MiB。"},413);
  let body;try{body=await request.json();}catch(_){return json({error:"同步資料格式無效。"},400);}
  const incoming=Array.isArray(body?.changes)?body.changes:[];if(!incoming.length)return json({ok:true,accepted:0});
  if(incoming.length>50)return json({error:"單次最多同步 50 筆變更。"},400);
  const sourceMap=await getConfiguredSourceMap(env),statements=[],now=Date.now();
  const stateCache = new Map();
  try{
    for(const change of incoming){
      const type=String(change?.type||"");
      if(type==="state"){
        const book=await resolveDeviceBook(context.db,sourceMap,change.book),patch=cleanState(change.state||{});
        let previousState = stateCache.get(book.bookId);
        if (!previousState) {
          const previous = await context.db.prepare(
            "SELECT state_json AS stateJson FROM reader_book_state WHERE user_id=? AND book_id=?"
          ).bind(context.userId, book.bookId).first();
          try { previousState = JSON.parse(previous?.stateJson || "{}"); }
          catch (_) { previousState = {}; }
        }
        const next = mergeReaderBookState(previousState, patch);
        const stateJson = JSON.stringify(next);
        if (stateJson.length > 24 * 1024) {
          throw new Error("單本書的閱讀狀態超過 24 KiB。");
        }
        stateCache.set(book.bookId, next);
        const patchJson = JSON.stringify(patch);
        const bookPayload = JSON.stringify({
          id: book.bookId,
          sourceId: String(change.book.sourceId),
          library: book.library,
          rootPath: book.rootPath,
          path: book.path
        });
        statements.push(context.db.prepare(
          "INSERT INTO reader_book_state " +
          "(user_id,book_id,provider,library,root_path,book_path,state_json,created_at,updated_at) " +
          "VALUES (?,?,?,?,?,?,?,?,?) " +
          "ON CONFLICT(user_id,book_id) DO UPDATE SET " +
          "provider=excluded.provider,library=excluded.library,root_path=excluded.root_path," +
          "book_path=excluded.book_path," +
          "state_json=json_patch(" +
          "CASE WHEN json_valid(reader_book_state.state_json) " +
          "THEN reader_book_state.state_json ELSE '{}' END,excluded.state_json)," +
          "updated_at=excluded.updated_at"
        ).bind(
          context.userId, book.bookId, book.provider, book.library,
          book.rootPath, book.path, patchJson, now, now
        ));
        statements.push(context.db.prepare(
          "INSERT INTO reader_sync_changes " +
          "(user_id,entity_type,entity_id,operation,payload_json,created_at) " +
          "SELECT ?,'state',?,'upsert'," +
          "json_object('book',json(?),'state',json(state_json)),? " +
          "FROM reader_book_state WHERE user_id=? AND book_id=?"
        ).bind(
          context.userId, book.bookId, bookPayload, now,
          context.userId, book.bookId
        ));
      }else if(type==="annotation"||type==="annotation_delete"){
        const book=await resolveDeviceBook(context.db,sourceMap,change.book),input=change.annotation||{},id=String(input.id||change.id||"").slice(0,120);
        if(!id)throw new Error("標註缺少識別碼。");
        if(type==="annotation"){
          const kind=String(input.type||"note"),cfi=String(input.cfi||"").slice(0,4000);
          if(!TYPES.has(kind)||!cfi)throw new Error("標註類型或 EPUB 定位資訊無效。");
          const quote=String(input.quote||"").slice(0,12000),note=String(input.text||"").slice(0,20000),color=String(input.color||"yellow").slice(0,32),created=Number(input.createdAt)||now;
          const annotation={id,bookId:book.bookId,type:kind,cfi,quote,text:note,color,createdAt:created,updatedAt:now};
          statements.push(context.db.prepare("INSERT INTO reader_annotations (user_id,book_id,annotation_id,provider,library,root_path,book_path,type,cfi,quote,note_text,color,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(user_id,book_id,annotation_id) DO UPDATE SET provider=excluded.provider,library=excluded.library,root_path=excluded.root_path,book_path=excluded.book_path,type=excluded.type,cfi=excluded.cfi,quote=excluded.quote,note_text=excluded.note_text,color=excluded.color,updated_at=excluded.updated_at")
            .bind(context.userId,book.bookId,id,book.provider,book.library,book.rootPath,book.path,kind,cfi,quote,note,color,created,now));
          statements.push(context.db.prepare("INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) VALUES (?,'annotation',?,'upsert',?,?)")
            .bind(context.userId,book.bookId+":"+id,JSON.stringify({book:{id:book.bookId,sourceId:String(change.book.sourceId),library:book.library,rootPath:book.rootPath,path:book.path},annotation}),now));
        }else{
          statements.push(context.db.prepare("DELETE FROM reader_annotations WHERE user_id=? AND book_id=? AND annotation_id=?").bind(context.userId,book.bookId,id));
          statements.push(context.db.prepare("INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) VALUES (?,'annotation',?,'delete',?,?)")
            .bind(context.userId,book.bookId+":"+id,JSON.stringify({book:{id:book.bookId,sourceId:String(change.book.sourceId),library:book.library,rootPath:book.rootPath,path:book.path},id}),now));
        }
      }else if(type==="event"){
        const event=change.event||{};if(!validEvent(event))throw new Error("閱讀事件欄位無效。");
        statements.push(context.db.prepare("INSERT OR IGNORE INTO reader_reading_events (user_id,event_id,day_key,book_id,book_title,format,seconds,started_at,ended_at,local_hour,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)")
          .bind(context.userId,String(event.id),String(event.dayKey),String(event.bookId),String(event.bookTitle||"").slice(0,240),String(event.format||"").toUpperCase().slice(0,8),Number(event.seconds),Number(event.startedAt),Number(event.endedAt),Number(event.localHour),now));
        statements.push(context.db.prepare("INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) SELECT ?,'event',?,'upsert',?,? WHERE changes()>0")
          .bind(context.userId,String(event.id),JSON.stringify(event),now));
      }else if(type==="preference"){
        const key=String(change.key||"").slice(0,80),value=change.value;
        if(!PREFS.has(key))throw new Error("不支援的閱讀偏好設定。");
        const valueJson=JSON.stringify(value);if(valueJson.length>8192)throw new Error("偏好設定資料過大。");
        statements.push(context.db.prepare("INSERT INTO reader_preferences (user_id,setting_key,value_json,updated_at) VALUES (?,?,?,?) ON CONFLICT(user_id,setting_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at")
          .bind(context.userId,key,valueJson,now));
        statements.push(context.db.prepare("INSERT INTO reader_sync_changes (user_id,entity_type,entity_id,operation,payload_json,created_at) VALUES (?,'preference',?,'upsert',?,?)")
          .bind(context.userId,key,JSON.stringify({key,value}),now));
      }else throw new Error("不支援的同步資料類型："+type);
    }
    const results=await context.db.batch(statements);
    return json({ok:true,accepted:incoming.length,statementCount:results.length});
  }catch(error){return json({error:"推送同步資料失敗："+String(error?.message||error).slice(0,180)},400);}
}
