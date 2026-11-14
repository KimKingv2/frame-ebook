import { json, getDatabase, verifyPassword, createSessionCookie, getOpenListProfiles, sha256Hex, isSameOrigin, isCloudflareAccessConfigured } from "../../_lib/common.js";

export async function onRequestPost({ request, env }) {
  if (!isSameOrigin(request)) return json({ error: "不允許跨來源登入請求。" }, 403);
  if (isCloudflareAccessConfigured(env)) {
    return json({ error: "本網站已使用 Cloudflare Zero Trust Access 驗證，請先通過 Access 門禁。" }, 403);
  }
  const db = getDatabase(env);
  if (!db) return json({ error: "Cloudflare D1 尚未綁定。請先設定 FRAME_READER_DB，完成後才能啟用雲端登入。" }, 503);
  if (!env.FRAME_READER_ACCESS_PASSWORD || !env.FRAME_READER_SESSION_SECRET) {
    return json({ error: "私人登入密碼或 Session Secret 尚未設定。" }, 503);
  }

  let body;
  try { body = await request.json(); } catch (_) { return json({ error: "登入資料格式無效。" }, 400); }
  const candidate = body && typeof body.password === "string" ? body.password : "";
  if (!candidate || candidate.length > 512) return json({ error: "請輸入私人閱讀密碼。" }, 400);

  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const ipHash = await sha256Hex(ip);
  const now = Date.now();
  const windowStart = Math.floor(now / (15 * 60 * 1000)) * (15 * 60 * 1000);
  try {
    const attempts = await db.prepare("SELECT attempts, window_start_ms FROM auth_attempts WHERE ip_hash = ?")
      .bind(ipHash).first();
    if (attempts && Number(attempts.window_start_ms) === windowStart && Number(attempts.attempts) >= 8) {
      return json({ error: "登入嘗試次數過多，請 15 分鐘後再試。" }, 429);
    }
    await db.prepare(
      "INSERT INTO auth_attempts (ip_hash, window_start_ms, attempts, last_attempt_ms) VALUES (?, ?, 1, ?) " +
      "ON CONFLICT(ip_hash) DO UPDATE SET " +
      "attempts = CASE WHEN auth_attempts.window_start_ms = excluded.window_start_ms THEN auth_attempts.attempts + 1 ELSE 1 END, " +
      "window_start_ms = excluded.window_start_ms, last_attempt_ms = excluded.last_attempt_ms"
    ).bind(ipHash, windowStart, now).run();

    const valid = await verifyPassword(candidate, env.FRAME_READER_ACCESS_PASSWORD);
    if (!valid) return json({ error: "密碼不正確，請再試一次。" }, 401);

    await db.prepare("DELETE FROM auth_attempts WHERE ip_hash = ?").bind(ipHash).run();
    const cookie = await createSessionCookie(env);
    const profiles = getOpenListProfiles(env);
    const openListConfigured = Object.values(profiles).some(profile => profile.configured);
    return json({
      authenticated: true,
      openListConfigured
    }, 200, { "Set-Cookie": cookie });
  } catch (error) {
    return json({ error: "登入服務暫時無法使用：" + (error && error.message ? error.message : "D1 error") }, 503);
  }
}
