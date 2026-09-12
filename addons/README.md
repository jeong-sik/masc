# Lane observation packages

These packages add observations and relationships to existing MASC activity.
They do not create a browser, game machine, Keeper, scheduler, or new permission
requirement. `protocol.py` provides only MCP stdio framing and the common row
schema. Domain logic lives in the individual packages, outside the MASC host.

`web-project` derives relationships between a bound build expectation, existing
deployment receipts, captured browser documents, and document feature probes.
`msx-observer` projects snapshots from the existing machine and keeps its frame
clock and incarnation. Both only read arguments; neither fetches a URL, opens a
screen artifact, issues game input, or modifies its source.

The MSX manifest also declares `[world.skills] directory = "skills"`. Its bundled
`msx-observe` instruction Skill and script/reference resources join the existing
workspace Skill catalog as a read-only source. `keeper_skill` reads the selected
bytes and reports their SHA-256; it does not execute the script or add game
controls. The source uses the existing configured Skill resource-read bound and
selection rules. See the [installation and Skill guide](../docs/guides/lane-addon-toml.md).

Build from the repository root (image construction belongs in CI):

```sh
docker build -f addons/web-project/Dockerfile -t masc-lane-web-project:0.1.0 addons
docker build -f addons/msx-observer/Dockerfile -t masc-lane-msx-observer:0.1.0 addons
```

Register the package's `lane.toml`. The manifests include example per-observer
resource envelopes: half a CPU, 128 MiB memory, 16 processes, and a 4 MiB maximum
reply. These values bound these small read-only workers, not Keeper activity.
Qualification must record the actual applied envelope and measure impact; these
defaults do not constitute measured performance acceptance.

The worker publishes its exact container ID before inspection and MCP
initialization, so those operations can be interrupted by explicit detach.
Cleanup is verified only after a successful Docker query confirms that the exact
container is absent. After a host restart, recovery verifies the retained
container ID and ownership label before removal. If the create receipt has no
container ID, recovery finds this instance's deterministic container name,
verifies the exact name and ownership label, and removes the resolved ID.
An unavailable Docker daemon or mismatched ownership leaves cleanup incomplete.
Package lifecycle tests cover blocked inspection, initialization, observation,
and lost-receipt recovery; CI and live qualification establish the actual result.

The MCP worker exposes `lane_observe`, taking `{binding, sources}` and returning
`{rows, coverage}` in both `structuredContent` and a JSON text content block.
`tools/list` supplies `inputSchema` and `outputSchema`. The implemented protocol
revision is 2025-06-18; initialize negotiates that revision explicitly.

Run feature tests without building OCaml or an image:

```sh
python3 -m unittest discover -s addons/tests -v
```

Tests execute the actual stdio workers, cover the four Web counterexamples,
source coverage and actor provenance, and MSX frame reset across incarnations.
The HTTP test measures actual served HTML; its client/document identity is
fixture data. It is not browser, Keeper action, Docker isolation, or live MSX
qualification. Those acceptance tests belong to the host integration.

## Sources

The host supplies immutable source snapshots, including coverage:

```json
{
  "source_id": "browser-events",
  "incarnation": "session-1",
  "cursor": "offset:42",
  "complete": true,
  "detail": null,
  "observations": []
}
```

An observation carries `id`, epoch `observed_at`, `actor` (actual observer or
executor, otherwise null), and `evidence: [{uri, sha256}]`. Digests are lowercase
SHA-256 or null. A deployment's assigned runtime never substitutes for actor.
Event IDs are namespaced by source and incarnation when projected into rows.
Rows reference source evidence; the host owns durable evidence preservation.

Unrecognized observation kinds, including raw Keeper records, produce no domain
claims. Coverage identifies the ignored kinds and preserves the source's own
completeness, cursor, and missing-range detail. Known kinds with malformed
required fields return a tool error, without invented default observations.

## Web binding and observations

```json
{
  "target": {"id": "store", "environment": "production", "url": "https://store.example/app"},
  "request_id": "verify-build-A",
  "expected": {
    "namespace": "store-build",
    "revision": "A",
    "observed_at": 1789034400.0,
    "manifest": {"uri": "artifact://build/A/manifest.json", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }
}
```

The expectation is a distinct row with the timestamp of the recorded build
expectation, not the browser timestamp. `manifest.sha256` is required to identify
its immutable evidence. The example digest is illustrative, not measured proof.

Each Web observation additionally carries `target` with the *actual* target ID,
environment, and URL, and `request_id`. Match uses all these coordinates exactly.
Keep query strings, ports, and paths. Do not relabel observed coordinates with
the requested coordinates. Kind-specific fields are:

| Kind | Required additional fields |
| --- | --- |
| `deployment` | `revision` recorded in the deployment receipt |
| `browser` | `client_id`, `tab_id`, `document_id`, `html` (same-document HTML, or null) |
| `probe` | `client_id`, `tab_id`, `document_id`, `passed` (boolean) |

The browser producer must capture actual URL, document identity, and HTML from
the same existing document. An independent HTTP request, source checkout hash,
or `/version` endpoint is not a substitute. The package does not navigate the
browser to obtain missing data. The document head has explicit markers:

```html
<head>
<meta name="masc-revision" content="B">
<meta name="masc-revision-namespace" content="store-build">
</head>
```

HTMLParser extracts active document-head markers; body content, templates,
noscript and title content cannot declare the build. Missing, duplicate,
ambiguous, or noncomparable namespace markers yield unknown.
A relation claims only what that browser document showed
at its observation time. Probes join only with matching target, request, client,
tab, and document. A failing probe with matching revision remains a feature
failure. Matching deployment receipts join as reported claims, without replacing
the actual document observation. Unrelated observations remain raw rows and
yield no relation.

## MSX binding and observations

Binding is `{ "machine_id": "workspace-msx" }` to follow the existing machine
across explicitly recorded histories. Optional `incarnation: "load-2"` pins one
history; absent or null means any observed incarnation, not an invented ID.
Each `capture`
observation adds `machine_id`, `incarnation`, nonnegative integer `frame`,
`screen: {uri, sha256}`, and nullable `input_cursor`. Incarnation must change when
loading/restoring a machine history so a reset frame is not mistaken for an
earlier point in the same clock. The package preserves every supplied capture
and indicates whether it matches the binding. It never derives game-state facts
from screen filenames or silently turns a Keeper turn into an MSX frame.
