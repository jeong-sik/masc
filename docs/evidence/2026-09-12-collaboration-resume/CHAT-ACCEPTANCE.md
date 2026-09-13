# Latest installed acceptance: 2026-09-13

Actual historical autonomous Edit `exec-1789223431021-0129` now passes on installed source4324764. The manifest, before/after blob hashes, rendered originals and displayed patch agree. Desktop and mobile screenshots include the visible diff; all83 fetched assets match the installed manifest. Exact-source Test and full Release succeeded. See [receipt, screenshots and scope](installed-chat-4324764/README.md). This closes the recorded Chat display gap for that real execution. LSP and the full18-item goal remain open. Sections below preserve earlier observations and failures.

# Installed Chat acceptance

`scripts/verify-installed-chat-edit.mjs` observes the installed server and a retained real autonomous Edit. It does not serve fixtures or replace assets. It checks:

- The installed release source and binary hash against the running process and executable realpath.
- Every fetched Dashboard asset against the paired release manifest.
- The real API execution receipt: keeper, descriptor, execution/tool-use/trace/session/turn/task identities, autonomous provenance, input, output and artifact references.
- A single joined Chat record for that execution, both complete displayed originals against retained bytes, and the displayed unified diff reconstructing the after-file.
- The real browser worker and artifact GETs, keyboard focus, desktop/mobile screenshots and absence of HTTP errors during the observed flow.

The command requires a fresh output directory and writes an explicit failure receipt. Domain writes and WebSockets are blocked; the small MCP allowlist contains only bootstrap and read-only keeper/pause status operations.

```text
node scripts/verify-installed-chat-edit.mjs \
  INSTALLED_PREFIX EXPECTED_COMMIT BASE_URL FRESH_OUTPUT_DIR TOKEN_FILE \
  KEEPER EDIT_RECEIPT_JSON RUNTIME_ROOT
```

For this scenario, use keeper `exhibit-editor` and `serial-autonomy-2578/Edit.receipt.redacted.json`, execution `exec-1789213537223-0038`. RUNTIME_ROOT is the actual base-path/.masc. The final novel differs from this first typo correction; this UI probe proves the historical edit, while the later substantive peer revisions are separate evidence.

Preparation status: Node syntax and diff checks passed; independent review completed and exact receipt matching strengthened. The actual 2578 HTTP receipt was inspected and preserved in `serial-autonomy-2578/chat-api-edit-receipt.json`. This script has not yet passed against an installed candidate. Earlier attempts at the actual Chat flow encountered Dashboard 429 responses, including a dynamic JavaScript module, and remain failures. Run the probe after the quota/current-context/native Gate candidate is built and installed. Gate replay and a fresh model turn need separate acceptance evidence.

The existing Dashboard dependency installation resolved Playwright and diff, and the two retained real files passed a local diff/patch round trip without launching a browser. This is preparation only, not the installed browser acceptance result.

## 2026-09-12 installed aad94 reassessment

The installed aad94 binary and paired assets are now live. The first recent-edit probe matched the API receipt and 80 assets, but had left autonomous groups closed. Tweaks expands run grouping, while each autonomous turn has its own closed state. The probe now walks actual autonomous history buttons and records those clicks; it also uses the actual Tweaks test ID and awaits full-history loading.

The expanded attempt still failed to find the snapshot-bearing row after 183 history expansions, while matching the exact API receipt and 83 assets without HTTP/page errors. This is **not a passed Chat acceptance**. Further diagnosis must inspect loaded history refresh, trace execution identity and receipt-to-row matching before another attempt. The recent target is task-004 turn428, `exec-1789223431021-0129`; it differs from the older novel target outside the latest 200 tool receipts.

Both attempts are preserved under `reassessment-aad94/chat-collapsed-failure/` and `chat-expanded-failure/`, with screenshots, page text and raw receipts. The older failed receipt's scope text was an unconditional description of intended assertions; its `probe_passed=false` and absent `rendered` establish that displayed-byte and diff checks did not pass. The updated script makes that scope conditional explicitly. Script changes received independent review; no P1/P2 findings. This inspection does not establish a product root cause or a fresh native Gate replay.

The browser dependency was resolved from the existing workspace Dashboard node_modules through NODE_PATH. A first invocation without that environment failed before browser launch with MODULE_NOT_FOUND; no local product build or dependency install was performed.

## Original direction correction and output lookup candidate

The retained Edit0129 output is a verified 1345B tool-result manifest. Its explicit snapshots are before5237…12602B and after18e0…12641B; artifact_refs lists the reverse order and does not define direction. The probe now verifies the manifest hash/bytes, its Edit content/structured consistency, explicit before/after refs and unordered reference membership. Previous failed receipts preserve their original assumptions; they never reached displayed-original checks. The corrected helper passed nine real-file/invalid-input checks and Node syntax review. It has not been rerun against an upgraded server yet.

PR35567 head26ee98cf40 adds exact historical output lookup and verified manifest display, with Test34702833667 and Release34702835195 requested. It follows the successful f75aa4 native projection test while remaining distinct from the current remote parent main merge. New installed-browser acceptance is still pending.
