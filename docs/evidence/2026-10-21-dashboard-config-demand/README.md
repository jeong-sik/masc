# Configuration preview follows configuration demand

Opening a Keeper conversation previously called `loadKeeperConfig` both from
`openKeeperDetail` and the route content mount. The resource deduplicates
concurrent calls, but chat-only entry still starts a full configuration GET.
The basic conversation and context rail do not consume that resource.

The settings overlay and diagnostics runtime editor already load their own
configuration when mounted. Remove the two chat-entry calls and let those actual
consumers own demand. Keep the endpoint, current revision/CAS, save ownership,
conflict draft recovery and error handling intact.

An independent adversarial review found one transition to fix alongside this:
`KeeperConfigPanel` captured loaded Keeper A state before requesting B. Demand
load resets the resource synchronously, so read the state after that transition.
The deferred B fixture failed on the original capture order by exposing A's
settings controls, and passes after re-reading the state. Persistent draft
corruption or an incorrect PATCH was not demonstrated.

## Validation

At base `8c2b56cb19a9f44397aa876a81396ad872ba5ec0` plus this change:

- Four focused Vitest files: 153 passed. They cover chat entry request absence,
  direct route/overlay ownership, actual config-panel demand, errors, switching,
  CAS conflicts and retained edits, and the diagnostic runtime editor.
- `pnpm typecheck` passed.
- Vite production build results for the published source are recorded in the PR
  evidence separately from the earlier build before the cached-state fix.
- `git diff --check` passed. No local Dune or CI watch was used.

Reproduce from `dashboard/`:

```sh
pnpm test src/components/keeper-detail.test.ts src/components/keeper-detail-state.test.ts src/components/keeper-config-panel.test.ts src/components/keeper-runtime-model-editor.test.ts
pnpm typecheck
pnpm build
```

## Measurement boundary

The installed Dashboard on the base source showed an initial config request of
about 2025 ms and a warm reload's first message at 587 ms. These are separate
observations with different cache/activity state, not a before/after comparison.
The full config snapshot builds prompt/world/skill/repository previews while
holding its existing configuration-revision transaction. No specific substage
was timed. This patch removes that work from chat-only entry; it does not claim
a 2-second first-message improvement. New-source installation and browser request
verification remain outstanding until observed separately. Private conversation
screenshots and raw configuration responses are not published here.
