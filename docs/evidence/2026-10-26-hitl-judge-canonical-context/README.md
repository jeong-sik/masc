# Stable judge-original context bytes

Observed while executing #25860's owner-drain control in PR #46019.
This repair is a child of that test layer, base
`f0121078333a676ec1448fc009e72d86cc0e857e`.

[Run 40227874157](https://github.com/jeong-sik/masc/actions/runs/40227874157)
executed `33bb1b7efce4bf3546cb8d65973a66b48ee315f6`: 57 PASS / 1 FAIL in 58
actual cases. The new concurrent-owner control passed. The existing judge-owner
original restore case failed its original equality assertion. Source review
identified a semantic risk beyond that equality: the original-request store
canonicalizes JSON objects and numbers, while original/HTTP/CLI message builders
serialized the captured context directly. A retained/reloaded original could
therefore produce different message bytes with the same canonical digest.
Production does not currently resume judgments through this owner store; this
repair does not claim an observed live replay incident.

Use the existing store canonicalizer when preparing or decoding an immutable
judge original and when the worker freezes its context. HTTP and CLI builders
then share the same prepared canonical context. Invalid nested duplicates and
non-finite numbers propagate as errors; array order and text remain significant.
No new serializer, migration, runtime option or format version is introduced.

The selected controls now compare exact original message text across owner-store
reload, nested key/numeric permutations, and preservation of array order.
Existing HTTP execution checks actual request message text against the prepared
original. Existing CLI-only and HTTP-to-CLI controls check the prompt delivered
to the injected runner against the original's exact context bytes. CLI process
execution and live providers are not claimed. Nine source hashes bind these
inputs. Parsing and whitespace checks passed. Corrected selected execution and
independent final source reviews are pending at record creation.

No local Dune build/typecheck, full regression, crash/restart, installed runtime
or deployment was performed. #25860 remains open for its other fault proofs.
