# RFC-0048 — Dashboard Information Architecture Phase 2

Status: Draft
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-08
Supersedes: —
Related: RFC-0046 (FsmHub SSOT), RFC-0049 (Surface Telemetry Foundation),
PRs #14219 / #14220 / #14235 / #14236 / #14238 (anti-explainer + dead-section purge)

## 1. Problem

The dashboard surface graph has accreted faster than its consolidation
work. Phase 1 already merged a handful of `monitoring:*` redirects and
hid two Monitor sub-sections. The remaining graph is still wider than
operators can hold in working memory, and ongoing cleanup PRs are
treating *symptoms* (explainer copy, dead routes) without touching the
*shape*.

### 1.1 Surface inventory (origin/main @ 6665e6ebfc)

`dashboard/src/config/navigation.ts`:

| Surface | Sections (visible) | Sections (hidden) | Notes |
|---|---|---|---|
| cockpit | (no sections) | — | single-pane |
| overview | (no sections) | — | single-pane |
| **monitoring** | journey, agents, cognition, runtime, goal-loop, fleet-health (**6**) | observatory, memory-subsystems (**2**) | Phase 1 absorbed telemetry/fleet/tool-quality/governance into `fleet-health` |
| command | operations | — | single-section surface |
| connectors | connector-status | — | single-section surface |
| workspace | board, sub-boards, planning, repositories, verification (**5**) | — | |
| lab | tools, autoresearch, harness | — | `legacy` section purged in PR #14238 |
| code | ide-shell | — | single-section surface |
| logs | (no sections) | — | single-pane |

Total: **9 top-level surfaces**, **19 visible sections**, **2 hidden
sections** retained as redirect targets.

Existing redirects (line 339-345 of navigation.ts) prove the pattern is
already in use:

```
'monitoring:sessions'   -> agents
'monitoring:activity'   -> observatory
'monitoring:live'       -> observatory (view=live)
'monitoring:telemetry'  -> fleet-health (view=event-log)
'monitoring:fleet'      -> fleet-health (view=comparison)
'monitoring:tool-quality' -> fleet-health
'monitoring:governance' -> fleet-health
```

### 1.2 Decision deficit

We do not know which of the 19 visible sections operators actually open.
Every consolidation proposal so far has been driven by static reading of
the navigation file, not by usage data. That produced two errors in the
external Kimi audit (Downloads/Kimi_Agent_대시보드 메뉴 정비, 2026-05-07):

1. Audit listed Monitor as 8 sections; 2 of them were already
   `hidden: true`.
2. Audit treated `fleet-health` as if it still co-existed with
   telemetry/fleet/tool-quality; it had already absorbed them in Phase 1.

The fix is not "draft a tighter audit." It is "stop debating section
counts without data." This RFC blocks on RFC-0049 producing real open
counters first.

### 1.3 Component LoC blowup (separate RFC, listed for context only)

`dashboard/src/components/` has **321 .ts files** totalling **82,086 LoC**.
Eleven files exceed 1000 LoC each. The larger ones (connector-status
1689, cost-dashboard 1442, cascade-config-panel 1386, keeper-detail
1263, fleet-fsm-matrix 1250) cluster around the surfaces this RFC
considers. **Component decomposition is RFC-0050 scope.** RFC-0048
treats only IA — section list, ordering, default surface, redirects.
File splits driven by LoC caps are out of scope and have already been
rejected as a workaround pattern (see `prometheus.ml` extraction issue
#14166, closed by user).

## 2. Goals

1. Make every IA change **data-driven**: drop or merge a section only
   after RFC-0049 telemetry shows ≤ X opens / 7 days for that section.
2. Keep the **redirect ledger** authoritative — any removed section
   must continue to resolve via a `CROSS_SURFACE_SECTION_REDIRECTS`
   entry (or the existing `'<surface>:<section>'` map) for at least one
   release after deletion.
3. Maintain hash-route stability for deep-linked operator bookmarks and
   external dashboards that link into specific sections.
4. Reduce visible-section count without removing capability. Every
   "removed" section must point to the surface that now hosts the same
   data.

## 3. Non-goals

- No file splits, no component decomposition (→ RFC-0050).
- No new backend RPC. RFC-0048 is wholly client-side IA.
- No design-language changes (color, type, spacing). The "ferris wheel"
  metaphor floated in the Kimi plan is **not adopted** in RFC-0048; if
  warranted it can become a separate design RFC after the IA settles.
- No change to surfaces with zero or one section (cockpit, overview,
  command, connectors, code, logs).

## 4. Design

### 4.1 Phase 2 sequencing

```
PR-A (this RFC, docs only)
   |
PR-B = RFC-0049 PR-1 (instrument)
   |
   v
   [7-day collection window]
   |
   v
PR-C  candidate selection (Markdown report + thresholds)
   |
   v
PR-D  hidden=true on bottom-N sections (still routable via redirect)
   |
   v
   [7-day soak window — operator complaint window]
   |
   v
PR-E  delete component code + add redirect entry
   |
   v
PR-F (optional)  reorder surface graph if ordering data warrants it
```

PR-D and PR-E are the only PRs that touch user-visible IA. Both gated
on RFC-0049 metric thresholds, defined in §4.4.

### 4.2 Threshold proposal (subject to data)

After 7 days of `surface_open_total` and `section_open_total`:

| Action | Threshold | Soak |
|---|---|---|
| Mark `hidden: true` (sidebar removal, route preserved) | < 5 opens / week, ≥ 2 active operators on the dashboard | 7 days |
| Delete component, replace with redirect | section stayed `hidden: true` 7 days with **zero** redirect target hits | — |
| Promote section to surface default | > 40% of that surface's opens land on this section | — |
| Merge two sections | both individually < 20 opens / week, share > 60% of operators | requires ad-hoc proposal |

These numbers are **placeholders**. PR-C will revise them once the
distribution is visible.

### 4.3 Redirect ledger contract

Every section ID ever shown in the sidebar MUST resolve forever. The
deletion order is:

1. PR-D: `hidden: true` — sidebar gone, hash route still works.
2. PR-E: section component code deleted, but
   `CROSS_SURFACE_SECTION_REDIRECTS` (router.ts:24) gains an entry
   mapping the old `<surface>:<section>` key to its successor.

A test (`router.test.ts`) enforces: for every section ID in
`navigation.ts` *or* in the redirect map, `hashForRoute` must produce
a route whose final tab/section pair is currently rendered.

### 4.4 Telemetry handshake

This RFC depends on RFC-0049 exposing the following counters (full
schema in RFC-0049):

```
dashboard_surface_open_total{surface}
dashboard_section_open_total{surface, section}
dashboard_section_open_total{surface, section, redirected_from}
```

PR-C consumes these via PromQL and emits a Markdown report into
`docs/audits/2026-MM-dashboard-ia-usage.md`. Threshold-crossing rows
become the candidate list for PR-D.

## 5. Compatibility & risk

### 5.1 Hash-route compatibility

All deletions go through the redirect map, so existing bookmarks and
external links keep resolving. We add an integration test that loops
over every section ID present in the last 6 months of git history and
asserts it still routes.

### 5.2 Operator surprise

Hiding a low-traffic section is easy to revert (`hidden: false` toggle).
Deletion is harder. The 7-day `hidden: true` soak in PR-D is the
escape hatch — any operator who still uses the section can complain
during the soak; reverting before PR-E is one-line.

### 5.3 Telemetry blind spots

`section_open_total` cannot distinguish "operator opened section
intentionally" from "auto-redirect landed there." The `redirected_from`
label in §4.4 is what makes the difference observable. PR-C must
exclude redirect-driven opens when computing the threshold for PR-D —
otherwise we would protect a dead section just because old links keep
firing it.

### 5.4 Cold-start bias

The first 7 days of telemetry will under-count weekly tasks and
over-count whatever happened to be in focus. PR-C should re-sample for
a second 7-day window before any deletion fires. Hide-only (PR-D)
decisions can run on a single window.

## 6. Open questions

1. **Per-operator privacy.** Should `section_open_total` include an
   operator label, or stay aggregate? Aggregate is enough for PR-D
   thresholds. Per-operator would let us answer "is this section used
   by anyone, or only by one person on Tuesday afternoons?" — but adds
   PII. Default: aggregate only.
2. **Redirect-loop guard.** If section A redirects to section B and we
   later delete B, the chain must collapse, not chain. Test infra in
   PR-C must walk redirect chains to a fixed point.
3. **Mobile / narrow viewport.** Current dashboard does not target
   mobile, so we ignore viewport-conditional IA. Flag for future RFC if
   priorities change.
4. **`overview` and `cockpit` ratio.** Both are single-pane top-level
   surfaces. If one of them dominates `surface_open_total`, the other
   may be a candidate to fold into it. RFC-0048 does not pre-commit to
   this — it depends on data.

## 7. Out of scope (cross-references)

- Component file decomposition: RFC-0050 (TBD).
- Design-language refresh: separate design RFC, post-IA.
- Backend telemetry consolidation: RFC-0044 (persistence read-drop).
- Composite snapshot rendering on keeper detail: RFC-0046 (merged
  through Step 5).

## 8. Done criteria

RFC-0048 is "Done" when:

1. Two consecutive 7-day usage reports show no section below the
   `hidden: true` threshold that has not already been hidden or has a
   recorded operator carve-out.
2. The `dashboard_section_open_total` redirect-from ratio for every
   visible section is < 50% (i.e., visible sections are reached
   directly, not as redirect destinations).
3. `router.test.ts` enforces the redirect-ledger contract from §4.3.
4. No component file deletion has produced an unresolved hash route in
   the last 30 days of dashboard logs.

If any of those four metrics regresses, RFC-0048 reopens.
