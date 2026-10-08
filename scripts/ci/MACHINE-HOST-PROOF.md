# Actual machine Add-on host proof

`lane-addon-images.yml` mode `host_lifecycle` builds `main_eio` and both native
workers once on Ubuntu amd64, then builds the existing runtime Dockerfiles.
It requires an explicit full source SHA and verifies the checkout against the
probe's required `--expected-source` argument. There is no moving-branch default.
The separate workflow checkout supplies the probe, not the feature binaries.

After source review, dispatch explicitly:

```sh
gh workflow run lane-addon-images.yml --ref ci/lane-addon-host-proof \
  -f mode=host_lifecycle \
  -f source_sha=1632107405d574726b90f0ac918ceeaf98ddbbcb
```

The probe creates a fresh workspace/config, starts the actual host, and mints an
admin credential through its normal login command. No production configuration,
Keeper, provider key or game media is copied. The only configured model endpoint
is a local counting sink: any HTTP request, including a startup health probe,
is recorded with method/path and fails the zero-request assertion. Workers run in
the package's ordinary restricted Docker containers; MSX uses no ROMs, and DOS
uses a generated COM program that prints `HI` and waits for keys.

The proof records these boundaries through authenticated public APIs:

- Detached: neither manifest's tools are exposed and neither active screen
  context is available.
- Attached: MCP discovery adds exactly the package-declared exports. Container,
  image and persistent-volume ownership are checked against the actual instance.
- Invocation: host MCP calls reach each native worker, return PNGs, and advance
  machine time. Public observations carry matching machine incarnation and
  clock; the live screen references the same published observation.
- Selective detach: MSX tools/context disappear while DOS still accepts input;
  DOS subsequently disappears too. Actual container removal is checked.
- Historical slices remain readable after detach. Their retention is expected,
  not a failure to remove active tools/context.

The uploaded `host-proof/` contains sanitized HTTP/MCP exchanges, screenshots,
binary/manifest/image identities, observations, checks, cleanup results and host
logs. Authorization/session headers and the workspace's auth files are excluded.
The disposable workspace is outside that artifact directory. Cleanup verifies
instance labels and full volume owner tuples before removing probe resources.

Read `receipt.json` for the actual verdict. Static parsing or a successful build
does not establish host lifecycle behavior. This probe does not establish Keeper
prompt injection, persistent-installation reconciliation, deployment, real-game
correctness, or Release/Tag readiness. Local server/Docker execution is not part
of coding-agent validation; execute this probe on its authorized CI runner.
