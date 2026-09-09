# Goal confirmation browser proof

The production dashboard bundle was built by CI run `34412528600`, artifact `10127840642`, from source `46cd44057f8acf30cf47497230f0d77d0913bd2e`. The harness verified the CI receipt, archive SHA256 `f87ac30022fe0d871e17f78203bbe85514bc332919fb4b02650b6dcd8ad32ed0` and index SHA before serving the extracted assets. No local build was used.

The browser navigated the actual Goal detail UI. Explicit synthetic HTTP fixtures supplied one awaiting-confirmation Goal and its verifier proof. Confirmation POSTs were intercepted locally, never forwarded to the live read-only backend. Other mutations and WebSockets were blocked. The full-page screenshot consequently includes the older backend's build-mismatch banner; this is preview evidence, not a deployed integrated server claim.

Observed and asserted:

- The detail card shows the exact criterion, revision, verifier evidence, request and run. The `<script>` text remains literal.
- The button submits exactly that displayed binding. Only matching POST acknowledgment plus GET readback displays the confirmed operator/time.
- A committed fixture POST followed by GET 503 displays uncertainty and no success claim.
- GET 403 displays permission failure with a fresh-evidence retry.
- At 390px viewport width, both proof and error cards fit the viewport; the evidence wraps and the confirmation button remains readable.

All six screenshots were opened and visually inspected. The receipt includes the two synthetic POST bodies, read order, blocked mutation attempts and measured mobile bounds. This proves CI-built browser behavior with synthetic confirmation HTTP, not real credential authorization or a real Goal mutation. Those backend semantics remain covered by the parent PR's separate checks.

Reproduce with a downloaded `masc-dashboard-<head>` artifact directory:

```sh
node scripts/verify-goal-confirmation-preview.mjs ARTIFACT_DIR 46cd44057f8acf30cf47497230f0d77d0913bd2e http://127.0.0.1:8935 FRESH_OUTPUT_DIR
```

The initial harness assumed the older preview-provenance layout and stopped before launching a browser. It now reads the actual dashboard-build-receipt/archive format. The accepted evidence is `/tmp/masc-goal-ui-browser-46cd-final`.
