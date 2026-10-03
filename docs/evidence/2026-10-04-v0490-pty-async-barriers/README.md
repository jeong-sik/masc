# Asynchronous workspace fixture verification

The final official remote-workspace entrypoint passed26/26 and the Item entrypoint passed2/2, combined exit0, using the existing e4afdce8f0c4ba4cf02e4326ba423c4fe2207339 macOS native artifact from RC37142285007. The HTTP-handler observer recorded zero unexpected exceptions and four BrokenPipe disconnects. This is synthetic HTTP/PTY evidence; no rebuilt PR binary, Linux result, integrated Full RC or live-server success is claimed.

[raw-run.tar.gz](raw-run.tar.gz) preserves all28 PTY captures, log, runner, fixture ledgers, exact changed sources, and three negative-control scripts/logs. All109 archived files and the archive itself were SHA256-verified against manifest.json. Local /tmp copies are supplementary. The original #41066 run remains in its adjacent evidence directory with its historical limitations stated.

The held Ask connection is open before workspace withdrawal, then must reach EOF/reset while its response gate remains held. Its8s deadline begins before the second Enter and therefore before client dispatch. The negative control delays admission3.0067s without changing workspace; the real client's natural timeout at10.0218s is rejected by the new deadline and would have passed the old admission-relative deadline. See ask-timeout-negative-control.json and its runnable script.

The Item test observes its existing8s no-request window after visible roster refusal, drains the live TUI and checks its observation ledger after handler join. A fixture GET injected250ms after keyboard processing is rejected (negative-control.json). This is bounded observation, not a proof about arbitrarily delayed workers.

The staged-media scenario routes beta's refused request and interrupt probe separately from alpha. It records every non-beta interrupt at ingress before AtomicChatFixture can return409 without recording it, then requires that ledger to be empty after all handlers join. Beta request IDs are also checked after join. Exact message, image bytes, metadata, reference and Keeper/workspace ownership assertions remain. Alpha's fixture completes normally and the client must display its reply and Esc:list before cleanup, so cleanup itself does not require an alpha interrupt.

The new alpha-interrupt-negative-control.py delays handling a valid alpha-named HTTP POST until normal interaction cleanup. The old primary scenario still returns and the released fixture answers409 without its own ledger entry, but the new post-join ingress assertion rejects the request. The JSON result records this expected rejection. This request was injected by the diagnostic harness, not sent by the product.

Board readiness includes the visible workspace-mismatch marker. Chat entry checks clear each prior refusal before requiring the next one, including palette navigation. The underlying known-mismatch Board error remains unchanged.

Historical scope: old21926 had two beta handler assertions despite primary28/28 success. Head6cdee removed those assertions but its source still missed delayed alpha interrupts after the immediate check (review5402589313). Those older receipts are retained in Git history; only this final source, post-join assertion, normal alpha completion and corresponding guarded run support the current claim. Independent current-head review and final integrated-head RC remain separate.
