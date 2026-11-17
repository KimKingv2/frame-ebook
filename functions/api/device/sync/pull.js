import { json } from "../../../_lib/common.js";
import { getDeviceContext } from "../../../_lib/device-sync.js";

export async function onRequestGet({ request, env }) {
  const context=await getDeviceContext(request,env);
  if(context.error)return context.error;
  const url=new URL(request.url);
  const cursor=Math.max(0,Number(url.searchParams.get("cursor"))||0);
  const limit=Math.max(1,Math.min(500,Number(url.searchParams.get("limit"))||250));
  try{
    const result=await context.db.prepare(
      "SELECT change_id AS changeId,entity_type AS entityType,entity_id AS entityId,operation,payload_json AS payloadJson,created_at AS createdAt " +
      "FROM reader_sync_changes WHERE user_id=? AND change_id>? ORDER BY change_id ASC LIMIT ?"
    ).bind(context.userId,cursor,limit+1).all();
    const rows=result.results||[],hasMore=rows.length>limit;
    const changes=rows.slice(0,limit).map(row=>{
      let payload={};try{payload=JSON.parse(row.payloadJson||"{}");}catch(_){}
      return {cursor:Number(row.changeId),entityType:row.entityType,entityId:row.entityId,operation:row.operation,payload,createdAt:Number(row.createdAt)||0};
    });
    return json({ok:true,changes,hasMore,cursor:changes.length?changes[changes.length-1].cursor:cursor});
  }catch(error){
    return json({error:"讀取增量同步資料失敗："+String(error?.message||error).slice(0,160)},503);
  }
}
