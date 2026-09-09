# IDE heartbeat feedback: CI browser evidence

The browser executed the actual `IdePersistencePanel` compiled by [PR check
34410660970](https://github.com/jeong-sik/masc/actions/runs/34410660970), artifact
`10127130657`, for PR head `1f3d330f80612f293e6bd72f8e73960e46d642ad`.
`browser/receipt.json` records both the CI checkout and PR head, all packaged
asset hashes, the executing harness hash, synthetic inputs, and screenshot hashes.
Every packaged file was verified before execution. No local build was used.

The CI-only fixture imports the real panel and supplies synthetic Keeper rows
and state-diagram GET responses. A fixed browser clock makes heartbeat age
reproducible. Running, Restarting and Failing show a five-minute-old heartbeat;
a row with creation/update timestamps but no heartbeat shows `정보 없음` and
no timestamp title. None of these panels claims `저장됨`, `동기화 중`, or `충돌`.
Lifecycle and context controls remain visible.

[Desktop](browser/desktop.png) and [390px mobile](browser/mobile.png) screenshots
were directly inspected: all four states are legible, the missing heartbeat is
explicit, and no horizontal overflow was measured. All four state-diagram GETs
were observed. Page errors and blocked requests were empty. Component and
accessibility tests (9 cases) and `tsc --noEmit` passed before the CI preview.

Reproduce using the downloaded artifact directory:

```sh
node scripts/verify-ide-heartbeat-preview.mjs /tmp/masc-ide-heartbeat-preview-1f3 1f3d330f80612f293e6bd72f8e73960e46d642ad /tmp/heartbeat-evidence
```

An initial harness-only performance-resource wait timed out despite the panel
and requests being present. The final harness waits for the lifecycle display
and checks its intercepted request ledger; the successful receipt is from that
corrected harness. No panel code changed after the measured CI head.

This proves the actual component's feedback with synthetic input. It does not
prove a live Keeper deployment, storage durability, the full IDE shell layout,
or completion of the broader persistence goal.
