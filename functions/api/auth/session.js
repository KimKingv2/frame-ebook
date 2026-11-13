import { json, isAuthenticated, getOpenListProfiles, getOpenListRootPath } from "../../_lib/common.js";

export async function onRequestGet({ request, env }) {
  const authenticated = await isAuthenticated(request, env);
  const profiles = getOpenListProfiles(env);
  const anyServerProfileConfigured = Object.values(profiles).some(profile => profile.configured);
  return json({
    authenticated,
    openListConfigured: anyServerProfileConfigured,
    openListProfiles: profiles,
    rootPath: authenticated ? getOpenListRootPath(env) : null,
    databaseConfigured: !!(env.FRAME_READER_DB || env.DB)
  });
}
