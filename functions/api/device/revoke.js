import { json } from "../../_lib/common.js";
import { getDeviceContext } from "../../_lib/device-sync.js";

export async function onRequestPost({ request, env }) {
  const context = await getDeviceContext(request, env);
  if (context.error) return context.error;
  try {
    const now = Date.now();
    await context.db.prepare(
      "UPDATE reader_devices SET revoked_at=? WHERE user_id=? AND device_id=? AND revoked_at IS NULL"
    ).bind(now, context.userId, context.deviceId).run();
    return json({ ok: true, revoked: true });
  } catch (error) {
    return json({ error: "撤銷設備授權失敗：" + String(error?.message || error).slice(0, 160) }, 503);
  }
}
