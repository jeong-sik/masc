# Remove synthetic and duplicate Dashboard pages

Issue: #45428. Implementation: `abb71c1abe9def6064c991d340105f917c16bb8c`
over `22c1fc45c791948431185f3aeb4bf544b80b3255`.

## Removed product surfaces

- Lab Performance generated synthetic Keeper/log rows and browser rendering
  demonstrations. Its page, navigation entry, dedicated tests and unused style
  are removed. Shared VirtualList and FPS utilities remain.
- The hidden Cockpit page was a static route map. Its route type, dispatcher,
  labels, page and dedicated tests are removed. Cognitive-mode entrypoints are
  still used by routing and remain intact.
- Inspector's static overview/link cards and local tab wrapper are removed.
  The existing Inspector action now renders the actual ServerConfig directly.

Tools, Safety Harness, Keeper memory and monitoring retain actual API/storage
consumers. Empty or failed reads were not taken as evidence for deletion.
Existing generic unknown-route handling sends the removed Performance URL to
Lab Tools and the removed Cockpit URL to Overview; no new compatibility aliases
were added.

## Review finding and repair

The initial removal also removed the only non-primary route. A retained
`dashboard:focus-mode=true` preference could then suppress both navigation and
the control/shortcuts needed to leave focus mode. The initial source PASS missed
this P2 and was explicitly withdrawn.

Two real App-state regressions reproduced the failure before repair:

```text
Tests  2 failed | 30 passed (32)
can leave a retained focus-mode state from a primary route
can leave retained focus mode with its keyboard shortcut on a primary route
```

The focus toggle is now mounted while focus mode is active independently of
floating-chrome suppression. The status tray keeps its prior condition.
Button/F11 state transitions pass after repair. Independent source review
accepted the exit-control repair at `213a4aacee09dbe36d955df697af4fb9ba3e550b`;
the later actual screenshot also exposed the hidden navigation's retained 58px
grid column. Compact chrome now allocates one full content column. Review of
that final delta is separate; source review is not formal GitHub approval.

## Executed checks

From dashboard/:

```sh
pnpm exec tsc --noEmit
pnpm exec eslint src/app.ts src/app.test.ts src/config/navigation.ts src/config/navigation.test.ts src/types/sse.ts src/components/dashboard-shell.ts src/components/v2/nav-rail-v2.ts src/components/lab.ts src/components/lab.test.ts src/components/operations-panel.ts src/components/operations-panel.test.ts
pnpm exec vitest run src/config/navigation.test.ts src/router.test.ts src/components/lab.test.ts src/components/operations-panel.test.ts src/cockpit-entrypoints.test.ts src/components/dashboard-shell-tab-surface.test.ts src/app.test.ts src/components/focus-mode-toggle.test.ts --no-file-parallelism --maxWorkers=1
```

Type checking and changed-file ESLint passed. The eight selected suites passed
**158 tests**. `git diff --check` passed. Full regression, production bundle and
local Dune build were not run. No new screen-wording/layout snapshot assertions
were added; the new tests exercise retained focus-mode state and its exit actions.

## Actual browser observations

ego-browser displayed the installed Dashboard before the change and a separate
Vite development frontend from this checkout after the change. The development
frontend used the existing live server through the configured loopback proxy;
no replacement backend or mock UI was substituted.

- Before: the visible Performance page exposed the rendering playground; the
  Inspector first showed static link cards and a separate server-config tab.
- After: Lab navigation offers Tools, Safety Harness and Keeper memory. The
  actual Tools page reads resolved configuration paths from the live backend.
- Inspector opens actual server configuration without the extra overview/tab.
- The former Performance URL resolves to Lab Tools; Cockpit resolves to Overview.
- Safety Harness remains routed. Its first captured frame was still loading;
  a subsequent frame displayed 4,999 actual verdicts. This is a bounded current
  observation, not a guarantee of all Harness data or event freshness.
- A retained focus-mode preference was seeded only on the private development
  origin, followed by reload. The actual Exit button remained visible. Clicking
  it restored the navigation and persisted false. Focus-mode recovery tests
  above separately exercise the button and F11.

Screenshots and original logs are retained privately because they include live
workspace data. They were visually inspected; they are not public fixture data
or assertions about every Dashboard route.

The development preview is not an installed production Dashboard. The Dashboard
artifact workflow remains disabled as requested. No binary/assets installation
or live server restart was performed by this change.
