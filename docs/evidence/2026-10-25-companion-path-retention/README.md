# Companion IPC retirement and pathname retention

Review response for #45806, prepared against head
`6b034ee3485d464d7b038234f7160b0dbd5af419` / direct base
`39474ac82914b5382b4065a5ed9cdd1d86c8c18a`.

The original broker checked directory/socket identity and then unlinked the
socket by pathname. The allocation checked directory identity and then removed
its pathname. A same-UID process could replace either name between the check
and deletion. A controlled execution of the original `private_listener` callback,
using explicit Eio hook/systhread ports and real Unix sockets, replaced the socket
immediately after `lstat` and observed `successor socket removed: true`.

The repair closes the originally owned listener descriptor, joins its connection
scope and all registered Browser settlements, and retains both filesystem names.
`Paths_retained` certifies only those active resource retirements. It does not
claim filesystem removal. The cached cleanup result emits a host warning naming
the allocation path. Descriptor-close and Browser-settlement failures remain
errors. Retained startup allocations remain `Cleanup_unconfirmed`.

## Reproduce the bounded checks

```sh
python3 test/fixtures/companion-path-retention/run.py
```

The runner extracts the actual listener function and allocation cleanup closure
from the candidate source. It executes them with explicit effect ports; the
listener scenarios use real Unix sockets. Both extracted source hashes are
printed. Five scenarios pass:

- the original descriptor closes while a replacement socket and renamed original
  socket remain untouched;
- injected close failure preserves the typed error and leaves the descriptor open;
- allocation joins the registered settlement and retains the path;
- descriptor uncertainty remains an error;
- Browser-settlement uncertainty remains an error.

The allocation probe also checks cached cleanup does not repeat settlement.
The full native fixtures were updated for retained paths, stopped listeners and
typed broker shutdown. They were read and parsed, **not executed**. OCaml 5.5.1
parse-only passes for the seven changed production/native-fixture ML/MLI files.
Whitespace and the #45806 changelog fragment check pass.

This is actual-function/component evidence, not a complete Eio lifecycle run,
OCaml project typecheck, Dune build, CI, installed host, real Browser or account
verification. Stopped socket entries/directories accumulate until operator-owned
maintenance; this change intentionally adds no background deletion or cleanup
replay. An unconfirmed descriptor close does not become an operator retention
acknowledgment or a successful owner release.
