import { json, isAuthenticated, getOpenListProfiles, getOpenListRootPaths } from "../../_lib/common.js";

export async function onRequestGet({ request, env }) {
  const authenticated = await isAuthenticated(request);
  const profiles = getOpenListProfiles(env);
  const anyServerProfileConfigured = Object.values(profiles).some(profile => profile.configured);
  return json({
    authenticated,
    accessEnabled: true,
    openListConfigured: anyServerProfileConfigured,
    openListProfiles: profiles,
    rootPaths: authenticated ? getOpenListRootPaths(env) : null,
    databaseConfigured: !!(env.FRAME_READER_DB || env.DB)
  });
}
