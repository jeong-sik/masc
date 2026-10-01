# Namespace pause readback: reachable HTTP authority

This child of #40378 removes the remaining call to the intentionally unpublished
`masc_pause_status` MCP tool. The new read-only
`GET /api/v1/operator/pause-status` returns the current workspace state directly,
outside dashboard snapshot/publication caches. It reports an uninitialized
workspace as `initializing=true, paused=null`. Pause/Resume writes continue to use
the existing operator action and confirmation path.

## Diagnosis actually executed

An isolated Linux ARM64 server from the official v0.48.0 release was initialized,
given its own admin login, started on an unused loopback port, and shut down with
SIGTERM after the experiment. No deployed workspace or Keeper was controlled.

- Server embedded commit: `fd57a0d963a7fdec20d8e2c0591345cf826138c2`.
- Server binary SHA256: `8a8c15696ea8223be4ac6fabe76e1f1d45a3c19345d97b663061df26b27704c6`,
  matched against that release's SHA256SUMS.
- Parent UI source: `767d9bc78ea76a91f3f4ea9c53a2d64fa480f7c0`.
- The release and parent use the same MCP profile admission, operator control,
  pause handler and schema-exclusion paths relevant to this defect.

The real server accepted namespace_pause and namespace_resume through
/api/v1/operator/action plus /confirm. Its persisted state changed from paused
to running. A correctly framed stateless MCP 2026-07-28 call to
masc_pause_status returned JSON-RPC -32601:
`Tool 'masc_pause_status' is not available on this MCP endpoint.`

The old UI browser fixture answered that unpublished tool successfully. Its
passing result therefore did not prove this server readback worked.

Producer-sandbox receipts are retained separately:
`evidence/task647-native-v048-1540/receipt.json` and `server.log`.
Earlier attempts distinguish HTTP bootstrap readiness, legacy session framing
and missing modern method/name headers; they are not passing readback evidence.
The server process exited 0 and its health paths identified only the isolated
workspace. The release binary is not a build of this new child branch.

## Checks and limits

- TypeScript type check and ESLint on the changed UI files: exit 0.
- Focused flow-control-state/readback Vitest: 26 tests, exit 0.
- OCaml parsing for the new producer, route and registered native regression:
  exit 0.
- The native regression covers uninitialized, running, pause, resume and another
  operator's subsequent pause without a projection cache.
- Native type checking and execution of the new route are not yet verified:
  the lane's earlier focused build was refused by dependency-pin drift. Parsing
  is not compilation or a native regression PASS.
- The previous parent UI screenshots remain fixture evidence, not proof of
  the new child or a deployed server.

An independent source review and a native build of the combined parent/child
are still needed before claiming real UI -> new HTTP route -> persisted state
success. Task-647 also requires its merge SHA and #27053 closure.

[근거] official release API/assets/checksum + isolated server raw responses and
persisted state, 2026-10-01 UTC (2026-10-02 KST); High within the stated native
diagnosis and focused UI checks. No full CI, deployment or completed Task claim.
