import { json, isSameOrigin } from "../../_lib/common.js";

export async function onRequestPost({ request }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源登入請求。" }, 403);
  return json({ error: "FRAME Reader 僅使用 Cloudflare Zero Trust Access，不提供獨立密碼登入。" }, 410);
}
