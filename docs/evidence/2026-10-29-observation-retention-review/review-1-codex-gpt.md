  2276	  if not !timed then t.ended_at <- None;
  2277	  Option.iter (reconcile_operation t) (Masc_tui_keeper_chat_log.operation_state log);
  2278	  t
  2279	;;
  2280	
  2281	(* What the durable transcript knows about a call that the wire did not
  2282	   carry: how it ended and how long it took. Matched by execution id, the
  2283	   server-owned identity both records share. A fact the wire already had is
  2284	   not taken back: the durable [Never_returned] and the unrecorded outcome

exec
/bin/zsh -lc '/Applications/Xcode.app/Contents/Developer/usr/bin/git --no-optional-locks status --porcelain --untracked-files=no -- docs/constitution.xml lib/types/prompt_block_id.mli lib/keeper/keeper_gate_replay.mli lib/keeper/keeper_microvm_declared_guests.mli bin/masc_tui_evidence_file.mli bin/masc_tui_types.ml bin/masc_tui_keeper_chat_transcript.ml test/test_tui_keeper_chat_transcript.ml docs/evidence/2026-10-26-ego-activity/README.md' in /Users/dancer/me/workspace/yousleepwhen/masc
 succeeded in 80ms:
codex
**Verdict: keep the idea of a short boundary contract, but replace both the universal retention invariant and the mandatory round-trip property test.** I agree that the evidence does not justify a single global retention layer. I disagree that the history establishes either that all 29 fixes were minimal and correct or that the absence of a proof obligation caused their recurrence.

The invariant should be about **correct interpretation across a domain transition**, not set inclusion:

> For each boundary, preserve or rederive the facts the next consumer is entitled to use, with their identity, provenance, scope and lifetime. Apply legitimate updates, revocations and redactions. If the authoritative source or effect outcome is genuinely unavailable, represent that uncertainty without inventing absence, success or authority.

A superset rule is too strong for current state and too weak for correctness. In #45791, an authoritative empty Goal observation must supersede an old active Goal; missing or unavailable is different from empty. In #46132, retaining an execution identity must not authorize redispatch when its effect is unknown. In #46169, a confirmed save and a subsequent lock-release error must **both** remain true. The [export contract](/Users/dancer/me/workspace/yousleepwhen/masc/bin/masc_tui_evidence_file.mli:6) makes that distinction explicit.

The repository already has some boundary obligations: [Prompt_block_id.mli](/Users/dancer/me/workspace/yousleepwhen/masc/lib/types/prompt_block_id.mli:75) requires new context blocks to choose post-tool and held-session behavior, including deliberately first-round-only context. So “nothing obligates a path” is too broad. The gap worth investigating is whether changed *paths* actually honor those existing classifications at their consumers.

I would change the proposed RFC into a short review checklist. For a changed boundary, identify the source of truth, acceptance point, consumer, scope, lifetime, permitted transitions and unavailable/unknown behavior. Cite an existing relevant functional test or add one tied to a demonstrated or concrete reachable failure. Use generated properties where they exercise a real contract; do not require `rebuild(state) ⊇ observations` for every boundary.

Useful tests would include:

- **#45791:** after the last active Goal ends, Resume delivers authoritative empty; an unavailable read does not masquerade as empty.
- **#46169:** inject failure after save confirmation and assert both retained `Saved` state and the release error.
- **#46132:** interrupt after dispatch, retain the original identity, and assert that an unknown outcome does not cause a second execution.

A round-trip test can still pass when both paths share the same faulty projection, when its generator never reaches the dangerous interleaving, or when it checks an internal record but not the actual consumer. It also misses crash timing, stale concurrent refreshes, duplication, redaction, performance and liveness. Use independent expected outcomes and deterministic fault injection where appropriate. The cited [transcript-fold test](/Users/dancer/me/workspace/yousleepwhen/masc/test/test_tui_keeper_chat_transcript.ml:1955) is a useful invariant example, but that particular test uses a fixed event sequence; it is not a generated property test.

A global journal would add ordering, atomicity, retention and privacy questions without solving the external-effect crash gap. A cheaper structural improvement is to consolidate a **proven drifting family** of context paths around the existing typed assembly and lifetime classifications, then test the actual consumer boundary. The transcript’s local single-writer/fold design is a good example of a domain-specific structural solution, not evidence that every domain should share its journal.

I would also revise the mapping:

- **#46327** is chiefly a TUI projection/visibility issue: historical retry evidence must remain visible without becoming the failure’s cause.
- **#45950** includes live stream reconciliation and redaction as well as replay.
- **#46098** involved activity that was not recorded and inventory that was not refreshed on cadence; the new independent refresh must preserve the existing selection and pending read. The [recorded evidence](/Users/dancer/me/workspace/yousleepwhen/masc/docs/evidence/2026-10-26-ego-activity/README.md:3) does not establish wholesale state replacement as the original cause.
- **#46168** preserves declared guest intent; **#46132** preserves execution identity and handles uncertain effects. Those warrant different recovery contracts.

The 29/202 figure is a useful signal for a focused audit, not proof of one cause or of each fix’s correctness. My review checked the eight named commits and relevant source contracts, not all 29 fixes or their runtime behavior.


tokens used
131,224
**Verdict: keep the idea of a short boundary contract, but replace both the universal retention invariant and the mandatory round-trip property test.** I agree that the evidence does not justify a single global retention layer. I disagree that the history establishes either that all 29 fixes were minimal and correct or that the absence of a proof obligation caused their recurrence.

The invariant should be about **correct interpretation across a domain transition**, not set inclusion:

> For each boundary, preserve or rederive the facts the next consumer is entitled to use, with their identity, provenance, scope and lifetime. Apply legitimate updates, revocations and redactions. If the authoritative source or effect outcome is genuinely unavailable, represent that uncertainty without inventing absence, success or authority.

A superset rule is too strong for current state and too weak for correctness. In #45791, an authoritative empty Goal observation must supersede an old active Goal; missing or unavailable is different from empty. In #46132, retaining an execution identity must not authorize redispatch when its effect is unknown. In #46169, a confirmed save and a subsequent lock-release error must **both** remain true. The [export contract](/Users/dancer/me/workspace/yousleepwhen/masc/bin/masc_tui_evidence_file.mli:6) makes that distinction explicit.

The repository already has some boundary obligations: [Prompt_block_id.mli](/Users/dancer/me/workspace/yousleepwhen/masc/lib/types/prompt_block_id.mli:75) requires new context blocks to choose post-tool and held-session behavior, including deliberately first-round-only context. So “nothing obligates a path” is too broad. The gap worth investigating is whether changed *paths* actually honor those existing classifications at their consumers.

I would change the proposed RFC into a short review checklist. For a changed boundary, identify the source of truth, acceptance point, consumer, scope, lifetime, permitted transitions and unavailable/unknown behavior. Cite an existing relevant functional test or add one tied to a demonstrated or concrete reachable failure. Use generated properties where they exercise a real contract; do not require `rebuild(state) ⊇ observations` for every boundary.

Useful tests would include:

- **#45791:** after the last active Goal ends, Resume delivers authoritative empty; an unavailable read does not masquerade as empty.
- **#46169:** inject failure after save confirmation and assert both retained `Saved` state and the release error.
- **#46132:** interrupt after dispatch, retain the original identity, and assert that an unknown outcome does not cause a second execution.

A round-trip test can still pass when both paths share the same faulty projection, when its generator never reaches the dangerous interleaving, or when it checks an internal record but not the actual consumer. It also misses crash timing, stale concurrent refreshes, duplication, redaction, performance and liveness. Use independent expected outcomes and deterministic fault injection where appropriate. The cited [transcript-fold test](/Users/dancer/me/workspace/yousleepwhen/masc/test/test_tui_keeper_chat_transcript.ml:1955) is a useful invariant example, but that particular test uses a fixed event sequence; it is not a generated property test.

A global journal would add ordering, atomicity, retention and privacy questions without solving the external-effect crash gap. A cheaper structural improvement is to consolidate a **proven drifting family** of context paths around the existing typed assembly and lifetime classifications, then test the actual consumer boundary. The transcript’s local single-writer/fold design is a good example of a domain-specific structural solution, not evidence that every domain should share its journal.

I would also revise the mapping:

- **#46327** is chiefly a TUI projection/visibility issue: historical retry evidence must remain visible without becoming the failure’s cause.
- **#45950** includes live stream reconciliation and redaction as well as replay.
- **#46098** involved activity that was not recorded and inventory that was not refreshed on cadence; the new independent refresh must preserve the existing selection and pending read. The [recorded evidence](/Users/dancer/me/workspace/yousleepwhen/masc/docs/evidence/2026-10-26-ego-activity/README.md:3) does not establish wholesale state replacement as the original cause.
- **#46168** preserves declared guest intent; **#46132** preserves execution identity and handles uncertain effects. Those warrant different recovery contracts.

The 29/202 figure is a useful signal for a focused audit, not proof of one cause or of each fix’s correctness. My review checked the eight named commits and relevant source contracts, not all 29 fixes or their runtime behavior.



[exited with code 0]
