import { json } from "../../../_lib/common.js";
import { getDeviceContext, getConfiguredSourceMap } from "../../../_lib/device-sync.js";

function parseJson(value, fallback = {}) {
  try { return JSON.parse(value); } catch (_) { return fallback; }
}

export async function onRequestGet({ request, env }) {
  const context = await getDeviceContext(request, env);
  if (context.error) return context.error;
  try {
    const cursorRow = await context.db.prepare(
      "SELECT COALESCE(MAX(change_id),0) AS cursor FROM reader_sync_changes WHERE user_id=?"
    ).bind(context.userId).first();
    const cursor = Number(cursorRow?.cursor) || 0;
    const [stateRows, annotationRows, preferenceRows, eventRows, annotationDeleteRows, sourceMap] = await Promise.all([
      context.db.prepare(
        "SELECT book_id AS bookId,provider,library,root_path AS rootPath,book_path AS path,state_json AS stateJson,updated_at AS updatedAt " +
        "FROM reader_book_state WHERE user_id=? ORDER BY updated_at,book_id LIMIT 10000"
      ).bind(context.userId).all(),
      context.db.prepare(
        "SELECT book_id AS bookId,provider,library,root_path AS rootPath,book_path AS path,annotation_id AS id,type,cfi,quote,note_text AS text,color,created_at AS createdAt,updated_at AS updatedAt " +
        "FROM reader_annotations WHERE user_id=? ORDER BY updated_at,book_id,annotation_id LIMIT 10000"
      ).bind(context.userId).all(),
      context.db.prepare(
        "SELECT setting_key AS key,value_json AS valueJson,updated_at AS updatedAt " +
        "FROM reader_preferences WHERE user_id=? ORDER BY updated_at,setting_key LIMIT 1000"
      ).bind(context.userId).all(),
      context.db.prepare(
        "SELECT event_id AS id,day_key AS dayKey,book_id AS bookId,book_title AS bookTitle,format,seconds,started_at AS startedAt,ended_at AS endedAt,local_hour AS localHour,created_at AS createdAt " +
        "FROM reader_reading_events WHERE user_id=? ORDER BY created_at,event_id LIMIT 10000"
      ).bind(context.userId).all(),
      context.db.prepare(
        "WITH ranked AS (" +
        "SELECT entity_id,operation,ROW_NUMBER() OVER (PARTITION BY entity_id ORDER BY change_id DESC) AS rn " +
        "FROM reader_sync_changes WHERE user_id=? AND entity_type='annotation' AND change_id<=?" +
        ") SELECT entity_id AS entityId FROM ranked WHERE rn=1 AND operation='delete' LIMIT 10001"
      ).bind(context.userId, cursor).all(),
      getConfiguredSourceMap(env)
    ]);
    const states=(stateRows.results||[]).map(row=>({book:{id:row.bookId,provider:row.provider,library:row.library,rootPath:row.rootPath,path:row.path},state:parseJson(row.stateJson),updatedAt:Number(row.updatedAt)||0}));
    const annotations=(annotationRows.results||[]).map(row=>({book:{id:row.bookId,provider:row.provider,library:row.library,rootPath:row.rootPath,path:row.path},annotation:{id:row.id,bookId:row.bookId,type:row.type,cfi:row.cfi,quote:row.quote||"",text:row.text||"",color:row.color||"yellow",createdAt:Number(row.createdAt)||0,updatedAt:Number(row.updatedAt)||0}}));
    const preferences=(preferenceRows.results||[]).map(row=>({key:row.key,value:parseJson(row.valueJson,null),updatedAt:Number(row.updatedAt)||0}));
    const events=(eventRows.results||[]).map(row=>({id:row.id,dayKey:row.dayKey,bookId:row.bookId,bookTitle:row.bookTitle,format:row.format,seconds:Number(row.seconds)||0,startedAt:Number(row.startedAt)||0,endedAt:Number(row.endedAt)||0,localHour:Number(row.localHour)||0,createdAt:Number(row.createdAt)||0}));
    const annotationDeletes=(annotationDeleteRows.results||[]).map(row=>String(row.entityId||""));
    const truncated={states:states.length>=10000,annotations:annotations.length>=10000,preferences:preferences.length>=1000,events:events.length>=10000,annotationDeletes:annotationDeletes.length>=10001};
    return json({ok:true,cursor,sourceMap,states,annotations,preferences,events,annotationDeletes,truncated});
  } catch(error) {
    return json({error:"建立多設備同步快照失敗："+String(error?.message||error).slice(0,180)},503);
  }
}
