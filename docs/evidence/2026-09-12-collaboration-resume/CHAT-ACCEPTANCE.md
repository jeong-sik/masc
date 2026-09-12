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
