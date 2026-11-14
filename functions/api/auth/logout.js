import { json, isSameOrigin } from "../../_lib/common.js";

export async function onRequestPost({ request }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源登出請求。" }, 403);
  return json({ authenticated: false, message: "請使用 Cloudflare Access 登出。" }, 200);
}
