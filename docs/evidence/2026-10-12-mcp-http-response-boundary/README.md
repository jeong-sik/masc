# MCP HTTP response write and acknowledgement boundary

Production source head: `0287750a15163b4972212ad16b3efbc2636a9aaa`.
This continuation changes evidence only.

## TCP boundary

An actual Eio_main loopback listen on ephemeral port 0 returned exit 2:
Unix.EPERM at bind. The execution sandbox does not allow the required socket
operation, and elevation is unavailable. The bounded smoke source and output
are stored here. No successful TCP/HTTP socket test is claimed.

## Executed memory-writer boundary

```
python3 docs/evidence/2026-10-12-mcp-http-response-boundary/run.py .
```

The interpreter loads the entire production MCP transport protocol, official
tool serializer, MCP dispatcher and MCP HTTP module. It also interprets the
installed Cohttp_eio Server source to expose its writer pair for this harness;
the installed Cohttp IO/Utils/Body and real Eio scheduler/buffered writer run
normally. The harness supplies an in-memory Eio sink and actual constructed
HTTP requests to the production request_handler. No listener is started.
This is handler/writer execution, not client-network transport.

Explicit doubles remain for Agent Core content/effect types, ASCII-only UTF-8
sanitizing, unexercised generated tool IDs, build metadata, guidance and logging.
The handler's private state is instantiated directly. The fixture uses only
nonblank string request IDs and ASCII text; it does not certify ID generation,
media schemas, invalid UTF-8 or production logging. Fs/real Keeper sessions and
capabilities are not accessed. Synthetic authentication values are never printed.

## Results

The saved run returned exit 0:

- Real production initialize/initialized handshake succeeded (200/202).
- Successful tool response: effect counter 1, post-flush acknowledgement 1.
  The acknowledgement callback verified complete response bytes and valid JSON.
- An explicitly failing sink write: effect counter 2, acknowledgement stays 1.
- Actual Eio cancellation during sink write: effect counter 3, acknowledgement
  stays 1 and cancellation propagates.
- Unauthorized request returns 401 without an additional effect or acknowledgement.
- A later normal request succeeds: effect counter 4, acknowledgements 2.
  The actual dispatcher snapshot remains Ready, with 4 calls and 1 rejection.

Thus inability to write the response does not establish that a tool did not
execute. The effect and response-acknowledgement stages remain distinct; the
failed cases must not be used as permission to duplicate the tool effect.
The acknowledgement proves server bytes flushed to the supplied sink, not
that a client, model or user read the result.

Exact production source hashes, installed Cohttp server hash, runner, logs and
artifact hashes are stored here. No Dune build or CI was run. Muse terminal
admission, durable execution receipts, full integration typing, actual TCP,
live providers, installed TUI/dashboard screenshots and formal approval/merge
remain unverified.
