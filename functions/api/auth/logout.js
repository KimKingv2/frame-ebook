import { json, clearSessionCookie, isSameOrigin } from "../../_lib/common.js";

export async function onRequestPost({ request }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源登出請求。" }, 403);
  return json({ authenticated: false }, 200, { "Set-Cookie": await clearSessionCookie() });
}
