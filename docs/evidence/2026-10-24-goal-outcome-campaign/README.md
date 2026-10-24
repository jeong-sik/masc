# Goal outcomes and verification integrity campaign

The audit of [Mental Models in the Agentic Era](https://productmindset.substack.com/p/mental-models-in-the-agentic-era) identified seven specific weaknesses at source8eac5c07c290d134a9ef6acb1e298584bf9a1366. The implementation and measurements are in [Native Stack45750](https://github.com/jeong-sik/masc/pull/45839), linked to [issue45747](https://github.com/jeong-sik/masc/issues/45747).

The metric is defined by fixed cases G1–G4 and A1–A7. Task count and Goal linkage ratio are diagnostic, not success targets. Independent Tasks remain valid. The canonical host metric is the experiment-owned acceptance.json referenced by Goal goal-outcome-driven-work-20261024, revision306708facbfb9379a9e51b8f7c815678. This directory preserves a dated snapshot, not another mutable authority.

| Case | Observed status | Evidence and scope |
| --- | --- | --- |
| G1 Current Goal criterion, revision, measurement and explicit unknown reach Keeper | Pass | Actual7501 direct-provider request plus deterministic native missing/stale/error controls. [Direct context](../2026-10-24-direct-goal-context/README.md). |
| G2 Model creates a related Task with matching Goal | Latest measured failure; earlier passes preserved | Source3014 Qwen receives Goal/revision but omits the association through terminal. Earlier54 Qwen and Gemma passes remain historical. [Latest runtime](../2026-10-25-goal-receipt-runtime/README.md). |
| G3 Approval returns attention to actual Goal measurement and remaining work without inferring Goal completion | Latest measured failure | Source3014 controlled linked-Task approval reaches the model; actual exact-ID Done lookup works, but model resubmits Done and ends with no measurement or remaining work. New receipt is never invoked. [Latest diagnosis](../2026-10-25-goal-receipt-runtime/README.md). |
| G4 Independent Tasks remain supported | Pass | Isolated external-agent create/claim/start, actual Node Docker computation, submission and controlled operator approval. This is not Keeper inference proof. |
| A1 Grading execution boundary | Pass, Docker scope | [Actual grading stages](../2026-10-24-coding-boundary/README.md) use captured bytes inside fresh unprivileged containers. |
| A2 Oracle-only success forgery | Pass | Both broken Node implementations remained unchanged and both oracle-only edits were rejected; both reference controls passed. |
| A3 Image byte identity | Pass | Native image length/hash/symlink and typed judge/operator/TUI mismatch propagation. Run40074289285 atdca2013e. |
| A4 Cohort/cost identity | Pass, controlled source and CLI scope | [Cohort identities](../2026-10-24-coding-cohort-identities/README.md) and [duplicate JSON protection](../2026-10-24-coding-json-integrity/README.md); no full live-provider benchmark claimed. |
| A5 Resume input identity | Pass, controlled source and CLI scope | Frozen source/scripts/prompts/corpus/config/runtime/binaries/models/memory/image identity, typed receipt/run identity and duplicate-key rejection. |
| A6 Producer/judge model observation | Pass, controlled native scope | Actual native provider parsing, admitted ToolUse ordinal, submission/verdict persistence and calibration tests at7501. Missing raw model identity remains unknown; response ID is a correlation label. This does not prove independent weights. |
| A7 Lifecycle approval, external acceptance and human Goal confirmation | Pass within explicit scopes | [Actual API](../2026-10-24-outcome-api-runtime/README.md) and [visually inspected dashboard](../2026-10-24-outcome-dashboard-runtime/README.md): lifecycle approval1, external acceptance unobserved1, Goal unchanged. Controlled operator proxy is not an independent LLM or actual human Goal verdict. |

Latest acceptance: **9/11**, measured after candidate3014 completed. G2 is
reopened and G3 remains failed. The earlier **10/11 historical case evidence
coverage** is preserved, not presented as current candidate success. G1/G4 and
A1–A7 keep their explicitly bound older scopes; this is not a single-head full
regression result. [The latest cohort](../2026-10-25-goal-receipt-runtime/README.md)
received the current Goal and new receipt instructions, omitted the Task link,
and failed continuation after controlled link/approval. Exact-ID Done lookup
worked; the model still resubmitted Done and never called goal_measure. A typed
completion-authority retention repair is in progress, with no success inferred.

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

At the current ledger read, local-admin had cancelled the original four session Tasks at13:39Z as orphan cleanup, naming other stack PR coordinates. That cancellation is preserved and is not execution completion. Remaining G3 work continues as Goal-linked task-2620, predecessor task-2595, claimed and started by the dedicated session identity. The shared Goal remains Executing at its original criterion revision.
