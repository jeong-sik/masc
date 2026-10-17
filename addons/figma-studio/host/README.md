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
adapter announces service sessions; the configured Keeper must explicitly bind
the intended document before submitting work. The adapter validates protocol
and capabilities before dequeuing any work. Unsupported versions fail before
any Figma operation is submitted.

State is private, has one writer and binds to the configured endpoints and
credential fingerprints. Changing either identity requires a new directory.
The ledger records each dequeued request before sending it. A lost reply is
reconciled by reading its operation ID, never by resubmitting the edit. Readback
chunks are reassembled with length and digest verification. Results, including
any required MCP size reduction, are retained before delivery and retried with
the original worker identity. The independent service and Addon retain their
own evidence; an adapter restart cannot relabel it for a replacement worker.

For contract verification, provide a Figma Studio distribution ZIP to
`addons/tests/figma_studio_integration.py`. The test extracts it outside the
source trees and exercises the actual service, Plugin JavaScript, adapter and
worker. Only the editor document and MASC authenticated routing are fixtures.
