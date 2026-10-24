# Stable Goal context: actual Task linkage and post-approval failure

The isolated server is source `3badb88117794510dac576bf3fc34f0336e17d8a`, built by [40101087227](https://github.com/jeong-sik/masc/actions/runs/40101087227). Server SHA256 is `150825c67aeaffbac66c20d33636ab02708fd4a9bf27ba3e5c0710daee5e3688`. ZIP CRC, published checksum and embedded source identity were checked. Compatible, previously verified support files were reused. This is server-only extraction and a separate test base, not a full package installation or production deployment.

The local model is `gemma4:e2b`, installed registry digest `7fbdbf8f5e45a75bb122155ed546e765b4d9c53a1285f62fd9f506baa1c5a47e`. The registry digest is not a provider weight attestation. Tools execute using the pinned Docker image `sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d`, without network. HTTP requests and raw model responses were captured privately at a local proxy. Public records contain tool calls, hashes and public responses, without raw thinking or credentials.

## G2: related Task persisted

The owner request asks for alpha, beta and gamma to become true, with a first partial Task changing only alpha and waiting for its approval. It supplies no Goal ID. This is one active Goal; it does not test disambiguation among multiple Goals. The owner prompt differs from the older7501/c6 cohort; do not claim a controlled population improvement.

Actual request000005 creates task-001 with a valid description and the matching Goal ID after two real missing-description rejections. The authoritative task-to-Goal index contains the link. The leading System Goal is retained in every tool request, extra context contains no Goal snapshot, and saved System bytes match the actual wire. `g2-observation.json`, `g2-task.json`, `g2-goal-links.json` and `g2-prompt-capture.json` preserve this boundary. G2 passes for this exact cohort. The model then stops with Task Todo; creation does not establish execution.

## First partial Task and controlled approval

One additional owner reminder was sent **before approval** to make the model claim and execute its already-created Task. `execution-reminder-input.json` and its admission retain that intervention. The model claims task-001, reads the file, receives two real Edit failures, writes alpha=true/beta=false/gamma=false, and submits `artifact:workspace/acceptance.json` for verification at14:34:13Z.

The operator proxy independently fetched the immutable submitted artifact and compared the actual file. Both contained exactly the expected1/3 state,46bytes, SHA256 `5fa852df4c27a68cc7e0c127b94c0fe2169a33f55201d50b20618a9ba45e9f06`. It approved only this partial Task at14:36:06Z, verification ID `vrf-c6c42865031b8d50dce397b39f68ecfc`. See `partial-inspection.json`, `partial-artifact.json`, `approval-intent.json` and `approval-receipt.json`. This is controlled operator-proxy approval, not an independent model verdict or human Goal completion confirmation.

## G3: delivered approval was ignored

No Keeper message or synthetic nudge was sent after that approval. Actual request000019 contains the approved Task outcome with the exact verification ID, current Goal revision and measurement in System, and33 offered tools including `masc_goal_measure`. The model returns a public answer saying it is still awaiting verification and makes no tool call. The event is acknowledged as `turn_completed`; the pending queue is empty. On-demand activation does not schedule idle follow-up by itself. This is a model action failure after delivery, not demonstrated scheduling starvation.

The actual file remains1/3, the Task is Done, and the Goal remains Executing with its initial reported measurement0/3. G3 fails in this cohort. No Task approval is relabeled as actual Goal progress. `g3-diagnosis.json`, [the diagnosis](g3-README.md), and `g3-after-approval-observation.json` preserve timestamps, hashes, state and public response. Request15 and the thinking-only terminal response14 preceded approval and are not post-approval retries.

## Visible dashboard

[The screenshot](dashboard-goal-system-carrier.png) was captured and visually inspected in Ego browser replacement space21. It uses the actual isolated backend and the integration checkout's Vite frontend. The inspector shows active_goals, separate System24.4KB and Extra9.0KB, and labels the data as the last captured prompt. It does not predict a future request or prove remote retention. The capture is turn4, distinct from the archived G2 turn1 capture.

`dashboard-last-prompt-api.json`, `dashboard-prompt-capture-turn4.json` and `dashboard-binding.json` bind the API fields, persisted capture, actual request19 System bytes and screenshot hash. The dev MCP proxy validates that incoming Origin matches its own Host before translating both to the fixed test backend. This setup is recorded in `dashboard-proxy-proof.json`; no wildcard CORS or backend application change was used. Installed frontend dependencies match the checkout's lockfile. The corrected label/hint is a two-string frontend delta after sourcecf60643, with its existing tab test locator updated. The two affected frontend suites pass25 tests (`frontend-tests.txt`); native execution remains attributed to the exact native head. An initial run using the old locator failed, then the locator was updated and the same suites passed. Browser space21 was finished after the saved screenshot was viewed.

## Verification scopes

- Source3bad: [six targeted native suites passed40101087040](https://github.com/jeong-sik/masc/actions/runs/40101087040), including actual three-request HTTP/Task linkage and carrier captures. Deterministic fixtures and this real model experiment are separate evidence.
- Official Resume repair atd3a242837194e94c435a228228ac0eaab10724aa: [two targeted native suites passed40102214212](https://github.com/jeong-sik/masc/actions/runs/40102214212).
- Official blank-base policy repair atcf60643a1680b6c1cfa678feb5c97034b3bd8d22: [two targeted native suites passed40103733597](https://github.com/jeong-sik/masc/actions/runs/40103733597),87 Host tests and13 projection tests. These official-only changes do not alter the regular HTTP product path used by the3bad canary.
- Independent source review passed the current direct PR delta atcf60643. This is not approval of all14 native stack members or a GitHub APPROVE receipt. No full regression, merge, production deployment, live official vendor session or microVM end-to-end grader is claimed.

The fixed campaign score is10/11 at this boundary. G3 remains a measured failure; Goal proof and final human confirmation remain separate and unrequested.
