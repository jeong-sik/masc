# Lane package connections to MASC

A Lane package contributes observations, relationships, optional Skills, and
optional actions to an existing MASC run. The container is the package's
environment; it does not replace a Keeper, the Keeper's tools, or its lifecycle.
Package-specific behavior belongs in the package's manifest, Skills and scripts.
The host and Dashboard use the same protocol for every domain.

An installation connects the package to a run using a declaration under the
resolved configuration root's `lane-addons/` directory:

```toml
id = "my-world-layer"
run_id = "my-project"
manifest_path = "../packages/my-world-layer/lane.toml"

[binding]
sources = []
```

Paths resolve from the declaration directory. The package image must already be
available to Docker. TOML reconciliation installs the package; it does not build
images, download missing environments, or execute Skill scripts automatically.
See [installation](lane-addon-toml.md) for reload and removal behavior and
[output composition](lane-output-composition.md) for connecting one installation
to another.

## The connections

| Direction | Declaration / protocol | Meaning |
| --- | --- | --- |
| Existing world → package | `binding.sources` | Explicit captured sources, including another installation's latest completed output. |
| Package → world | `lane_observe` output | Rows, source coverage, clock coordinates and original evidence. |
| Package → Keeper discovery | `[world.skills] directory = "skills"` | Read-only entries in the existing Skill catalog and existing resource reader. |
| User or Keeper → package | `[world.actions] tool = "lane_act"` | An optional action request to this worker incarnation, with a durable receipt. |
| Package → retained evidence | `artifacts` in its output | Explicit bytes, hashed and retained by MASC; rows reference them by local artifact ID. |

MSX and Browser source adapters continue observing their existing owners. A
package may instead own its environment, as an emulator package does. A
statistics package can read another package's output without a new emulator or
Keeper. These are package roles, not a progression that every package must follow.

## Optional actions

An acting package declares both its contribution and its advertised MCP tool:

```toml
contributions = ["observe", "act"]

[world.actions]
tool = "lane_act"

[world.skills]
directory = "skills"
```

The existing `resources` table remains required. Its container and reply limits
apply to this package; they do not impose a Keeper turn or cost budget.

The package advertises an action tool schema requiring exactly `context`,
`request_id`, and `action`. The host supplies context; callers supply the action:

```json
{
  "context": {"instance_id": "worker-id", "incarnation": "worker-id"},
  "request_id": "request-id",
  "action": {"kind": "package-defined-operation"}
}
```

Inspect exposes the advertised schema. The host validates supported object,
array and scalar constraints using the existing tool validators. Unsupported
schema keywords are rejected explicitly; this is not full JSON Schema support.
Acting workers also receive context in their observation requests. Read-only
workers retain the ordinary `binding` and `sources` observation request.

One instance UUID identifies one worker lifetime. It is also the incarnation in
this version. Replacement creates a new identity. In-place machine reset,
checkpoint restore, and a separate shared machine incarnation are outside this
contract; the UUID alone does not protect an independently owned MSX machine.

Use `POST /api/v1/lane-addons/actions` or the generic `masc_lane_act` tool with:

```json
{
  "instance_id": "worker-id",
  "expected_incarnation": "worker-id",
  "request_id": "request-id",
  "action": {"kind": "package-defined-operation"}
}
```

An authenticated request is persisted before the package is invoked. Acceptance
returns promptly; the optional worker handles it in its own execution flow.
The Dashboard preserves the selected instance, incarnation and request identity
when querying a receipt. It does not silently retarget or resend a lost request.

Read the receipt with `GET /api/v1/lane-addons/actions?instance_id=...&request_id=...`
or `masc_lane_action_status`. A repeated request with the same normalized input
returns the existing receipt. A different input under the same request identity
is rejected. Receipt identity and SHA-256 include the host-generated context.

| State | What the receipt establishes |
| --- | --- |
| `queued` | The host durably accepted this request. |
| `running` | The host recorded dispatch to the actual container. |
| `confirmed` | The package reported confirmation and its output was retained. Read the evidence for what it actually confirmed. |
| `failed_before_effect` | The request was not dispatched, or the package explicitly reported failure before effect. |
| `outcome_unknown` | A dispatched request has no usable durable result, or the package could not establish its outcome. |

The authenticated requester and actual container executor remain distinct. The
host does not infer a model or provider identity. A package confirmation is not
independent verification, nor does transport success establish an external
effect. Package-specific tests must read the resulting state or artifact.

After a worker exits, orphaned running receipts become `outcome_unknown` and
undispatched queued receipts become `failed_before_effect`. They are never
automatically replayed against a replacement. Detachment retains receipts and
committed observations. A slow action may occupy its own worker; other workers,
Slice queries and Keeper work do not acquire that action's completion dependency.

## Artifact output

Any package may include artifact bytes in its observations. Action-result output
uses the same envelope:

```json
{
  "rows": [],
  "coverage": [],
  "artifacts": [
    {"id": "state", "mime_type": "application/octet-stream", "data_base64": "AA=="}
  ]
}
```

A row references those exact bytes with `{"artifact_id":"state"}` in its
`evidence` list. MASC enforces the package's reply envelope, decodes canonical
base64, computes SHA-256, and writes a content-addressed blob. No URI is fetched
to obtain an artifact. Existing URI references are references, not evidence that
MASC has read or retained their destination bytes.

The `artifacts` member is optional when there are no bytes to publish. Producing
evidence does not require an `act` contribution.

An action result requires `status`, an object-valued `result`, and `output`. Its status is one of
`confirmed`, `failed_before_effect`, or `outcome_unknown`. The package must state
what it checked in `result` and return the corresponding observation evidence.
Raw observations do not gain semantic confidence or inferred causal claims.

## Qualification boundary

The workflow tests cover public dispatch, request deduplication, stale identity,
schema validation, retained receipts and exact action output through Slice.
A held worker fixture checks that another observer and Slice continue and that
detaching cancels undispatched actions without replaying the running request.
Orphan receipt tests exercise recovery without dispatch. These tests do not
establish real emulator behavior, a whole-server restart, or a Keeper model turn.

The next package qualification must freeze this host revision, install the
package using TOML, act through the common surface, and independently inspect
retained bytes and the Dashboard. If the domain needs another host dispatcher
or component branch, package-only extensibility has not passed.
