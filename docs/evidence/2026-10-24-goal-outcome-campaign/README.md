# Goal outcomes and verification integrity campaign

The audit of [Mental Models in the Agentic Era](https://productmindset.substack.com/p/mental-models-in-the-agentic-era) identified seven specific weaknesses at source8eac5c07c290d134a9ef6acb1e298584bf9a1366. The implementation and measurements are in [Native Stack45750](https://github.com/jeong-sik/masc/pull/45791), linked to [issue45747](https://github.com/jeong-sik/masc/issues/45747).

The metric is defined by fixed cases G1–G4 and A1–A7. Task count and Goal linkage ratio are diagnostic, not success targets. Independent Tasks remain valid. The canonical host metric is the experiment-owned acceptance.json referenced by Goal goal-outcome-driven-work-20261024, revision306708facbfb9379a9e51b8f7c815678. This directory preserves a dated snapshot, not another mutable authority.

| Case | Observed status | Evidence and scope |
| --- | --- | --- |
| G1 Current Goal criterion, revision, measurement and explicit unknown reach Keeper | Pass | Actual7501 direct-provider request plus deterministic native missing/stale/error controls. [Direct context](../2026-10-24-direct-goal-context/README.md). |
| G2 Model creates a related Task with matching Goal | Failed; repair under validation |7501 schema was unavailable; c6 eager schema was present but accepted Task had no Goal and later requests lacked the Goal snapshot. The model-choice cause is not isolated. [Baseline and repair](../2026-10-24-goal-tool-round-context/README.md). |
| G3 Approval returns attention to actual Goal measurement and remaining work | Unproven | Requires a linked partial Task, actual approval and subsequent Keeper behavior. Source instructions or deterministic responses do not prove it. |
| G4 Independent Tasks remain supported | Pass | Isolated external-agent create/claim/start, actual Node Docker computation, submission and controlled operator approval. This is not Keeper inference proof. |
| A1 Grading execution boundary | Pass, Docker scope | [Actual grading stages](../2026-10-24-coding-boundary/README.md) use captured bytes inside fresh unprivileged containers. |
| A2 Oracle-only success forgery | Pass | Both broken Node implementations remained unchanged and both oracle-only edits were rejected; both reference controls passed. |
| A3 Image byte identity | Pass | Native image length/hash/symlink and typed judge/operator/TUI mismatch propagation. Run40074289285 atdca2013e. |
| A4 Cohort/cost identity | Pass, controlled source and CLI scope | [Cohort identities](../2026-10-24-coding-cohort-identities/README.md) and [duplicate JSON protection](../2026-10-24-coding-json-integrity/README.md); no full live-provider benchmark claimed. |
| A5 Resume input identity | Pass, controlled source and CLI scope | Frozen source/scripts/prompts/corpus/config/runtime/binaries/models/memory/image identity, typed receipt/run identity and duplicate-key rejection. |
| A6 Producer/judge model observation | Pass, controlled native scope | Actual native provider parsing, admitted ToolUse ordinal, submission/verdict persistence and calibration tests at7501. Missing raw model identity remains unknown; response ID is a correlation label. This does not prove independent weights. |
| A7 Lifecycle approval, external acceptance and human Goal confirmation | Pass within explicit scopes | [Actual API](../2026-10-24-outcome-api-runtime/README.md) and [visually inspected dashboard](../2026-10-24-outcome-dashboard-runtime/README.md): lifecycle approval1, external acceptance unobserved1, Goal unchanged. Controlled operator proxy is not an independent LLM or actual human Goal verdict. |

Current score:9/11. The latest1eef real Gemma run retained Goal context and selected the matching Goal ID, but repeatedly omitted the required Task description; no Task persisted. It was stopped with explicit pause readback. The [one-seed placement diagnostic](../2026-10-24-goal-carrier-diagnostic/README.md) supports a stable carrier repair under development; it proves no G2/G3 success. Goal proof and human confirmation are not requested as if11/11 had passed.

## Docker and microVM

The reproduced P1 was in the Docker coding-evaluation driver: its grading step crossed back to the host and imported model-modified code. The repair keeps verify, regression and build within the supported Docker grading boundary and restores both check.sh and check.js from canonical inputs. Docker-only describes this driver's implemented support, not the product's entire sandbox architecture.

The inspected microVM runtime executes through its guest/shim path; it was not the same reproduced host-grading path. This campaign did not run a microVM end-to-end grader. Exporting a guest candidate and executing it on the host would defeat either backend. Kernel isolation does not by itself preserve oracle, artifact or experiment identity.

## Exact execution records

- dca2013ebf915a37631a5d95d305d226928c1b6f: native9 selected suites passed40074289285; macOS candidate40074290418 built and checked.
-7501aec032012869d8b979e0d14e1a9a9464ace7: native29 selected suites40078581651 completed26PASS,3FAIL. All new Goal/provider/identity/submission suites passed; failures were metrics NaN fixture, closed-Plan schema contract and baseline provider expectation. macOS build40078868804 succeeded; server-only extraction checked CRC/SHA/embedded source, compatible checked support bundle reused.
- b9bba3d4b416e269ff1d586f17f81e55c09ad8b3: all four selected repairs passed40082520098. This is not29allPASS on one head.
- c6e54ff523772596ce70a9b158f89c74fedeab17: macOS build40095081238 succeeded. Fresh real wire offered33tools, including Task creation and Goal measurement. G2 still failed, leading to the typed Goal retention repair. The failed experiment was explicitly stopped and pause state reread; its invalid evidence submission was not approved.
-1eef45b69f395b1819537c116c7df839023da110: Goal-only retention plus browser evidence frozen for native7 run40097972974 and macOS build40097972842. Native7 completed6PASS/1FAIL: new HTTP receiver Goal-carrier assertions passed, but real Task creation reported MASC not initialized because fixture setup omitted initialization. Its link assertion correctly failed; Corrected HTTP6cases passed40098831581 at9f024959528a5c0ea12ce59f0c1a63b2a364695d, whose product files match1eef. This is not all7 rerun on one head. macOS build40097972842 succeeded; server SHA24e409da4e773983b10bb0e7d5af0d1c93ce1e7257c5ba4083e93bd649083cb6. [Real-model experiment](../2026-10-24-goal-retention-runtime/README.md) failed workflow; delivery and Task success remain distinct.

No full regression, production installation, deployment, stack merge or actual human Goal completion is claimed. Ordinary independent source reviews, native execution, isolated runtime and browser observations are separate evidence. The lower boundary PR45755 still has a historical standalone request-changes; its two additional identity repairs are in upper layer45779. Integrate the reviewed native stack whole through its top; do not merge lower layers separately.
