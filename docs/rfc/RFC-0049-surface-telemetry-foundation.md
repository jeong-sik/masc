# RFC-0049 — Dashboard Surface Telemetry Foundation

Status: Draft
Author: jeong-sik (with Claude Opus 4.7)
Date: 2026-05-08
Supersedes: —
Related: RFC-0048 (Dashboard IA Phase 2 — primary consumer)

## 1. Problem

The dashboard has nine top-level surfaces and nineteen visible
sections. We have no data on which of them operators open. Every
consolidation proposal so far has been static — read the navigation
file, guess at duplication, propose merges. The Kimi audit
(2026-05-07) is the most recent failure of this method: it listed
already-hidden sections as duplicates and treated already-merged
surfaces as separate.

`dashboard/src/router.ts` is the SSOT for surface transitions. The
`route` signal (line 225) updates synchronously on every navigation,
hashchange, and deep-link entry. There is no instrumentation hooked
into it. Backend `Prometheus.register_counter` and `Prometheus.inc_counter`
already exist (`lib/prometheus.ml`), so the missing piece is a
client → backend ingest endpoint and the client-side observer.

This RFC defines the minimum-surface-area telemetry needed to make
RFC-0048 decisions data-driven, with two non-negotiable properties:

1. Every transition is recorded exactly once (no double-count on
   redirect collapse).
2. No PII. No operator label, no session ID, no IP. Aggregate counts
   per `(surface, section)` only.

## 2. Goals

1. Produce three Prometheus counters (`dashboard_surface_open_total`,
   `dashboard_section_open_total`, `dashboard_section_open_total` with
   `redirected_from` label).
2. Single client observer hooked into the existing `route` signal —
   no router refactor, no new state store.
3. Single backend POST endpoint that increments counters. No
   per-event storage. No log file.
4. Survive hashchange spam (browser back/forward repeated): collapse
   identical consecutive `(surface, section)` pairs within 500 ms into
   one event.

## 3. Non-goals

- No per-operator analytics. Aggregate only.
- No latency / dwell-time / bounce-rate metrics in this RFC. Adding
  them later is OK; pre-committing to them now expands surface area
  without a consumer.
- No A/B test infrastructure.
- No client-side persistence (localStorage, IndexedDB). Counters live
  on the server.
- No redirect rewrite. The router's existing
  `CROSS_SURFACE_SECTION_REDIRECTS` map is observed, not modified.

## 4. Design

### 4.1 Counter schema

```
# HELP dashboard_surface_open_total Top-level dashboard surface opens.
# TYPE dashboard_surface_open_total counter
dashboard_surface_open_total{surface="<id>"} <count>

# HELP dashboard_section_open_total Section-level opens within a surface.
# TYPE dashboard_section_open_total counter
dashboard_section_open_total{surface="<id>",section="<id>",redirected_from="<surface>:<section>|none"} <count>
```

`redirected_from` carries the literal `<original_surface>:<original_section>`
key from `CROSS_SURFACE_SECTION_REDIRECTS` when the route resolution
came through a redirect, otherwise `"none"`. This is the label that
RFC-0048 §4.4 needs to exclude redirect-driven hits from deletion
thresholds.

### 4.2 Event semantics

A single "open" event fires when:

1. The `route` signal value changes such that either `tab` or
   `params.section` differs from the previous emission, AND
2. ≥ 500 ms have elapsed since the last identical `(tab, section)` was
   emitted, OR the new pair differs from the last emitted pair.

The 500 ms window collapses three browser-history bursts into one (back,
forward, back-again) without losing genuine same-pair re-opens
separated by real operator action.

The first emission after page load fires unconditionally and carries
the route resolved by `initRouter`.

### 4.3 Client → backend POST

```
POST /api/dashboard/nav-event
Content-Type: application/json
Body: { "surface": "<id>", "section": "<id>|null", "redirected_from": "<key>|null" }
Response: 204 No Content
```

Failure modes:

- 4xx → drop event, log to console at `info`. No retry. We accept
  rare loss; we don't queue.
- 5xx → drop event. Same as above.
- Network offline → drop event. `navigator.sendBeacon` would survive
  page-unload but adds shutdown semantics we don't need yet.

`fetch(..., { keepalive: true })` is sufficient. No batching.

### 4.4 Backend handler

`lib/dashboard_nav_event.ml`:

```ocaml
let handle_nav_event ~surface ~section ~redirected_from =
  let labels =
    [ ("surface", surface)
    ; ("section", Option.value ~default:"" section)
    ; ("redirected_from", Option.value ~default:"none" redirected_from)
    ]
  in
  Prometheus.inc_counter "dashboard_surface_open_total"
    ~labels:[("surface", surface)] ~delta:1.0 () ;
  match section with
  | None -> ()
  | Some _ ->
    Prometheus.inc_counter "dashboard_section_open_total"
      ~labels ~delta:1.0 ()
```

Validation: `surface` must be a member of `VALID_TABS` (mirrored from
the TS `types.ts` constant). `section` must either be `null` or a
known section ID for the given surface (validated against a frozen
allowlist generated at startup from the navigation manifest).
`redirected_from` is parsed as `<surface>:<section>` and validated the
same way; unknown values are rejected with 400.

This is the entire backend surface. No other endpoint, no other
counter.

### 4.5 Client observer

A single file, `dashboard/src/lib/nav-telemetry.ts`:

```ts
import { effect } from '@preact/signals'
import { route } from '../router'

const COLLAPSE_WINDOW_MS = 500
let last: { surface: string; section: string | null; at: number } | null = null

function emit(surface: string, section: string | null, redirectedFrom: string | null) {
  void fetch('/api/dashboard/nav-event', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ surface, section, redirected_from: redirectedFrom }),
    keepalive: true,
  }).catch(() => { /* drop */ })
}

export function startNavTelemetry(): void {
  effect(() => {
    const r = route.value
    const surface = r.tab
    const section = r.params.section ?? null
    const redirectedFrom = r.params.__redirected_from ?? null
    const now = Date.now()
    if (
      last &&
      last.surface === surface &&
      last.section === section &&
      now - last.at < COLLAPSE_WINDOW_MS
    ) {
      return
    }
    last = { surface, section, at: now }
    emit(surface, section, redirectedFrom)
  })
}
```

`startNavTelemetry()` is called once from `main.ts` after `initRouter()`.

The observer reads `__redirected_from` from `route.params`. Adding
that field requires a one-line change in `applyCrossSurfaceRedirect`
(router.ts:75): when the redirect fires, write the source key into
`nextParams.__redirected_from`. The router already strips
`tab`-equivalent keys from the canonical hash (router.ts:215), so we
extend that filter to also strip `__redirected_from` — i.e., the field
is internal-only and never appears in URLs.

### 4.6 Test plan

`dashboard/src/lib/nav-telemetry.test.ts`:

- emits one event for the initial route on `startNavTelemetry()` call.
- collapses two identical `(surface, section)` pairs within 500 ms
  into one.
- emits separately when surface or section changes.
- carries `redirected_from` when the route arrived via a redirect.
- emits `redirected_from: "none"` for a direct navigation.
- never emits `surface` outside `VALID_TABS`.

`router.test.ts`:

- `__redirected_from` is set on params when a redirect resolves and is
  cleared otherwise.
- `__redirected_from` is stripped from `toHash` output (no leak into URL).

OCaml side: `test/test_dashboard_nav_event.ml` validates surface and
section against the navigation manifest and increments counters.

### 4.7 Rollout

PR-1 (this RFC's first implementation PR):

1. Backend handler + counter registration.
2. Frontend `nav-telemetry.ts` + one-line `__redirected_from` plumbing
   in router.
3. Tests above.
4. `main.ts` call site.

PR-2 (consumed by RFC-0048):

- Add a Grafana panel sourcing the counters.
- Add a small CLI: `scripts/dashboard-ia-usage.sh --since=7d` that
  produces the Markdown report RFC-0048 PR-C consumes.

PR-3 (deferred until RFC-0048 PR-C asks for it):

- Optional `redirected_from` exclusion view in Grafana.

## 5. Compatibility & risk

### 5.1 Wire-format compatibility

The `redirected_from` label is added on day one. We pay the cardinality
cost (≈ 19 sections × at most 3-4 redirect sources = ~60 distinct label
combinations) up front so we never have to migrate the counter.

### 5.2 Hash-URL leakage

`__redirected_from` is internal to the route signal and never written
to the URL. A regression test in `router.test.ts` enforces this. If
the leak ever happens, the field becomes user-bookmarkable and would
distort downstream counters.

### 5.3 PII

There is no operator label, no session cookie, no IP. The handler
must not log the request body — only increment the counter.

### 5.4 Failure modes

Telemetry is best-effort. We accept loss on 4xx, 5xx, offline. If the
endpoint returns 5xx for an extended period we under-count uniformly,
which is acceptable for an "is this section used at all" question. It
would not be acceptable for SLO measurement; that is out of scope.

### 5.5 Cardinality cap

Hard ceiling: at most `|surfaces| × |sections| × (|redirects| + 1)`
distinct label combinations. Today: 9 × 20 × 4 ≈ 720, well under any
Prometheus limit. If we ever cross 10k we add an opt-in flag.

## 6. Open questions

1. **CSRF.** Should the POST require an origin check? The dashboard
   already uses the same origin for its other writes. We default to
   the existing CSRF middleware; if there is none on the dashboard
   write path, the answer is "yes, add one before this RFC merges."
2. **Test fakes.** RFC-0048 PR-C reads from Prometheus via PromQL.
   Should we expose a fake-clock test mode? Not in this RFC — defer
   until a consumer asks.
3. **`redirected_from` chain.** If A redirects to B which redirects to
   C, the field carries A's key, not B's. Test in §4.6 covers the
   single-hop case; chain-collapse needs RFC-0048 PR-C's redirect-walk
   to handle this consistently.

## 7. Done criteria

1. Both counters appear in `/metrics` after the first navigation.
2. The Markdown report in PR-2 produces a non-empty section list with
   non-zero counts after 24 hours of dashboard use.
3. `redirected_from` distribution across `dashboard_section_open_total`
   matches the redirect map cardinality (no leaks, no missing
   redirect sources).
4. `router.test.ts` and `nav-telemetry.test.ts` pass.
