# Abandoned original Browser settlement

Review response for #45806, prepared against current head
`598fcd602f5a927f5eb1d3ab65369bad1b66a970`, direct base
`b3e153196c3e20a8baf26c85b6207d394f1a4a75`, Native Stack #45746 position 8/31.
The original reviews are
[5642808900](https://github.com/jeong-sik/masc/pull/45806#pullrequestreview-5642808900)
and [5642844842](https://github.com/jeong-sik/masc/pull/45806#pullrequestreview-5642844842).

An abandoned private binding retained a known extension operation, but returned
success when its original Browser was stopping or no longer current. That branch
sent no Release and observed no settlement. It now returns the same fixed
unconfirmed-settlement error used for unconfirmed Release replies. An absent
operation and a confirmed original Release remain successful.

## Bounded reproduction

```sh
python3 docs/evidence/2026-10-25-companion-abandoned-settlement/run.py
```

Requires OCaml 5.5.1, `ocamlfind`, compiler-libs, Eio and Yojson. The runner uses
the OCaml parser's source locations to extract the actual runtime `on_finish`
callback. It compiles that unchanged expression with the complete actual
`Lane_addon_companion_allocation` implementation. Eio scheduling, callback
registration, completion notification, allocation cleanup and cached results run
directly. The broker port owns a real temporary Unix listener, closes it and
reports its shutdown. Browser identity, stopping state and Release replies are
explicit ports; no manager, native worker, Browser transport or extension runs.

Nine scenarios check allocation outcomes, Release dispatch counts, exact original
operation identity and cached cleanup, for 36 assertions. Before repair, the
replacement, stopping, and lost-stopping Browser scenarios fail their outcome
checks. After repair all 36 pass. See `before.txt` and `after.txt`; both bind the
runtime and allocation input hashes. No assertion or effect port changed between
the recorded before and after executions.

The direct consumer is `Allocation.on_finish`, which sanitizes callback failure,
and `Allocation.cleanup`, which retains it as an error. Runtime `stop_entry`
converts that error to `Lifecycle.Cleanup_unconfirmed`; a known unresolved
Browser operation therefore cannot certify owner release. No public API changes.

This fixes the introducing layer. Later #45882 has a distinct captured-original
worker-stop/join path for this branch and must retain that implementation when
the stack is replayed. The runner accepts `--runtime-source PATH` to inspect the
introducing-layer source separately after later layers add their own effect ports.

Production OCaml parse-only, whitespace and changelog checks also pass. Dune,
project-wide typecheck, CI, actual native Broker/worker, Browser, extension,
account login and installed runtime are unverified here. The component result
does not establish those outcomes or independently approve this PR or stack.
