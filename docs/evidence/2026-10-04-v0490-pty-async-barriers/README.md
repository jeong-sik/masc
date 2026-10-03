# Asynchronous workspace fixture barriers

Final official entrypoints: remote workspace history **26/26 PASS**, Item workspace authority **2/2 PASS**, combined exit 0. The scripts ran through their actual __main__ entrypoints on the existing e4afdce8f0c4ba4cf02e4326ba423c4fe2207339 macOS native artifact from RC37142285007. No local Dune build, new PR binary, Linux result, integrated Full RC or live server is claimed.

[raw-run.tar.gz](raw-run.tar.gz) durably preserves all 28 PTY captures, run log, wrapper, fixture ledgers, exact changed Python sources and both negative-control scripts/logs. Every archived file and the archive itself are SHA256-pinned in manifest.json and were read back and verified. The prior #41066 26-scenario run is also preserved in its adjacent evidence directory's raw-run.tar.gz; local /tmp copies are supplementary.

The held Ask connection is open before workspace withdrawal, then must reach EOF/reset while the response gate is still held. Its 8s deadline starts immediately before sending the second Enter, before client dispatch, so delayed server admission cannot extend the deadline toward the TUI's 10s HTTP timeout. ConnectionHttpResponse exposes the handler-owned socket; observation peeks without consuming input or closing it. POST-only admission counts, phases and current B surface assertions remain.

The negative control deliberately delays server admission by 3s and retains workspace A. The real native client's ordinary timeout closes the connection around 10s after dispatch: the new 8s dispatch deadline rejects it, although the old admission+8s deadline would accept it. See ask-timeout-negative-control.json and the runnable script. This is a counterfactual timeout experiment, not a successful workspace cancellation.

The Item test observes the entire existing 8s no-request interval after the client visibly applies roster unavailability, keeps draining the live TUI and checks the ledger after handler cleanup. The observation distinguishes earlier admitted reads from the denied retry. A real fixture GET injected 250ms after the keyboard frame is rejected (negative-control.json). This is bounded observation, not proof about arbitrarily delayed workers.

The Board precondition also requires the visible workspace-mismatch marker. Current product source already sets the same Board authority error for a known mismatch; the added marker makes that reading explicit. Each chat refusal entry path, including the palette command, clears its prior footer notice before requiring a new refusal, avoiding an unchanged-frame wait.

Earlier failed diagnostic attempts remain historical and are not claimed as passes: an overbroad Item ledger initially counted reads admitted before visible authority withdrawal; a full rerun exposed the palette's unchanged refusal text. The final observation scope and per-entry reset correct those fixture issues. Independent review must inspect this final diff; prior-head verdicts do not carry forward.
