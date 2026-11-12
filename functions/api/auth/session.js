import { json, isAuthenticated, getOpenListConfig } from "../../_lib/common.js";

export async function onRequestGet({ request, env }) {
  const authenticated = await isAuthenticated(request, env);
  const config = getOpenListConfig(env);
  return json({
    authenticated,
    openListConfigured: !!config,
    rootPath: authenticated && config ? config.rootPath : null,
    databaseConfigured: !!(env.FRAME_READER_DB || env.DB)
  });
}
