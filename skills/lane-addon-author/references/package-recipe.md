# Package recipe

Use the current MASC repository `addons/protocol.py` and a small existing package
as a transport reference; record the revision copied. The protocol is ordinary
MCP stdio. Do not add host-side dispatch for your domain. The package owns its
`observe` implementation, declared output ports and optional action schema.

Package files normally include `lane.toml`, worker source, transport code,
`Dockerfile` and behavior tests. Keep any package Skills under the directory
explicitly named by `[world.skills].directory`; their resources must live under
the respective Skill directory.

## Manifest and installation are separate

`lane.toml` describes the package:

```toml
id = "document-changes"
revision = "0.1.0"
title = "Document changes"
contributions = ["observe", "derive"]
image = "document-changes:0.1.0"
command = ["python3", "server.py"]

[resources]
cpus = 0.5
memory_bytes = 134217728
pids = 16
max_reply_bytes = 4194304

[world.outputs.changes]
lanes = ["changes"]
```

Resource values above are an example worker allocation, not task or Keeper
budgets. Choose them for the package workload. Prefer an immutable image identity
for deployment. Use Docker `CMD` when the host supplies the explicit command;
a duplicated `ENTRYPOINT` can cause a different program invocation.

An installation TOML contains exactly `id`, `run_id`, `manifest_path` and
`[binding]`. Its sources use typed `snapshot_file`, `browser_document`,
`msx_capture` or `lane_output` connections. Read current tool/schema documentation
for required fields; do not infer source kinds from filenames. Relative manifest
and snapshot paths resolve against the installation TOML directory.

## Input and presentation

Optional `[interface]` entries `binding_schema` and `presentation` are JSON text
inside TOML strings. Binding schemas describe an object using the host's supported
JSON Schema subset, including the package's `sources` array. Unsupported keywords
are rejected. The host validates before starting the worker, but the worker still
validates domain data received from sources.

Presentation contains `description` and `readings`. Each reading has package-local
`lane_id`, a nonempty exact field `path` array, `label`, optional `unit`, and
`format` (`text`, `number`, `boolean`, `json`). Labels do not grant authority.
Missing or wrongly typed values must remain unavailable, rather than zero.

## Source contract

A snapshot envelope contains `source_id`, `incarnation`, nullable `cursor`,
`complete`, nullable `detail` and `observations`. The envelope source ID must equal
the binding source ID. Preserve source revision separately from capture time.
Retain evidence hashes and resolve result references back to those bytes.

Collectors should atomically replace snapshots. Failed capture publishes explicit
incomplete coverage so an old success cannot masquerade as current evidence.
Reject nonfinite JSON numbers. A damaged previous snapshot must not prevent a
valid current capture from replacing it. Preserve the existing bytes for identical
source identity/cursor only when the capture contract says those identify the
same data.

Test the worker through MCP, not only its calculation functions: initialization,
tool discovery, observe input and output schema, missing source, incomplete source,
real representative input and a source change. Test action review and failure
receipts if actions exist. Evidence coverage and the claimed output scope must
agree.

## CI and operator handoff

Use the project's CI to run behavior tests and build/save the exact image. Record
source SHA, CI URL, image digest and test scope. If CI is blocked by billing or
infrastructure, retain that failure and keep image readiness unverified.

Use `masc_lane_declaration_read` and `masc_lane_declaration_save` for revision-aware
installation. Create must not replace an existing file; save requires the opaque
revision returned by read. Inspect applied revision and instance phase, then use
`masc_lane_slice` and `masc_lane_evidence` to inspect retained output and sources.
Do not compute an opaque revision from raw-file SHA unless that exact API contract
specifies it.

For subscription-capable hosts, discover `masc_lane_updates`; inspect/save the
workspace subscription configuration, then have the actual subscribed Keeper read
and acknowledge its receipt. Management identity must not impersonate that reader.
A new worker incarnation starts a distinct observation sequence.
