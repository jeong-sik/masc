# Task deletion cleanup UI evidence

This bundle records real Chromium rendering of the CI-built Dashboard at source `5cdf1aee64aa0942a9c390387ad284e5b6bc37b2` ([artifact workflow](https://github.com/jeong-sik/masc/actions/runs/34298781705)). API responses are synthetic fixtures intercepted by Playwright. This is UI interaction evidence, not a backend runtime, production deployment, or restart recovery result.

The operator deletes `cleanup-target`. The first response reports that deletion committed but link cleanup failed. After the refreshed Task list removes its card, the cleanup panel remains visible with the actual fixture error and a retry button. Clicking retry submits the same Task ID; a settled response removes the panel. Both POST bodies are recorded in `requests.json`.

- `cleanup-pending.png` and `.txt`: card absent, cleanup error and retry remain.
- `cleanup-settled.png` and `.txt`: cleanup panel removed after the second receipt.
- `proof-receipt.json`: exact source/archive/index identity and two same-ID calls; zero browser page errors.
- `browser-proof.py`: fixture data, route interception and assertions used for this run. It expects the matching CI artifact under `artifact/`; the artifact itself is not duplicated here. Its local Chrome executable path is a test-host prerequisite, not product configuration.
- `evidence-manifest.json`: SHA-256 of the original captured artifacts, checked before copying.

Unprovided shell/auth/Gate endpoints return fixture errors; their visible banners are not production health findings. The script does not test page reload persistence. The retry state in this source is session-local; durable cleanup receipts and API/UI rehydration remain follow-up work.

Separate backend evidence: [Task/cache tests](https://github.com/jeong-sik/masc/actions/runs/34298781901) passed at the same source. [Deletion outbox tests](https://github.com/jeong-sik/masc/actions/runs/34298979885) passed at `14ee39b8a9986b1e47970a1ed2c489aaaa5d7f02`; those cover primary-commit ordering and pending rejection retirement, not the browser fixture's backend.
