; Per-file dune stanza for the runtime.toml reasoning-replay suite. Lives here
; per test/stanzas/README.md to avoid the conflict hotspot in the legacy
; grouped (tests ...) stanza.

(test
 (name test_runtime_toml_reasoning_replay)
 (modules test_runtime_toml_reasoning_replay)
 (libraries masc.runtime alcotest))
