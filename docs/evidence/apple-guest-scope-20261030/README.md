# Apple guest name and scope probes, 2026-10-30

These are bounded source-extraction probes, not a MASC build, a provider test,
or live Keeper evidence. The source worktree was based on main
`171143393e8f029bc2e09e22407b2601d8b21f37`. The host was Darwin 25.6.0 arm64
with OCaml 5.5.1. The receipts record SHA-256 digests of the exact input source
files; the scope input included uncommitted changes when it was captured.

`name-receipt.json` compiles the actual guest-name and base-path hash functions
with stubs for path canonicalization helpers, safe filenames, network mode and
SHA-256. Its two synthetic absolute paths need no trailing-slash normalization;
their simple Keeper name and short generated names do not exercise the stubs
for filename sanitization or long-name hashing. The two distinct full hashes
share eight leading hex digits and produce the same guest name. No runtime
guest or volume was created.

`scope-receipt.json` compiles the changed scope, stop, and all-mode preflight
helpers extracted from `keeper_turn_sandbox_runtime.ml`. Labels, guest names,
provider reads, cache invalidation, errors and destructive effects are stubs. It checks matching,
missing and different labels; absent, running and stopped observations; a
preflight with a foreign guest; reinspection before a stop; and timeout
forwarding to the stub reader. It does not compile the surrounding production
module or run its Eio, inventory, JSON parser, volume, credentials or guest
paths. The repository fixture tests for those integration paths remain
separate; their presence does not establish that they were run.

`cache-receipt.json` extracts the readiness and invalidation functions from
the runtime and shim modules. Base normalization, Eio and guest size are
stubs. It observes that invalidating an Apple guest name clears matching keys
across two synthetic bases while preserving a different name, a Kata key and
the Kata boot record. It does not execute the actual base resolver, provider,
identity store, concurrency or any production guest lifecycle.

To reproduce into a new, disposable output directory from the repository
root, replace the example paths with paths that do not exist yet:

```sh
python3 docs/evidence/apple-guest-scope-20261030/name-extract.py . /tmp/masc-guest-name-probe-new
python3 docs/evidence/apple-guest-scope-20261030/scope-extract.py \
  --source lib/keeper/keeper_turn_sandbox_runtime.ml \
  --receipt /tmp/masc-guest-scope-receipt-new.json
python3 docs/evidence/apple-guest-scope-20261030/cache-extract.py \
  --repo . --receipt /tmp/masc-guest-cache-receipt-new.json
```

The actual Apple API check and later effect are separate operations; these
probes do not fence an external replacement between them. They do not establish
workspace-scoped volume ownership, migration, or safety for Kata,
Microsandbox, Docker, or colliding process-local caches.
