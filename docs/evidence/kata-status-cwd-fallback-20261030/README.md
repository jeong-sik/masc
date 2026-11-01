# Kata status cwd fallback: extracted fixture

The fixture extracts the actual `current_working_dir` fallback, Kata context
capture, inventory selection and log command selection from the named source
files. It compiles them with a stub `Host_config`, minimal types, and mocked
inventory/log commands. Each case runs in a separate child process. The deleted
cwd cases create, enter and remove only a directory in the fixture's temporary
tree. No container runtime, server, VM or network operation is started.

The retained receipt is copied byte-for-byte from
`artifacts/kata-status-cwd-fallback-20261030/receipt-01.json` and contains no
host paths or credentials. It records the exact source and script hashes. The
run used Darwin arm64 and OCaml 5.5.1. Seven cases passed: a live cwd; deleted
cwd falling back to an existing base, HOME or temp directory; and deleted cwd
with a missing base, a regular-file base, or an injected resolver failure.
For the latter three, neither inventory nor log callbacks were called. The first
two setup attempts did not produce receipts: the first exposed a warning-4
problem in the harness, and the second exposed macOS `/var` path aliasing. Both
were corrected in the harness before the retained run.

The source checkout at the run had base HEAD
`06e43272be3f4bec7d2798f7d8d464774536895c` and uncommitted changes. The
receipt did not itself record that HEAD; `provenance.json` is a separate
post-run annotation tied to the original receipt's SHA-256. It identifies the
full files from which the fixture extracted portions:

| File at the run | SHA-256 | Relation to base HEAD |
| --- | --- | --- |
| `lib/keeper/keeper_sandbox_control.ml` | `927f3aa954df8363efdf4e3d1ff1ab8cb6d681f665bf6b1da3a5d254c8729fd0` | Modified, uncommitted file |
| `lib/config_dir_resolver/config_dir_resolver.ml` | `ca48f1349cfe6d5600355334a15f68dfab8b5336c03eb872961824d293b0d9b5` | Byte-identical to base |
| `lib/env_keeper_scrub.ml` | `59d749b7c4e7680eebadd2170ae18a0f50641ddb233f0034bf07b2c124b4f8ce` | Byte-identical to base |
| `docs/evidence/kata-status-cwd-fallback-20261030/reproduce.py` | `276cedf2c8b96330f0e78846ac4dcd62955509f295e000983658f21b9b68117c` | New, uncommitted script |

These file hashes identify the inputs used by the retained run. They do not
identify the entire worktree or assert that its later complete diff existed at
run time. The base HEAD alone does not identify the modified source or script.

To run again from the repository root, choose a new output path:

```sh
mkdir -p artifacts/kata-status-cwd-fallback-20261030
python3 -B docs/evidence/kata-status-cwd-fallback-20261030/reproduce.py \
  --output artifacts/kata-status-cwd-fallback-20261030/receipt-new.json
```

The script requires `ocamlfind`, OCaml, `unix`, and `yojson`; it refuses to
overwrite a receipt. The stub accepts the synthetic base and HOME inputs; it
does not exercise `Host_config` normalization or persisted defaults, real
`Process_eio`, CLI resolution, a running server, or a terminal. A successful
directory stat is a point-in-time observation, not a fence against replacement
before a later subprocess or proof that an earlier turn used the same inode.
