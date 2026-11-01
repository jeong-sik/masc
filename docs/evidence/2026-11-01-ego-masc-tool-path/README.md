# Installed MASC to Ego: first tool-path acceptance

At 2026-11-01 01:48:33–01:48:39 UTC, the external coding agent called the
installed MASC server's public MCP browser tools. This is a real
server → host → browser Addon → Ego run, driven explicitly by the coding
agent, not an autonomous Keeper or native-SDK-equivalence benchmark.

The server reported source commit
`dbd032511fea4e3d04687448275c0f41abff56cc`, version `0.66.0`. Its executable
hash and the worker executable hash are recorded in `runtime-and-sdk.json`.
The worker's source commit was not independently identified. This bundle is
not installation or execution proof for the new recovery implementation.

The exact driver content digest is recorded in `proof.json`. Run:

```sh
python3 scripts/probe-browser-ego-masc.py \
  --endpoint http://127.0.0.1:8935/mcp \
  --agent YOUR_CLIENT_ID --token-file /path/to/your-client.token \
  --client-id OBSERVED_EGO_CONNECTION \
  --out artifacts/ego-native-parity/UNUSED_RUN_NAME
```

The run opened its own test Page, made eight production browser tool calls,
and closed that Page. It left the shared Space and all other Pages alone.
The HTTP fixture recorded exactly one save containing the expected Korean
and emoji text, selected option, rich HTML and trusted paste/click events.
Separate browser state returned one trusted shadow, iframe and offscreen
click; the cross-origin iframe reported the exact filled text. A deliberately
wrong initial URL received a typed pre-effect refusal, and the independent
HTTP ledger still contained one save.

`tool-calls.json` contains the actual returned tool results and each attempt's
timestamp/elapsed time. `server-ledger.json` is the independent HTTP save
oracle. `masc-browser-1.png` is the returned full-page PNG, inspected visually:
the form contains the entered text, High selection, bold rich text and Saved
record status. Its offscreen iframe region appears blank in this native
capture; the screenshot alone does not certify iframe rendering. Frame
interaction proof is the separately returned state/message. The fixture
endpoints stopped after the run. `SHA256.json` binds the retained files.
No bearer or MCP session header is retained here.

Before this run, the attached worker referenced missing Ego Space 3 and
failed tab discovery before input. The operator-authorized repair preserved
the declaration through MASC's detach/declaration-save tools and created
successor Space 6. The run uses that successor. This is recovery to a new
Space, not continuation of the missing Space or a code fix for cached
readiness. Private repair receipts remain under the original working
artifact run.

Native reference: Ego `0.6.2.5`, Chromium `156.0.8078.74`, Node `24.22.1`,
guide v2.2.0; the guide digest is retained without copying its contents.
The complete goal remains open under [the acceptance
scope](../../guides/EGO-NATIVE-PARITY.md): native comparison, other API
families, current-candidate recovery, installed upgrade and goal-only Keeper
workflows still need their own evidence.
