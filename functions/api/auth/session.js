import { json, getAccessAuthDiagnostics, isAccessVerifierConfigured, getOpenListProfiles, getOpenListRootPaths } from "../../_lib/common.js";

export async function onRequestGet({ request, env }) {
  const auth = await getAccessAuthDiagnostics(request, env);
  const authenticated = auth.authenticated;
  const profiles = getOpenListProfiles(env);
  const anyServerProfileConfigured = Object.values(profiles).some(profile => profile.configured);
  return json({
    authenticated,
    accessEnabled: true,
    jwtValidationConfigured: isAccessVerifierConfigured(env),
    accessJwtDiagnostics: {
      failureReason: auth.failureReason,
      checks: auth.checks
    },
    openListConfigured: anyServerProfileConfigured,
    openListProfiles: profiles,
    rootPaths: authenticated ? getOpenListRootPaths(env) : null,
    databaseConfigured: !!(env.FRAME_READER_DB || env.DB)
  });
}
