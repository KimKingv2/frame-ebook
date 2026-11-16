import { json, getOpenListProfiles, getOpenListRootPaths, getDatabase } from "../../_lib/common.js";

// Cloudflare Access has already authenticated or rejected the request at the
// edge. This endpoint only reports Reader service readiness; it does not run
// a second JWT verifier or establish a separate application session.
export async function onRequestGet({ env }) {
  const profiles = getOpenListProfiles(env);
  const anyServerProfileConfigured = Object.values(profiles).some(profile => profile.configured);
  const accessIdentityConfigured = !!(env.FRAME_READER_ACCESS_TEAM_DOMAIN && env.FRAME_READER_ACCESS_AUD);
  return json({
    authenticated: true,
    accessEnabled: true,
    authenticationMode: "cloudflare-access-edge",
    openListConfigured: anyServerProfileConfigured,
    openListProfiles: profiles,
    rootPaths: getOpenListRootPaths(env),
    databaseConfigured: !!(env.FRAME_READER_DB || env.DB),
    cloudReaderDataConfigured: accessIdentityConfigured,
    cloudAnnotationsConfigured: accessIdentityConfigured
  });
}
