# Package catalog/preview transport and active-worktree routing

Baseline #41205 `88ee4e48474aea2178fdfeb6f56623fa8e41dafe` (OPEN exact head read before work). The root-created owner worktree was fast-forwarded from `000697850f49ce9366fc17f3533fbb6bc6ba4a93`; incoming changes were JavaScript and documentation only.

Shared typed payloads are declared in the existing route module interface. H1 still applies with_read_auth before using them. Both catalog and preview now have H2 GET routes applying with_h2_read_auth before calling the exact same payloads and duplicate-preserving query decoder. Catalog discovery and preview relative resolution/containment use config.workspace_path; authentication continues to use the shared state base_path, matching the existing auth contract.

Actual meaningful REDs:

- H2 client/server frames against the gateway: unauthenticated catalog expected401, original route missing404.
- A real temporary Git linked worktree has the same lane.toml edited to a different title. Workspace.default_config resolves shared base_path to main while preserving workspace_path; the original catalog returns the main directory rather than the connected checkout.
- With catalog/H2 repaired, temporarily restoring only preview’s old base_path behavior produces Main checkout package rather than Active branch package. The final workspace_path repair restores the active metadata.

Final focused build and all **9 cases** in the small H2 request-body-admission executable pass (two new package cases plus seven existing body/auth cases). The package cases check both endpoints without token/invalid bearer, valid authenticated payloads, unknown/repeated query rejection, active branch preview, and absolute-main, parent-relative and symlink escapes. Escapes are checked through the shared H1 payload and actual H2 frames; directory escape is also refused over H2. No image process is launched: fixture state has no process manager and preview correctly reports unverified inspection.

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_h2_request_body_admission.exe
(cd test && ../_build/default/test/test_h2_request_body_admission.exe test 'package catalog')
(cd test && ../_build/default/test/test_h2_request_body_admission.exe)
```

The existing H2 harness pumps real request/response frames in memory; this is not a socket-level h2c negotiation test. H1 shared payloads are invoked directly; no new H1 wire execution is claimed. Two extraction/test syntax errors and an initial macOS /var versus /private/var path-alias fixture assertion are retained separately, excluded from meaningful RED. Normalizing the fixture precondition with realpath retains the actual active-worktree identity requirement.

Fourteen raw logs are byte-exact, including EOF whitespace, with final source/binary hashes in checks.json. Initial author evidence and prior TUI package flows remain historical unchanged-scope results. No full repository build/suite, live server mutation, provider run, release CI or TerminalBench was performed.
