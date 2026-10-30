# Isolated Dashboard component capture

This fixture imports the real `normalizeKeepers`, `KeeperActivitySummary`, and
`RawDataDebug` modules. Synthetic count fields are `conversation_tail_count=6` and
`addressed_message_count=1`; no history rows are loaded or aggregated here. It does not connect to a MASC server or prove actual
Keeper delivery. Wrapper CSS is only for the evidence page.

From the repository root, with Dashboard dependencies already available:

```sh
cp -R docs/audits/2026-10-23-feature-audit/dashboard-fixture dashboard/.audit-feature-20261023
cd dashboard
pnpm exec vite --config .audit-feature-20261023/vite.config.ts
```

Open `http://127.0.0.1:51923/.audit-feature-20261023/index.html`.
The activity component renders `멘션 1`; the debug component renders
`멘션 메시지 1` and `대화 tail 6`. The captured source was code head
`ed476e2a76f21bd48330da9db38f7b651effef83`.

Capture used Ego Lite 0.6.0.16 in owned task space 77; the space was finished
with no kept pages, and the temporary Vite process was stopped. No visual
snapshot test, UI wording assertion or CI gate was added.
