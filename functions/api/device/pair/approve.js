import { getAccessIdentity, isSameOrigin, json } from "../../../_lib/common.js";
import { databaseOrError } from "../../../_lib/device-sync.js";

function normalizeCode(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8);
}

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源核准設備。" }, 403);
  const dbResult = databaseOrError(env);
  if (dbResult.error) return dbResult.error;
  let identity;
  try { identity = await getAccessIdentity(request, env); }
  catch (error) { return json({ error: error?.message || "Cloudflare Access 身分驗證失敗。" }, error?.status || 503); }

  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: "配對代碼格式無效。" }, 400); }
  const userCode = normalizeCode(body.userCode);
  if (userCode.length !== 8) return json({ error: "請輸入完整的 8 位設備配對代碼。" }, 400);

  const now = Date.now();
  try {
    const result = await dbResult.db.prepare(
      "UPDATE reader_device_pairings SET status='approved',user_id=?,approved_at=? " +
      "WHERE user_code=? AND status='pending' AND expires_at>?"
    ).bind(identity.userId, now, userCode, now).run();
    if (!(Number(result.meta?.changes) > 0)) {
      return json({ error: "配對代碼不存在、已過期或已經使用，請在 Mac 重新產生代碼。" }, 404);
    }
    return json({ ok: true, approved: true, message: "設備已核准，請回到 FRAME Ebook Mac 端完成連結。" });
  } catch (error) {
    return json({ error: "核准設備失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
