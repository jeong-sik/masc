# Fusion as assembled Lane workers

Install the same isolated package once per panel and once per judge. A worker
calls its host over standard MCP sampling; it never receives provider credentials
and has no direct provider network connection. Its installation's `model_route`
chooses a declared host runtime route. Each worker has a separate MCP connection,
so horizontal panels do not recursively call a shared client. Actual parallel
container execution remains to be qualified.

```text
retained input ── panel A ──┐
               └ panel B ──┴── judge ── report ── explicit Keeper/Broadcast
```

Panel inputs can be retained snapshot files or named Lane outputs. Judges require
named `result` outputs from other computation workers in the same host run. Their
`analysis_id` must match. `role`, `prompt`, and `instructions` are installation
settings: a panel can use a distinct lens, and a judge can synthesize or challenge
the supplied answers. Model replies remain free text. No JSON decision envelope
or implicit Board publication is required.

The output port `result` carries `fusion/computation` rows: actual role, status,
model identity and text, original sampling response/error, model request/outcome
references, input coverage, and retained input references. `input_complete` says
whether the inputs were complete; it never turns a failed model call into a
successful answer. A judge receives failed/uncertain upstream results explicitly
and marks its input coverage partial. A post-call outcome retention failure can
carry only the durable request, with `outcome_unknown` preserved.
An otherwise retained response that Fusion cannot consume (for example, image
content) is `invalid_response`: its exact `sampling_response` and evidence remain,
and `validation_error` explains the incompatibility. This is distinct from a
host failure, which retains the actual `sampling_error` terminal envelope.
Both judge and report verify that distinction before using a computation.

Sampling request and response frames share the manifest's byte envelope, including
newline. A rejected oversized host response produces an explicit tool error: the
model-call outcome is unconfirmed, and no retained request/outcome identity is
inferred from bytes that were not admitted. Recovery must read the host's retained
request directly. The worker drains that frame in bounded chunks so subsequent
MCP requests remain framed. Non-finite numbers in admitted responses or retained
report inputs are rejected before those values can enter emitted JSON.

The report package renders this output without impersonating a Board-backed
native Fusion run. Reading or broadcasting the report uses the existing explicit
evidence action; completing a computation does not deliver it.

Examples are in `docs/examples/lane-addons/fusion-compute/`. Replace each host
runtime route and the panel snapshot paths before installation. All declarations
share `run_id = "assembled-fusion"`, while their stable installation IDs differ.
The host retains snapshot bytes before supplying them. `snapshot_file` captures
are supplied evidence, not automatically refreshed live sources.

Model access requires server host sampling support. HTTP Agent Core runtimes are
wired in the parent stack; official-client adapters still lack the per-request
output-limit channel and fail explicitly. No container build, live provider
execution, installed TUI proof, or agent use is established by these examples.
Duplex subprocess tests use a synthetic host that records request/outcome JSON.

Model evidence is checked against `sampling_receipts` projected by the host on
each `lane_output` observation. The host resolves the producer's exact request
record and retained terminal outcome; a package-created artifact is not proof of
a model call. Judges reject missing receipts or replies that differ from the
retained response before requesting their own sampling call.
