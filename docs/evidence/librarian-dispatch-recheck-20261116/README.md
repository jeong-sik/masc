# Recheck immutable originals without restoring them again

The operator's MASC process PID 5756 advertised embedded commit
`10e51ac19527155939dc05e2caf77f1de6aac7b6`, including the official-history
index repair. CPU and memory remained high. A later allocation snapshot
reported 451,243,199,992 cumulative estimated allocated bytes and
10,348,000,000 estimated not-yet-deallocated bytes, with no dropped samples.
These are sampling estimates, not peak RSS or proof of a leak.

`allocation-sites.json` is a content-free selection of that snapshot's
authorization call stacks. Request-body parsing, nested history parsing and
canonical reserialization each account for gigabytes of cumulative allocation.
The initial authorization and dispatch callback share these stack prefixes,
so the rows do not measure dispatch alone or predict how many bytes this
repair saves. Private original requests and conversation bodies are excluded.

## Duplicated work

The dispatch callbacks for completed history, floor steps and admission
originals called `Owner.load` again, although this authorization already held
the canonical body that an initial load verified. They then compared entire
request trees. The history callback also called `History.restore` again,
reparsing nested JSON strings, recreating prompt preparation, reserializing
the full capture and checking its immutable encoding a second time.

The store already provides the necessary narrower contracts:

- `Owner.reload` reads current owner metadata/progress and requires the same
  scope, request ID, digest, installation, package, tool and summary. It carries
  the previously verified immutable body. Missing or changed ownership refuses.
- `History.confirm_record` checks the captured physical source root, host
  binding and request digest without reconstructing the immutable capture.

The repair uses those existing APIs. Current physical Keeper/Memory-epoch
observation, owner comparison, predecessor acknowledgement, counterpart-template
and live export checks remain. Initial authorization still fully loads and
validates the original. No process-wide body cache, bypass, weaker digest check
or new execution authority is introduced.

Body reuse follows the documented `reload` contract: after initial validation,
the held value remains the input while its exact immutable owner identity is
confirmed. A disk body removed later is not reread by this callback. This is
distinct from a removed owner record, which refuses. Other operations that
require reading the body still retain their own strict reads.

## Verification and boundaries

An independent source session reviewed the contract and found an illegal
update of a private record in the new regression. It was corrected to change
serialized owner metadata through the actual store API. Cleanup is protected
from Eio cancellation.

The actual host-authorization regression creates an owned fixture original,
authorizes it, temporarily moves its already verified body, and rechecks the
authorization. It then changes the owner summary and requires refusal, while
asserting no extra provider call or source acknowledgement. The fixture restores
its own body and owner record. The test source parses but has not executed.

OCaml 5.5.2 directly typed the modified production interface and implementation
with fatal warnings 4 and 8 against existing build interfaces; both passed.
This was a small compiler invocation, with no Dune build. An attempt to type
the full regression source could not complete because the prebuilt
`Masc_test_deps` and current interfaces disagree over
`Workspace_utils_paths_backend`; no test-library rebuild was started.
`typing.json` records these limits.

No full project build, Alcotest execution, CI or candidate installation is
claimed. Overall live CPU/memory improvement remains to be measured after
deployment. Repeated immutable prompt rendering during initial restoration and
checkpoint decoding remain separate work.
