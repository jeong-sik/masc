# Goal outcomes and verification integrity campaign

The audit of [Mental Models in the Agentic Era](https://productmindset.substack.com/p/mental-models-in-the-agentic-era) identified seven specific weaknesses at source8eac5c07c290d134a9ef6acb1e298584bf9a1366. The implementation and measurements are in [Native Stack45750](https://github.com/jeong-sik/masc/pull/45867), linked to [issue45747](https://github.com/jeong-sik/masc/issues/45747).

The metric is defined by fixed cases G1–G4 and A1–A7. Task count and Goal linkage ratio are diagnostic, not success targets. Independent Tasks remain valid. The canonical host metric is the experiment-owned acceptance.json referenced by Goal goal-outcome-driven-work-20261024, revision306708facbfb9379a9e51b8f7c815678. This directory preserves a dated snapshot, not another mutable authority.

| Case | Observed status | Evidence and scope |
| --- | --- | --- |
| G1 Current Goal criterion, revision, measurement and explicit unknown reach Keeper | Pass | Actual7501 direct-provider request plus deterministic native missing/stale/error controls. [Direct context](../2026-10-24-direct-goal-context/README.md). |
| G2 Model creates a related Task with matching Goal | Scoped pass | Source328 configured GLM-5.3 chooses the matching Goal ID; original alpha-only Task constraints and external Goal index agree. Earlier failures remain preserved. [Latest runtime](../2026-10-25-goal-continuation-glm/README.md). |
| G3 Approval returns attention to actual Goal measurement and remaining work without inferring Goal completion | Scoped pass | Source328 configured GLM-5.3: approved Task → Read →1/3 measure → actual beta/gamma Edit/Read →3/3 measure → Task2 submission → Goal request_complete and accurate proof/human-pending report. One controlled ordinary HTTP cohort, not general reliability. [Independent diagnosis](../2026-10-25-goal-continuation-glm/postapproval/diagnosis.json). |
| G4 Independent Tasks remain supported | Pass | Isolated external-agent create/claim/start, actual Node Docker computation, submission and controlled operator approval. This is not Keeper inference proof. |
| A1 Grading execution boundary | Pass, Docker scope | [Actual grading stages](../2026-10-24-coding-boundary/README.md) use captured bytes inside fresh unprivileged containers. |
| A2 Oracle-only success forgery | Pass | Both broken Node implementations remained unchanged and both oracle-only edits were rejected; both reference controls passed. |
| A3 Image byte identity | Pass | Native image length/hash/symlink and typed judge/operator/TUI mismatch propagation. Run40074289285 atdca2013e. |
| A4 Cohort/cost identity | Pass, controlled source and CLI scope | [Cohort identities](../2026-10-24-coding-cohort-identities/README.md) and [duplicate JSON protection](../2026-10-24-coding-json-integrity/README.md); no full live-provider benchmark claimed. |
| A5 Resume input identity | Pass, controlled source and CLI scope | Frozen source/scripts/prompts/corpus/config/runtime/binaries/models/memory/image identity, typed receipt/run identity and duplicate-key rejection. |
| A6 Producer/judge model observation | Pass, controlled native scope | Actual native provider parsing, admitted ToolUse ordinal, submission/verdict persistence and calibration tests at7501. Missing raw model identity remains unknown; response ID is a correlation label. This does not prove independent weights. |
| A7 Lifecycle approval, external acceptance and human Goal confirmation | Pass within explicit scopes | [Actual API](../2026-10-24-outcome-api-runtime/README.md) and [visually inspected dashboard](../2026-10-24-outcome-dashboard-runtime/README.md): lifecycle approval1, external acceptance unobserved1, Goal unchanged. Controlled operator proxy is not an independent LLM or actual human Goal verdict. |

Latest experiment-owned acceptance file: **11/11 scoped cases**. G2/G3 are measured at source328 in the configured single GLM-5.3 ordinary-HTTP cohort; G1/G4 and A1–A7 retain their explicitly bound older evidence. This is not a full regression at one head or Goal Completed. The actual [dashboard](../2026-10-25-goal-continuation-glm/ui/README.md) shows reported3/3 separately from Verifying/proof_pending and Task2 AwaitingVerification.

The main8935 read APIs stopped responding during the artifact update; that historical failure is retained. After recovery, the actual main API registered reported-only11/11 at2026-10-25T00:41:14Z, accepted Task2620 for verification at00:44:50Z, and accepted the main Goal request_complete at00:45:12Z: Verifying/proof_pending. [Original receipts and later primary-file reads](../2026-10-25-goal-main-registration/README.md) bind these main facts separately from the canary. Verifier proof and human confirmation remain pending. The unchanged frozen acceptance snapshot's earlier pending bookkeeping describes its write time, not these later API receipts.

The GLM request29 also created Task002 alongside the Read, before request30's1/3 measurement. Remaining artifact edits occurred after that measurement. G3's scoped finding covers measured remaining work and truthful completion reporting; it does not assert that every planning or Task-state effect followed measurement.

Historical failures remain material. Candidate3014 completed at9/11: Qwen omitted the Task link and failed continuation after controlled link/approval, even after an exact-ID Done query succeeded; it never invoked the new receipt. Candidate2be recovered unforced association but initially made all three fields true before approval, then needed actual rejection/recovery. Its fresh approval reached request20, yet the model performed no further tool call or measurement. [Those frozen stages](../2026-10-25-completion-authority-retention/qwen-runtime/README.md) remain intact. The current-turn retention and Official Start carrier repairs have their own source/native scope; the single positive GLM case does not isolate a source/model cause or a population success rate.

The prior54e8 Qwen cohort passed G2 and actual remaining-work/3/3 measurement,
but failed G3's full contract through incorrect Goal verification/completion
reporting and missed the requested intermediate measurement order. Its
[frozen final-request comparisons](../2026-10-25-goal-measurement-receipt/frozen-inference/README.md)
remain diagnostic, with negative arms preserved.
Historical failures remain visible. The older1eef cohort failed before Task
creation. The3bad Gemma cohort failed G3 after correctly delivered approval and
had one disclosed pre-approval execution reminder. The3bad Qwen cohort omitted
Goal association, so its pre-approval public-API link was controlled fixture
setup; after approval its exact-ID default queries hid Done and it made no
remaining progress. [That actual cohort](../2026-10-24-goal-qwen-runtime/README.md)
is separate from [the inference-only comparison](../2026-10-24-goal-approval-model-comparison/README.md).
Task count, Task approval and Goal linkage alone do not satisfy the Goal.

## Docker and microVM

The reproduced P1 was in the Docker coding-evaluation driver: its grading step crossed back to the host and imported model-modified code. The repair keeps verify, regression and build within the supported Docker grading boundary and restores both check.sh and check.js from canonical inputs. Docker-only describes this driver's implemented support, not the product's entire sandbox architecture.

The inspected microVM runtime executes through its guest/shim path; it was not the same reproduced host-grading path. This campaign did not run a microVM end-to-end grader. Exporting a guest candidate and executing it on the host would defeat either backend. Kernel isolation does not by itself preserve oracle, artifact or experiment identity.

## Exact execution records

- dca2013ebf915a37631a5d95d305d226928c1b6f: native9 selected suites passed40074289285; macOS candidate40074290418 built and checked.
-7501aec032012869d8b979e0d14e1a9a9464ace7: native29 selected suites40078581651 completed26PASS,3FAIL. All new Goal/provider/identity/submission suites passed; failures were metrics NaN fixture, closed-Plan schema contract and baseline provider expectation. macOS build40078868804 succeeded; server-only extraction checked CRC/SHA/embedded source, compatible checked support bundle reused.
- b9bba3d4b416e269ff1d586f17f81e55c09ad8b3: all four selected repairs passed40082520098. This is not29allPASS on one head.
- c6e54ff523772596ce70a9b158f89c74fedeab17: macOS build40095081238 succeeded. Fresh real wire offered33tools, including Task creation and Goal measurement. G2 still failed, leading to the typed Goal retention repair. The failed experiment was explicitly stopped and pause state reread; its invalid evidence submission was not approved.
-1eef45b69f395b1819537c116c7df839023da110: Goal-only retention plus browser evidence frozen for native7 run40097972974 and macOS build40097972842. Native7 completed6PASS/1FAIL: new HTTP receiver Goal-carrier assertions passed, but real Task creation reported MASC not initialized because fixture setup omitted initialization. Its link assertion correctly failed; Corrected HTTP6cases passed40098831581 at9f024959528a5c0ea12ce59f0c1a63b2a364695d, whose product files match1eef. This is not all7 rerun on one head. macOS build40097972842 succeeded; server SHA24e409da4e773983b10bb0e7d5af0d1c93ce1e7257c5ba4083e93bd649083cb6. [Real-model experiment](../2026-10-24-goal-retention-runtime/README.md) failed workflow; delivery and Task success remain distinct.

-3badb88117794510dac576bf3fc34f0336e17d8a: six selected native suites passed40101087040; macOS build40101087227 succeeded. Server-only extraction/checks and real Gemma canary: G2 pass, G3 measured failure; actual browser/API/System-wire evidence is in the linked runtime directory.
- d3a242837194e94c435a228228ac0eaab10724aa: official Resume repair, two selected suites passed40102214212. cf60643a1680b6c1cfa678feb5c97034b3bd8d22: official blank-instructions repair, two selected suites passed40103733597 (87 Host +13 projection tests). Neither result is a live vendor-session or whole-regression verdict.
-54e8b9b7cafab6122b8eccc9e15d8ec549e03ad8: native Task-outcome and tool parity checks passed40105703498; macOS candidate40105705308 built. Actual Qwen executes Goal-linked work and records3/3 but fails strict completion reporting. [Runtime evidence](../2026-10-25-goal-lookup-runtime/README.md).
-3014cfce79636f1e41cc39f6019a3428c6912145: native40110334799 passed50 Goal gate cases and one canonical tool parity case; direct HTTP cases5PASS/1FAIL exposed a parent empty-Goal assertion mismatch. The test-only correction is ec664e53b7eda6a7dae4eb09daa04b56ad98997d; all six corrected HTTP cases then passed run40111175993 separately. The3014 macOS server was checked against packaged SHA and embedded source, SHA256 bd9042e019d31c377e8c9ca72409bc5b152052dc79dd70621f027cc008c475b6. The actual3014 Qwen cohort completed G2FAIL/G3FAIL; the model never invoked the receipt. See the latest runtime evidence.

No full regression, production installation, deployment, stack merge or actual human Goal completion is claimed. Ordinary independent source reviews, native execution, isolated runtime and browser observations are separate evidence. The lower boundary PR45755 still has a historical standalone request-changes; its two additional identity repairs are in upper layer45779. Integrate the reviewed native stack whole through its top; do not merge lower layers separately.

At the historical ledger read, local-admin had cancelled the original four session Tasks at13:39Z as orphan cleanup, naming other stack PR coordinates. That cancellation is preserved and is not execution completion. Successor task-2620 was claimed and started by the dedicated session identity and later submitted as vrf-6267bb77e2da35dc33f8991eddf2a446. The main Goal is now Verifying/proof_pending at its unchanged criterion revision; no Task approval or human Goal confirmation is claimed.

-32805eb764eab2710262446e925b0ea5c3a44c08: native40116634161 completed six suites245 tests; Claude had3 explicit failures then600s timeout. Checked macOS server40116636410, SHA98cd486335f7a40d2d49cc05501a52e1b4aee958732453405db8ded17e4de8b7; actual configured GLM-5.3 strictG2/G3 scopedPASS and API/persisted/visible-UI proof. Separate snapshot and Claude fixture repairs follow without converting this run to full native PASS.
- be9a9d9da9d426c8babb691a9ebc4620ca4a517c: native40147287888 completed5 suites,251 tests:247PASS/4FAIL, no suite timeout. The actual first-retry submission/scheduling fixture passed. [Four fixture repairs and the three-suite follow-up](../2026-10-25-native-verification-followup/README.md) preserve this failed run rather than overwrite it.
- 17583b006eaf0823587ba07a27ad50889ef8d498: native40149490208 completed3 selected suites239PASS/0FAIL, no timeout. The actual durable replay/correlation and Claude hook-terminal fixes passed. Later PR45874 commits add documentation/evidence/changelog only; the two untouched parent suites and full regression were not rerun at17583.
