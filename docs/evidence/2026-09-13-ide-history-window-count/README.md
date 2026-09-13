# Activity history count source acceptance

The Activity panel previously displayed only the fetched window, making 50 recent workspace events easy to read as the entire history. It now shows the loaded workspace event count against the API's `total_matching_events` and explains when older events are not loaded. Missing or invalid totals are shown as unavailable. Repository-scoped IDE bridge events stay outside that workspace count.

This evidence runs the production source Activity component in Chromium through Vite development transformation with explicitly synthetic API data. It is not an installed MASC acceptance, real persisted history measurement, full IDE acceptance, or implementation of older-history pagination.

## Observed scenarios

- Desktop standard, desktop compact, and mobile compact (390 × 844): `Workspace history: 50 of 1972 loaded`, with the older-events notice. A separate scoped bridge event makes the timeline contain 51 rows; the workspace count remains 50.
- Mobile unknown-total scenario selected through the fixture control: `50 loaded · total unavailable` with no invented older-events count.
- Mobile empty scenario selected through the fixture control: `0 of 0 loaded`, zero timeline rows.
- All five captured states have no document horizontal overflow. No browser page errors occurred. Desktop and mobile compact screenshots were directly inspected.

`receipt.json` records scenario text, viewport, geometry, row counts and synthetic API requests. PNGs are viewport screenshots. `validation.json` records commands, successful exit codes and production source hashes; corresponding tool logs are included (Vitest trailing blank line normalized). The Activity suite passed 29 tests, including six count/invalid-total cases and existing scope/refresh coverage. TypeScript noEmit and ESLint of the changed production module passed. No product build or runtime mutation was performed.

Reproduce from this worktree:

```sh
node scripts/ide-history-window-browser-probe.mjs dashboard /tmp/FRESH_HISTORY_OUTPUT
```

The output directory must not already exist. The probe starts and closes its own Vite dev server and Chromium browser. `SHA256SUMS` hashes every evidence file except itself.
