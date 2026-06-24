# RFC: Keeper-conversation HITL review flow (post-"대화에서 검토")

- Status: Draft
- Author: vincent (+ Claude Opus 4.8)
- Created: 2026-06-24
- Related: approvals surface fidelity series (PRs #22201/#22202/#22204/#22211/#22216 — the approvals surface itself, now landed)
- Research basis: audit recorded in `~/.claude/.../memory/project-masc-hitl-approvals-design-fidelity-loop.md` (iter 10–11)

## 1. Summary

The HITL review loop is: **approvals queue → "대화에서 검토 →" → keeper conversation → decide**. The approvals queue end is comprehensively built and tested. This RFC covers the *other* end — what the operator sees after clicking into the keeper conversation — and proposes two changes that the static design mock does not specify (the mock's `onOpenKeeper` is a navigation stub, so there is no pixel target for this surface). Both require a product-IA decision, which is why they are framed here rather than slapped in.

It also records a **resolved** non-issue (the dual-source SSOT question) so it is not re-raised.

## 2. Current state (grounded)

- `ApprovalCard` "대화에서 검토 →" and the keeper link call `openKeeperWorkspace(name)` → `navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })` (`dashboard/src/components/approvals/approvals-surface.ts`).
- `agents-unified.ts:64`: a `keeper` route param renders `KeeperDetailPage`.
- `keeper-detail-page.ts:174-176`: the **default view is the conversation** (`detailOpen=false`); "운영 상세" flips `detailOpen=true` to the tabbed `KeeperDetailBody`.
- The pending-approval detail (`승인 ID` / `차단 도구` / `작업`) is shown by `KeeperRuntimeAlertStrip` (`keeper-detail-alert-strip.ts:115`, source `keeper.trust.approval_state.pending_first`), **rendered only inside `KeeperDetailBody`** (`keeper-detail-body.ts`) — i.e. the "운영 상세" view.
- Therefore, on landing from "대화에서 검토" the operator is on the conversation view, where the structured pending-approval detail is **not** surfaced (it is one toggle away, behind "운영 상세").
- The conversation / comms panes consume `route.value.params.keeper` and `params.view` but **no `params.turn`** — there is no deep-link to a specific turn / pending tool-call.

So the flow is *wired* (correct keeper, correct conversation), but the conversation view itself carries no pending-review cue, and there is no anchor to the specific tool-call under review.

## 3. Resolved non-issue: dual-source is NOT an SSOT violation

The alert strip reads `keeper.trust.approval_state.pending_first`; the approvals surface reads `governanceData.approval_queue`. These look like two sources but are two serializations of **one** backend store:

- `lib/dashboard/dashboard_governance.ml`: `approval_queue` ← `Keeper_approval_queue.list_pending_dashboard_json ()`
- `lib/keeper/keeper_runtime_trust_timeline.ml`: trust/approval_state ← the same `Keeper_approval_queue.list_pending_dashboard_json ()`

One module (`keeper_approval_queue`, the in-memory HITL queue) is the single source of truth; momentary divergence between the two screens is normal eventual-consistency from independent refresh cycles, not a definitional SSOT violation. **No change proposed.** Recorded here so it is not re-investigated.

## 4. Proposals (each gated on a product-IA decision)

### 4.1 Pending-review cue in the conversation view

**Problem**: the operator lands in the conversation with no indication that this keeper is awaiting their decision; the structured pending detail lives behind "운영 상세".

**Options**:
- **A. Slim banner in the conversation view** — when `keeper.trust.approval_state.pending_first` is set, render a one-line cue ("이 keeper는 승인 대기 중 · <도구> · 결재 큐에서 처리 →") in the conversation pane, linking back to the approvals surface. Data already available; no new endpoint. Low risk, additive.
- **B. Open "대화에서 검토" directly into "운영 상세"** — make the approvals link carry a param that opens `detailOpen=true` (requires wiring `detailOpen` to a route param, since it is currently local `useState`). Changes the meaning of the "대화" label (lands on detail, not dialogue).
- **C. Do nothing** — treat conversation (dialogue context) and "운영 상세" (structured detail) as deliberately complementary; the label "대화에서 검토" means "read the dialogue", and structured detail is intentionally one toggle away.

**Decision needed**: which of A/B/C. (Author leans A — keeps the dialogue-first label, adds a non-intrusive cue, no governance action on a second surface.)

### 4.2 Turn-anchoring (deep-link to the pending tool-call)

**Problem**: the pending approval has a `turn_id`, but `openKeeperWorkspace` does not pass it and the conversation does not consume it, so the operator must scroll to find the relevant turn in a long conversation.

**Constraint (no silent failure)**: passing `turn` from approvals is only correct if the conversation *consumes* it (scrolls/highlights). A param nothing reads would be a silent no-op — so this is a **2-surface change** (approvals passes `turn`; keeper-detail conversation reads `params.turn` → `scrollIntoView` + highlight) and must land together.

**Decision needed**: pursue now, or defer. (Author leans defer — larger, and 4.1 delivers most of the value.)

## 5. Non-goals

- Inline approve/reject from the keeper conversation. Adding HITL *actions* to a second surface duplicates the single decision point (approvals queue) and is governance-action territory — out of scope; keep approvals as the sole act-point.
- Any change to `keeper_approval_queue` (the backend SSOT) — §3 confirms it is correct.
- Re-adding the design mock's defer/undo/resolved-history (no backing endpoint; intentionally omitted in the approvals surface).

## 6. Test plan (for whichever option is chosen)

- 4.1-A: render `KeeperDetailPage` for a keeper whose `trust.approval_state.pending_first` is set, assert the conversation view shows the cue + a link to the approvals surface; assert it is absent when no pending approval. Non-vacuous via revert.
- 4.2: assert `openKeeperWorkspace` passes `turn`; assert the conversation reads `params.turn` and scrolls/highlights that turn node.

## 7. Open decisions (blocking implementation)

1. §4.1: option A / B / C?
2. §4.2: now or defer?

Until these are answered, no code lands — this is a design-only RFC. The approvals surface (the pixel-perfect HITL screen the loop targeted) is complete; this RFC covers the adjacent keeper-detail surface, which the design mock does not specify.
