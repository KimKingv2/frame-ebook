import { json } from "../../_lib/common.js";
import { databaseOrError, randomUrlToken, sha256Text } from "../../_lib/device-sync.js";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function makeUserCode() {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, value => ALPHABET[value % ALPHABET.length]).join("");
}

export async function onRequestPost({ request, env }) {
  const dbResult = databaseOrError(env);
  if (dbResult.error) return dbResult.error;
  const contentLength = Number(request.headers.get("Content-Length") || 0);
  if (contentLength > 4096) return json({ error: "設備配對請求過大。" }, 413);
  let body = {};
  try { body = await request.json(); } catch (_) {}
  const deviceName = String(body.deviceName || "FRAME Ebook").trim().slice(0, 80) || "FRAME Ebook";
  const now = Date.now();
  const expiresAt = now + 10 * 60 * 1000;
  try {
    await dbResult.db.prepare(
      "DELETE FROM reader_device_pairings WHERE expires_at<? AND status<>'claimed'"
    ).bind(now).run();
    for (let attempt = 0; attempt < 5; attempt++) {
      const deviceCode = randomUrlToken(32);
      const pairingHash = await sha256Text(deviceCode);
      const userCode = makeUserCode();
      try {
        await dbResult.db.prepare(
          "INSERT INTO reader_device_pairings " +
          "(pairing_hash,user_code,device_name,status,created_at,expires_at) VALUES (?,?,?,'pending',?,?)"
        ).bind(pairingHash, userCode, deviceName, now, expiresAt).run();
        return json({
          ok: true,
          deviceCode,
          userCode: userCode.slice(0, 4) + "-" + userCode.slice(4),
          verificationUrl: new URL("/device-link/", request.url).href,
          expiresAt
        });
      } catch (error) {
        if (attempt === 4) throw error;
      }
    }
    return json({ error: "無法建立設備配對請求，請稍後重試。" }, 503);
  } catch (error) {
    return json({ error: "建立設備配對失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
