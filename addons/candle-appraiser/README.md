# Candle appraisal worker

This package owns durable Grade, per-task Relation, and Weights judgment intents.
It does not own the Candle ledger, payout policy, final settlement or provider
credentials. The host must fully decode a returned answer against its original
`Candle_appraisal.request` before deciding a ledger effect.

The server's Candle bootstrap consumes the unique visible `candle_appraise`
export with host operator authority. It reads an original intent before submitting
one that the worker authoritatively reports as absent. Rebuilding the same payout,
stage, original Relation task, model input, schema and rendered prompt retains its
request ID. Before any worker RPC, the host durably binds that original ID and
captured input to the selected logical installation, package and tool. A fresh
replacement cannot claim that an old unknown request is absent and run it again;
reattach the original installation to read its retained result. Worker process
restarts on the same installation keep that destination binding. Pending answers
resume on the existing maintenance pulse. An absent
or detached Add-on leaves the confirmed obligation in the host ledger.

Each Grade, Relation and Weights result still passes full host domain decoding
before settlement. The host records the original intent and answering slot in its
existing Exact run history; that observer receipt does not grant dispatch or mint
money. Provider credentials and execution stay in the common Add-on Exact host
path. Configure the installation's `grade`, `relation` and `weights` Exact outputs;
a standalone `candle_appraiser` model route does not attach the worker.

The consumer request-schema grant depends on the Browser Addon stack. Source
wiring and scripted fixtures do not establish an installed worker, live provider
success, or a visible Dashboard/TUI result.

The `candle_appraise` tool submits or reads a request without waiting for a model
inside its RPC. Submission requires the admitted `operator` caller envelope;
the host still checks visibility and exact worker ownership. `lane_call` and
the two host request/result control tools are not exported to agents.

The tool schemas use the host-supported object union subset. Only Relation
requests carry `task_id`; only finished replies carry `result`.

Each intent retains the payout identity, stage, original Relation task ID, input,
schema and rendered prompt before it can appear in `lane_host_requests`.
Only the rendered prompt is sent as a model message; audit identity is not extra
grading evidence. Configure each named output through the existing installation
Exact route. The package baseline and request-schema grant remain mandatory.

The persistent state directory contains one versioned record per request. Reads
validate the complete record and input digest. Reusing an ID for different input
or replacing an already retained terminal result is refused. A new incarnation
on the same installation state can continue a pending intent or read its original
result. `outcome_unknown` is terminal: it never becomes a fresh model request.
Initial store creation syncs the installation parent before admitting work.
Missing or replaced storage is an error, including individual reads.
Directory sync failure makes that running worker refuse further reads/listings;
it cannot advertise an unconfirmed write as a completed judgment.

`lane_host_requests` answers in pages (`[world] host_request_pages = true`). A
page carries pending requests in rising request id order, as many as fit one
reply frame, and nothing beside them. The host passes the last id of a page back
as `after` to get the next page; an empty page ends the listing. An intent is
stored when a page that carries it alone fits the manifest's actual reply frame;
other pending intents do not change that answer. An intent that
cannot fit such a page ends as the body-free `request_body_refused` result. A
reduced frame that cannot carry a retained request refuses that page explicitly
instead of silently hiding pending requests.

`lane_observe` exposes pending/finished counts and request IDs. When an ID list
would exceed the declared reply frame, counts remain available and the output
explicitly identifies the individual-read path. A finished request means a
terminal Exact result was retained; it does not mean a grade passed domain
validation, money was paid, or a Goal completed.

Observation uses the common derive-only `binding`/`sources` envelope. Candle
does not declare an action tool, so the host does not send action context to
`lane_observe`. The host binds each returned observation to its original worker
instance and incarnation; the row subject identifies `candle_appraise`, not a
worker-supplied authority. Exported tool calls retain their separate admitted
caller envelope.

Finished worker records retain the request ID, input digest and result without
the input body. Deploy this revision with the
[worker state hard cut](../../docs/guides/EXACT-WORKER-STATE-HARD-CUT.md).

The masc server carries this package. Declare it with `package = "candle-appraiser"`,
then run `masc exact-addon-setup --declared --base-path <base-path>`, which writes
the package under `<base-path>/.masc/packages/` and builds its image
([TOML installation](../../docs/guides/lane-addon-toml.md#서버가-가진-exact-패키지)).
State that still holds worker record v1 needs the hard cut above before the move.
A declaration that pins the package with `manifest_path` builds the image from
the repository root instead:

```sh
docker build -f addons/candle-appraiser/Dockerfile -t masc-lane-candle-appraiser:0.1.8 addons
```

Select this revision with the server stopped (see
[TOML installation](../../docs/guides/lane-addon-toml.md)). This revision names `[world] exact_protocol = 1`.
A server that knows `exact_protocol` refuses a manifest that does not name the
protocol it speaks, and a server that does not know the key refuses this one.
A revision before 0.1.6 answers `capacity_wait`, which a server that
includes [#52731](https://github.com/jeong-sik/masc/pull/52731) no longer reads.

The host mounts the package at `/addon` and its installation-owned persistent
state at `/state`, using the existing container/engine ownership contract.
Provider keys do not belong in this container.

The package now shares `addons/exact_worker.py` with the Workspace Curator
worker. The image includes that module beside `protocol.py`; the 0.1.1 image is
required when mounting this package source. Pending and terminal records retain
the original `candle-appraiser` directory, version and request digests. This
refactor does not change who may submit judgments or settle payouts.

Focused subprocess checks use scripted host results, not real provider answers:

```sh
python3 -m unittest discover -s addons/tests -p test_candle_appraiser.py
```
