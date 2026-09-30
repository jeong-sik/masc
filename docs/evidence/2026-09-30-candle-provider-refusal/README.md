# Provider refusal native evidence

[Test run36609262218](https://github.com/jeong-sik/masc/actions/runs/36609262218) at `966089bc60284af38933d75ac822a46fe013c606` completed its targeted Test step successfully: three suites,27 cases. The entire workflow was still running when inspected; the full suite-runner log is preserved here.

- Transport8: real fixture HTTP400/403 becomes rejected,402/429 remains unavailable/retryable; exact durable receipts retain response body and selected slot. Existing malformed output,503 and declared HTTP/CLI succession cases also pass.
- Appraisal11: rejected input creates no payment, a plain pulse does not repeat it, explicit wake settles its obligation. Production payout arithmetic and recipient boundaries are exercised with injected model decisions.
- Worker8: production candidate scheduling and durable obligation handling pass.

This commit predates `48b5bae848`, which retains retry events across an unavailable scan. These27 cases do not establish that later recovery behavior. They also do not establish real-model grading quality, live rollout or the complete cross-feature integration.
