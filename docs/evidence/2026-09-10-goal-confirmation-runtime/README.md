# Actual isolated Goal confirmation API

CI run `34415189641` produced macOS arm64 runtime-probe artifact `10128900378` at `0f9b7fa1f5bd2c9f390fd331097c71f4f6905d07`. All three binary SHA256 values matched its manifest; the server executable hash was `547b513f4080ff7e8257d24247e1331e3aecf790d4f9ae69dd9a87dec7a993fd`. The artifact is explicitly not release-validated. Later parent commit 69bd37dd01 changes only a test expectation.

A new server ran on port 18943 with its own fresh base under `/Users/dancer/.masc-integration/goal-confirmation-0f9-probe2`. No existing process, production workspace or active operation was replaced. The harness generated an ephemeral Admin credential and supplied it through the existing startup credential contract; it did not save the token in these receipts.

Public MCP created a Goal and requested completion. An explicitly synthetic HTTP provider asked the production verifier tool to read a real fixture file, reported APPROVE once, and ended. The server's actual verifier pipeline persisted the proven request and run. No Goal, proof or confirmation ledger was written by the harness.

The Goal remained awaiting_confirmation until the real authenticated POST. The recorded HTTP observations then prove:

- GET without a bearer returned 401.
- A body containing an actor field and a request naming another verifier run each returned 400, leaving the Goal waiting.
- POST of the exact displayed criterion revision/request/run returned completed with human_confirmed; GET returned the identical record.
- The operator is `admin`, resolved from the credential, despite the request's spoofed agent header. This proves credential authority, not physical human presence.
- Repeating the exact POST preserved the original operator/time and emitted no duplicate completion event. One event names the same request/run/criterion.
- Reopening through public MCP invalidated the previous binding; its replay returned 400. The fixture's final phase is therefore executing, not completed.

`receipt.json`, raw HTTP request/response records, verifier requests, the confirmation event, health, binary manifest and server log preserve these joins. Goal id is `goal-1788995514248-d795c8d8`. This proves the actual server/application/auth/persistence path with a synthetic verifier, not semantic LLM quality. The separate UI PR's browser proof is not conflated with this API run.

The first setup attempt stopped at startup because the synthetic exact-output target lacked its MASC runtime declaration. No Goal was created there. The second fresh run passed; all servers started by the harness were stopped afterward. No local build was used.
