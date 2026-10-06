# Machine activity admission through stdio

Issue #41207: MSX/DOS activity observers were installed only in HTTP startup. This isolated response starts at prepared #41199 integration `347e6749035636c25a8c4ce9d762b5d29a0a2f14`. It moves the existing observer installation into shared owner activation, alongside Browser, before ownership publication. The same switch still clears both observers. No production default or admission policy changes.

The real stdio regression creates four isolated configurations: MSX/DOS, each Off/On. Each fresh process has no loaded machine. A one-step request therefore either refuses configured Off or reaches the normal no-machine-loaded error when On; no emulator work or backend is loaded. Read-only screen/peek deliberately bypass activity admission, so they cannot test this boundary. Only temporary fixture auth is disabled; inherited secrets are excluded, autonomous work is disabled, and the valid model configuration points to unreachable loopback port 9. No provider is invoked.

The pre-fix focused build exited 0. All four actual cases failed with `Machine activity configuration is unavailable` (RED, 3.289s); the original binary SHA is retained. The one-line relocation then built successfully and the same four cases passed (3.280s). Those initial passing runs revealed unclosed subprocess pipes in the new fixture; explicit pipe cleanup was added, without changing assertions. The final declared focused alias actually passed all four cases in 2.117s with no ResourceWarning. Direct and alias executions are repeated qualification of four cases, not eight distinct cases. Ruff and Pyright report zero errors.

Commands from this worktree:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build bin/main_stdio_eio.exe
python3 test/test_stdio_machine_activity.py _build/default/bin/main_stdio_eio.exe
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build @test/runtest-test_stdio_machine_activity
ruff check test/test_stdio_machine_activity.py
pyright --outputjson test/test_stdio_machine_activity.py
```

Handles: baseline build73130 exit0; RED90195 exit1; patched build39371 exit0; initial direct+alias46106 exit0; final alias20018 exit0. Raw logs are retained byte-for-byte, including initial warnings and EOF whitespace. Checks pin four current source inputs, the final binary, and every copied raw artifact. No full suite, live backend, provider, production or release proof is claimed.
