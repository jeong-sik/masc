# Supervisor readiness boundary — #37900

Base: `acaaee9828a7cfaa94a28c02d62b9f97aa4ecfd4`.

The supervisor previously promoted a PID-bound candidate after `/health` returned success. The HTTP frontend can answer that endpoint before owner/store preparation finishes. A later boot refusal could therefore leave an LKG and a restart proof for an unready candidate. The operator status command used the same insufficient endpoint.

Both now use `/health/ready`, whose production handler requires the startup barrier and published owner state. PID, artifact digest, supervisor nonce, child exit status and stop semantics are unchanged.

## Direct execution

The exact helper prefix and three named functions from `test/test_start_masc_script.ml` were extracted without editing their bodies and compiled with the complete actual `String_util.ml/.mli` plus installed Alcotest, Re, Digestif and Unix libraries. Other Common-dependent fixtures were excluded. See `source-identity.json` for the source hashes and scope; `final-source-match.json` confirms the executed sources still match.

- The actual supervisor receives a PID-matched candidate whose liveness succeeds and readiness fails. The fixture checks no LKG/proof, exit23, and exactly one child launch.
- The existing positive fixture accepts only the exact configured-host `/health/ready` URL and checks LKG promotion and external stop.
- The control fixture rejects status before readiness, then reports healthy after readiness and stops its owned child.

All **3 cases passed** in 5.355s (`run.log`). The same negative fixture against the original baseline scripts **failed** as expected (`baseline-regression.log`): it restarted a child that exited23 without readiness; the fixture terminated the erroneous second launch, yielding143. This is a sensitivity check, not a passing baseline.

`compile.log` records the exact isolated `ocamlfind ocamlopt` command. `full-test-source-parsing.log` records syntax parsing of the entire changed test file. This does not typecheck or execute the entire test module. `curl` and `lsof` are explicit fixture ports, not a real HTTP listener or an installed server. No live workspace state, installed artifact, or server was changed; no Dune/full build/CI watch was run.

## Existing policy retained

The executable's Refuse_boot inventory already covers metadata, current Memory, official-client session bindings and event queues. Gate remains Preflight_only with unavailable authority surfaced at runtime. Checkpoints remain outside boot inventory under the documented 2026-09-26 operator decision. The runbook now distinguishes these policies and the recovery paths; this repair adds no global refusal, reset, delay or retry limit.
