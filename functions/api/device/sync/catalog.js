import { json } from "../../../_lib/common.js";
import { getDeviceContext, getConfiguredSourceMap } from "../../../_lib/device-sync.js";
import { readerBookIdForFilename } from "../../../_lib/reader-data.js";

export async function onRequestGet({ request, env }) {
  const context=await getDeviceContext(request,env);
  if(context.error)return context.error;
  const sourceId=String(new URL(request.url).searchParams.get("source_id")||"");
  const provider=(await getConfiguredSourceMap(env))[sourceId];
  if(!provider)return json({error:"這個 WebDAV 來源尚未對應到 Cloudflare 已設定的伺服器端書庫。請確認 Mac 與 Cloudflare 使用相同的 AList 網域和唯讀帳號。"},403);
  try{
    const result=await context.db.prepare(
      "SELECT provider,library,root_path AS rootPath,path,parent_path AS parentPath,name,format,size_bytes AS size,modified_at AS modifiedAt,"+
      "cover_hash AS coverHash,cover_type AS coverType,cover_status AS coverStatus,"+
      "book_title AS bookTitle,book_creator AS bookCreator,book_language AS language,book_description AS description,"+
      "book_publisher AS publisher,book_date AS publishedAt,book_identifier AS identifier,book_subjects_json AS subjectsJson "+
      "FROM cloud_catalog WHERE provider=? AND is_dir=0 AND format IN ('EPUB','CBZ') ORDER BY library,path LIMIT 10000"
    ).bind(provider).all();
    const items=[];
    for(const row of result.results||[]){
      const id=await readerBookIdForFilename(row.name);
      let subjects=[];try{subjects=JSON.parse(row.subjectsJson||"[]");}catch(_){}
      items.push({id,provider:row.provider,sourceId,library:row.library,rootPath:row.rootPath,path:row.path,parentPath:row.parentPath,
        fileName:row.name,title:row.bookTitle||String(row.name).replace(/\.(epub|cbz)$/i,""),author:row.bookCreator||"",
        format:row.format,size:Number(row.size)||0,modifiedAt:row.modifiedAt||null,coverHash:row.coverHash||null,
        coverType:row.coverType||"",coverStatus:row.coverStatus||"",language:row.language||"",description:row.description||"",
        publisher:row.publisher||"",publishedAt:row.publishedAt||"",identifier:row.identifier||"",subjects});
    }
    return json({ok:true,provider,sourceId,items,count:items.length,truncated:items.length>=10000});
  }catch(error){return json({error:"讀取雲端書架索引失敗："+String(error?.message||error).slice(0,160)},503);}
}
