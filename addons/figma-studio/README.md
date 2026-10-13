# Figma Studio Lane Addon

This optional package exposes native design capture, bounded edits, retained
PNG/JSON snapshots and explicit structural validation to its configured Keeper.
A companion Figma Plugin and host relay live in the `figma-mcp` repository under
`plugin/studio` and `studio`. This worker does not make network requests.

Build from the MASC repository root:

```sh
docker build -f addons/figma-studio/Dockerfile -t masc-lane-figma-studio:0.1.0 addons
```

Copy `install.toml` to the resolved MASC config root's `lane-addons` directory,
and set its `manifest_path` to this package's actual manifest. Configure the
Keeper name and a distinct authenticated relay agent. Keep the Figma PAT and
MASC credential in the host relay's private configuration, outside the binding,
Plugin, model prompts and artifacts. Use a Full-profile MASC MCP connection for
the relay; a bearer agent is not an operator or a Keeper identity.

The package exports `masc_figma_status`, `masc_figma_bind`, `masc_figma_submit`,
`masc_figma_operation`, `masc_figma_snapshot`, `masc_figma_validate`,
`masc_figma_rest_capture`, `masc_figma_rest_operation`, and `masc_figma_relay`.
Their private `lane_call` entrypoint receives the trusted
host caller. Direct raw export calls are refused. Discovery can be shared;
call authorization is enforced inside the package. The configured relay may
also read `masc_figma_snapshot` to download an existing snapshot; it cannot
bind sessions, submit edits, request REST captures or validate snapshots.
An HTTP Admin credential is still an authenticated agent, not an operator
principal. Merely naming its configuration "owner" does not grant owner access.
Only one visible Studio
installation can currently export these names.

The first host observation configures the binding. Tools are discoverable before
that observation but refuse execution until configured. Binding identity is
immutable within a persistent volume. Change the logical installation when
changing its owner; old private data must not be relabeled for a new caller.

A prepared request is durable. A relay poll marks it dispatched before returning
the command. Lost replies do not put it back on the queue. Restart rejects
undispatched requests and retains dispatched ones as `outcome_unknown`. The
worker's boot ID is package-generated, not a host incarnation. New Plugin/worker
sessions require explicit pairing and binding. Duplicate operation IDs must
carry identical input. Accepted result and snapshot insertion are one SQLite
transaction. Keep `/state` on the host-managed persistent volume.

Relay acknowledgements contain the operation identity, state and snapshot
reference without repeating the full readback. `masc_figma_operation` returns
completion counts; supply `completed_offset` and `completed_limit` together
to read a range of the retained completion entries. Upstream omissions remain
explicit in `completed_available` and `completed_omitted`. The package's byte
limit applies to replies and published observations; the host owns incoming
transport framing, including its private caller envelope.

`masc_figma_snapshot` returns native JSON in model-visible text and the PNG
as an MCP image. `masc_figma_validate` checks supplied node/property assertions;
it never certifies appearance. Its report records the evaluator and exact
snapshot ID. The next `lane_observe` transfers snapshot, PNG and report bytes in
the existing artifact envelope. Export success does not establish that host
retention or terminal display has completed.

REST capture uses its own request queue and never requires a Plugin session.
Submit `masc_figma_rest_capture` with `operation_id`, `file_key`, `root_id` and
optional `version`. The host relay reads the node and renders the exact returned
version, then retains a `rest_version` snapshot. `masc_figma_rest_operation`
reports its outcome. A server snapshot cannot be used as a live edit baseline
without verifying its association to the Plugin document; this initial version
requires a fresh Plugin capture for edits.

For terminal preview, save the complete snapshot tool result and run the
companion `studio/preview.py result.json --kitty`. It checks the PNG digest and
uses timg's Kitty backend. Visual inspection still needs a capable terminal or
image viewer. A generated Kitty command is not evidence that a human saw it.

Focused verification:

```sh
python3 -m unittest discover -s addons/tests -p test_figma_studio.py -v
ruff check addons/figma-studio addons/tests/test_figma_studio.py
pyright addons/figma-studio
```

These exercise the real worker entrypoint with a fixture document. They do not
establish Docker installation, real Figma edits, a connected Keeper, visual
quality, or application behavior. See the [platform capability reference](../../docs/design/figma-platform-capabilities.md).
