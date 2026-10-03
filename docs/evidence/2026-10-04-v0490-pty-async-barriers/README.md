# Asynchronous fixture barriers

Addresses both P2 findings on #41058 (Rondo review 5402388640). Python fixtures only.

The held Ask observes the admitted connection with a non-consuming socket peek. It proves the connection is open before workspace withdrawal and sees EOF/reset while the response gate remains held. Total admission-to-disconnect is bounded by the existing 8s fixture deadline, below the current TUI HTTP timeout of 10s. Only then does it release the response and verify B's current surface and the admission ledger. ConnectionHttpResponse exposes the handler-owned socket without changing existing response resolution.

After the rendered roster refusal, the Item scenario keeps authority unavailable for the complete existing 8s observation window, drains PTY output, rejects any account GET, checks that the TUI remains alive and preserves the error/money/ownership assertions. The final ledger checks that same denied-retry observation after HTTP handlers join. It distinguishes earlier requests admitted before the client observed the unavailable roster. This is bounded quiescence evidence, not a proof about arbitrarily delayed workers.

Final focused Ask cases: 2/2 PASS. Final official Item entrypoint: 2/2 PASS. Both use the existing e4afdce8f0c4ba4cf02e4326ba423c4fe2207339 macOS artifact from Full RC 37142285007. manifest.json pins final changed sources, binary and raw artifacts. No product build, Linux result, new-head Full RC or live server is claimed. #41066 separately records the prior remote-workspace entrypoint 26/26 run.

The negative control injected a real fixture HTTP GET 250ms after the Item keyboard frame. The asynchronous assertion correctly rejected it (negative-control.json). The diagnostic harness injected this request; the product did not emit it. Raw scripts/logs remain under /tmp/masc-pty-async-barriers-final-ask-20261004, /tmp/masc-pty-async-barriers-final-item2-20261004 and /tmp/masc-pty-async-barriers-negative2-20261004.

An earlier complete Item attempt failed because its post-cleanup ledger also counted valid reads before the visible authority withdrawal. The final observation marker fixes that fixture distinction; the earlier failure remains under /tmp/masc-pty-async-barriers-final-item-20261004 and is not claimed as a pass.
