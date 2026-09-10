# Live observation qualification tooling

These scripts collect evidence against an already-running candidate. They do
not deploy a binary, build an image, create a browser session, navigate an
existing browser, or operate an MSX machine. They never query or wait for CI.

`qualify.py` records authenticated attach, inspect, completed observations,
slice, evidence freezing, refresh, and detach. Every HTTP response body is saved
with its hash and duration. Concurrent `/health` reads measure responsiveness;
they do **not** prove Keeper turns or game controller progress. Output always
marks full v0 qualification false and leaves missing acceptance evidence named.

Use existing credentials with `--token-file`. The credential value is excluded
from journals and stdout; redirects are refused so a bearer is not forwarded to
another destination. Output directories must be empty and are made private.
Manifests are absolute paths on the **MASC server**; binding JSON files are read
on the machine running the script. Each manifest pairs with its binding by
argument position.

```sh
python3 scripts/lane-addons/qualify.py \
  --base-url http://127.0.0.1:8935 \
  --manifest /server/checkout/addons/web-project/lane.toml \
  --binding /operator/web-binding.json \
  --manifest /server/checkout/addons/msx-observer/lane.toml \
  --binding /operator/msx-binding.json \
  --token-file /operator/existing-masc-token \
  --output-dir /operator/evidence/lifecycle-run
```

The origin and paths above are examples; no runtime path is compiled into the
scripts. Images must already exist in the candidate's Docker context. With
`--docker /path/to/docker`, the script independently checks each exact container
ID after detach. An inspect error alone is insufficient: the daemon must answer
and an exact-ID listing must be empty. Use the server's actual Docker context.

The default run does not contact a Keeper. An operator can explicitly request
delivery of one package's relation rows with `--keeper-name NAME
--deliver-addon-id web-project`. The receipt is retained as a delivery receipt;
actual evidence consumption, the Keeper's choice, corrective action and later
independent verification still need their own proof. No remedy command is added
to that delivery. A frozen evidence reference is not dereferenced as an arbitrary
operator-local file path.

`--health-samples`, `--health-interval`, `--poll-interval`, `--wait-seconds`, and
`--http-timeout` control this finite operator measurement only. They do not
change any Keeper limit or choose a product performance tolerance. The summary
reports p50/p95 and raw failures by phase. Agree on acceptance tolerances after
reviewing baseline, then rerun the same workload with those criteria separately.
Even a successful script exit means measurements were collected, not that the
Goal or all v0 scenarios passed.

## Existing source bindings

Web `binding.sources` may combine:

```json
[
  {
    "kind": "browser_document", "source_id": "existing-browser",
    "lane": "live", "client_id": "existing-native-client-UUID", "tab_id": 4,
    "target_id": "fixture-site", "environment": "qualification", "request_id": "verify-A"
  },
  {"kind": "snapshot_file", "source_id": "deployments", "path": "/server/evidence/deployment-envelope.json"}
]
```

Use the actual selected client and tab from the existing Browser Lane. For an
existing automation session use `lane: "automation"` and omit `client_id`; the
source refuses to switch to a different current tab. Attach does not create the
session. The package binding's target, expected build and request must match the
declared source mapping. See `addons/README.md` for exact domain payloads.

MSX source configuration is `{"kind":"msx_capture","source_id":"game"}`.
It captures the already loaded `workspace-msx` machine with its actual history
incarnation and frame. No controller inputs are issued. If no machine or browser
document is available, incomplete coverage is the correct result.

## Owned revision fixture

```sh
python3 scripts/lane-addons/fixture.py --output-dir /operator/evidence/web-fixture
```

This creates only a loopback HTTP fixture on an ephemeral port and prints its
URL plus `fixture.json`. The file contains the immutable expected manifest's
actual SHA-256, revision A and namespace. Initially the server serves B with a
disabled feature. Its existing owner can choose to navigate the existing browser
to the printed URL through the usual Browser Lane controls. The Add-on then
observes the real client/tab/document; the fixture does not invent those IDs.
The actual served artifact is `current.html` in the owned fixture directory;
`expected.html` holds the A artifact. A Keeper may restrict its file edits to
this fixture directory. The server reads `current.html` on each document GET.

An authorized corrective action against this owned fixture is an HTTP POST to
its `/state` with `{"revision":"A","feature_ok":true}`. The file update uses
atomic replacement. This is an action **for the Keeper or operator to choose**;
the qualification runner never sends it. A fresh browser read and independent
click of `#fixture-action` must observe `#fixture-result` becoming
`feature-complete` before claiming browser functional success.

The fixture's `/probe`, `/state`, and HTTP request journal report destination
HTTP/server observations only. They lack browser document identity and must not
be converted into the Web Add-on's document-specific `probe` kind. Keep them as
separate evidence alongside actual browser capture and independent verification.

## Tooling tests

```sh
python3 -m unittest discover -s scripts/lane-addons -p 'test_*.py' -v
```

Tests use an owned fake MASC HTTP service and an owned revision fixture. They
verify the runner's cleanup, evidence files, token omission and partial-status
reporting; they are not live MASC, Docker, browser or Keeper acceptance.
