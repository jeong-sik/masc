# Capture live workspace memory for a local curator proposal

The standalone CLI can read the server-owned workspace memory inventory directly:

```sh
uv run scripts/curate-workspace-memory.py \
  --context-url http://127.0.0.1:8935/api/v1/dashboard/workspace-memory-context \
  --token-file /path/to/existing-agent.token \
  --endpoint http://127.0.0.1:11434 --model installed-model \
  --output /path/to/new-run-directory
```

`--context` and `--context-url` are mutually exclusive. The URL must name the
workspace-memory-context route on a loopback HTTP(S) origin, without credentials,
query parameters or fragments. The optional token file supplies only that GET's
Bearer header; model requests do not carry it. Neither source nor model requests
follow redirects or use environment proxies.

The output captures source HTTP status and exact response bytes before decoding.
If the response contains the literal credential bytes, the response is withheld
from disk and refused before model forwarding. This check does not detect encoded
or transformed representations of the credential. Failed HTTP, malformed JSON, unsupported context contracts and failed
Keeper discovery produce a failed receipt without calling the model. Successful
captures retain context SHA-256, individual snapshot metadata and source coverage
in the existing proposal artifacts.

This connects the existing server collector to a standalone model proposal. It
does not create a scheduled lane, verify semantic correctness, promote shared
memory, or make Keeper recall consume the proposal.

Validation: 10 CLI scenarios passed with local HTTP fixtures, including live
source capture through model proposal, source-only authentication, HTTP 401,
redirect refusal, unsupported schema, and credential-echo refusal. This is a
fixture integration result; live deployed endpoint/model execution is separate.

## Deployed endpoint observation

At 2026-09-09T18:23:18Z the local deployed MASC endpoint returned HTTP 404.
The CLI wrote a terminal failed receipt in 0.00297 seconds and produced no model
request, model response, or proposal artifact. The reviewed receipt and HTTP
status are captured in `live-unavailable-receipt.json` and
`live-unavailable-context.http.json`; raw runtime response data is not included.
This proves the unavailable-source failure path only. Successful ingestion from
the deployed server and a subsequent real local-model proposal remain unverified.
