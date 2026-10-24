# MASC host adapter for Figma Studio

Run this adapter on the host. The Lane Addon stays in its network-isolated
microVM. Install and run Figma Studio separately from its distribution ZIP;
neither process imports a module from the other repository.

```text
Keeper → MASC host → isolated Addon
                       ↑ authenticated MCP
                 MASC host adapter → Figma Studio HTTP API ← Figma Plugin
```

The adapter needs the service URL and its client credential. The Plugin token
and Figma PAT belong only to the service. The service does not connect to MASC.
The existing general-purpose Figma MCP server is not needed for this path.

Create a private configuration (`chmod 600`) outside either source checkout:

```toml
[masc]
url = "http://127.0.0.1:8935/mcp"
token = "REPLACE_WITH_REGISTERED_RELAY_AGENT_TOKEN"

[figma]
url = "http://127.0.0.1:8941"
client_token = "REPLACE_WITH_SERVICE_CLIENT_TOKEN"

[adapter]
state_directory = "./adapter-state"
poll_interval_ms = 1000
request_timeout_seconds = 30
```

```sh
python3 addons/figma-studio/host/adapter.py --config /path/to/private/adapter.toml
```

Configure the same registered agent as `relay_agent` in the Addon binding. The
adapter validates protocol and capabilities first. No new work is dequeued:
there is no reviewed session-liveness contract yet, and `/v1/status` presence
does not prove the Plugin is connected, so the admission path stays closed
until such a contract exists. Already-submitted operations are still queried
by operation ID.

State is private, has one writer and binds to the configured endpoints.
Credential rotation retains the same ledger; credentials are not part of its
durable identity. Each delivery retains its original worker and service identity.
An endpoint binding mismatch refuses startup without modifying the ledger.
The ledger records each dequeued request before sending it. A lost reply is
reconciled by reading its operation ID, never by resubmitting the edit. Readback
chunks are reassembled with length and digest verification. Results, including
any required MCP size reduction, are retained before delivery and retried with
the original worker identity. The independent service and Addon retain their
own evidence; an adapter restart cannot relabel it for a replacement worker.
There is a crash gap between receiving a dequeued request and persisting it;
the adapter cannot recover that request from its ledger if it stops in that gap.

This is a deferred experiment. The current service has no reviewed session
liveness or remote cancellation contract, so the adapter dequeues no new work.
Session presence in `/v1/status` does not prove the Plugin is connected;
absence does not prove a queued operation cannot execute. Prepared/dispatched
operations remain submitted and are queried by operation ID until the service
supplies a terminal result. The adapter cannot
claim closure or prevent delayed edits after reconnect on its own. Do not merge
or install this experiment as a completed product.

For contract verification, provide a Figma Studio distribution ZIP to
`addons/tests/figma_studio_integration.py`. The test extracts it outside the
source trees and exercises the actual service, Plugin JavaScript, adapter and
worker. Only the editor document and MASC authenticated routing are fixtures.
