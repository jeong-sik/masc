# Owner shutdown request and follow-up observation

An authenticated, identity-bound SIGTERM request could succeed, then the lease
identity observation could fail. The CLI collapsed this into its pre-request
error and said "No process was stopped". Its observation limit also emitted
`owner_stopped=true` while the owner was still draining.

The repaired receipt reports `termination_requested` independently from
`readiness`. Observation failure and pending drain do not prove exit. Setup
rechecks the workspace without sending another shutdown request; startup still
owns the final lease/port conflict check.

The CLI produces `masc.setup_server_shutdown.v1` and the shipped Python setup
consumer decodes that same receipt. Deliver the binary and setup script from
this source together; a receipt mismatch remains an unconfirmed result.

## Focused evidence

- Baseline: `be5b701e33811e65bcd748763741bf947a1fc81c`. The affected CLI,
  preparation ML/MLI and setup consumer were byte-identical to the installed
  `8e534a757f13350d8a34fbd98bc828bc3578e153` candidate.
- The actual production preparation ML/MLI and CLI were compiled as an isolated
  component with real Eio/Yojson. HTTP, authentication and kernel owner capture
  and signaling were substituted. The before/after receipts and signal counts
  are in [component-results.json](component-results.json).
- Existing upgrade-preparation tests: 7 passed under those component
  substitutions. Existing Python journey tests: 7 focused cases passed, covering
  available/busy ports, post-request observation failure, read-only reinspection,
  no second termination request and malformed receipts.
- Production CLI/preparation component compilation passed the repository warning
  flags with OCaml 5.5.1. Four changed OCaml files passed syntax parsing.

No local Dune build, full host typecheck, real process termination, macOS audit
token race reproduction, installation or runtime recovery is claimed. The
macOS kernel subcause of the original observation error remains unestablished.
