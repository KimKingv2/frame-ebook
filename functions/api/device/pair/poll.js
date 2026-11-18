import { json } from "../../../_lib/common.js";
import { databaseOrError, randomUrlToken, sha256Text } from "../../../_lib/device-sync.js";

export async function onRequestPost({ request, env }) {
  const dbResult = databaseOrError(env);
  if (dbResult.error) return dbResult.error;
  let body = {};
  try { body = await request.json(); } catch (_) { return json({ error: "設備配對資料格式無效。" }, 400); }
  const deviceCode = String(body.deviceCode || "");
  if (!/^[A-Za-z0-9_-]{40,160}$/.test(deviceCode)) return json({ error: "設備配對憑證格式無效。" }, 400);
  const pairingHash = await sha256Text(deviceCode);
  const now = Date.now();

  try {
    const pairing = await dbResult.db.prepare(
      "SELECT pairing_hash AS pairingHash,device_name AS deviceName,status,user_id AS userId,expires_at AS expiresAt " +
      "FROM reader_device_pairings WHERE pairing_hash=? LIMIT 1"
    ).bind(pairingHash).first();
    if (!pairing) return json({ error: "找不到設備配對請求，請重新產生代碼。" }, 404);
    if (Number(pairing.expiresAt) <= now && pairing.status !== "claimed") {
      await dbResult.db.prepare(
        "UPDATE reader_device_pairings SET status='expired' WHERE pairing_hash=? AND status IN ('pending','approved')"
      ).bind(pairingHash).run();
      return json({ status: "expired", error: "配對代碼已過期，請重新產生。" }, 410);
    }
    if (pairing.status === "pending") return json({ status: "pending" });
    if (pairing.status === "claimed") return json({ status: "claimed", error: "這個配對請求已經完成兌換。" });
    if (pairing.status !== "approved" || !pairing.userId) return json({ status: "expired", error: "設備配對狀態無效，請重新產生。" }, 410);

    const deviceToken = randomUrlToken(48);
    const tokenHash = await sha256Text(deviceToken);
    const deviceId = crypto.randomUUID();
    const claimedAt = Date.now();
    const results = await dbResult.db.batch([
      dbResult.db.prepare(
        "UPDATE reader_device_pairings SET status='claimed',device_id=?,token_hash=?,claimed_at=? " +
        "WHERE pairing_hash=? AND status='approved' AND expires_at>?"
      ).bind(deviceId, tokenHash, claimedAt, pairingHash, claimedAt),
      dbResult.db.prepare(
        "INSERT INTO reader_devices (device_id,user_id,device_name,token_hash,created_at,last_used_at,revoked_at) " +
        "SELECT ?,user_id,?,?,?, ?,NULL FROM reader_device_pairings " +
        "WHERE pairing_hash=? AND status='claimed' AND device_id=? AND token_hash=?"
      ).bind(deviceId, String(pairing.userId), String(pairing.deviceName || "FRAME Ebook").slice(0,80),
        tokenHash, claimedAt, claimedAt, pairingHash, deviceId, tokenHash)
    ]);
    if (!(Number(results?.[0]?.meta?.changes) > 0) || !(Number(results?.[1]?.meta?.changes) > 0)) {
      return json({ status: "pending", message: "設備核准狀態正在更新，請稍後重試。" });
    }
    return json({
      ok: true,
      status: "approved",
      deviceId,
      deviceToken,
      deviceName: String(pairing.deviceName || "FRAME Ebook")
    });
  } catch (error) {
    return json({ error: "完成設備配對失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
