# Ego Lite support and acceptance

MASC's target is the browser work an agent can perform with the installed
`ego-browser` SDK: observe, decide, execute, observe the result, recover, and
continue in the same owned Space. Sharing an executable does not establish
equivalent capability. A passing form fixture does not complete this target.

The installed `ego-browser skill` guide is the native API reference. Record
its version and digest when comparing behavior: both the SDK and the guide
can change. MASC delegates locators, actionability, scrolling, native input
and waits to Ego. MASC owns the lane's identity, execution authority,
cancellation, file grants and retained results. A browser bridge must not
grant arbitrary host JavaScript or bypass file authorization in the name of
native parity.

## Acceptance scope

For each family, compare the same fixture and final application state through
the native SDK and the actual MASC tool path. Record source, installed binary
identity, Ego version, connection, Space and Page identity, tool calls,
elapsed times, completed effects, failures and retained screenshots. Preserve
failed runs. A different Space or worker after a failure is a replacement,
not evidence that the original work continued.

| Family | Required behavior and observation |
| --- | --- |
| Discovery and lifetime | Exact connected browser, managed and unmanaged Pages, explicit adoption/release, new/closed Pages, completion and kept Pages; truthful missing/disconnected Space state |
| Semantic observation | Viewport/full-page/subtree snapshots, native refs and locators, iframe and shadow content, stale references and page changes |
| Forms and editors | Fill/clear, focus, native key input, Unicode, single/multiple/disabled options under native semantics, plain and rich paste; independently observed saved state |
| Pointer and visual work | Trusted clicks, double clicks, hover, offscreen targets, native drag and coordinate paths, screenshots and screenshot geometry |
| Navigation and waits | Goto/reload/history, native URL/selector/load/function waits, timeout diagnostics and recovery from an unresponsive Page without changing its identity |
| Browser expressions | Native Page evaluate and browser-context fetch, structured results and native errors; browser expressions are not host code |
| Composition and SDK fidelity | Native options and result shapes, conditional decisions, several Page handles and event-scoped actions; preserve browser authority while closing gaps in the finite workflow surface |
| Events and dialogs | Popup and download waiters armed before input, event ownership, alert/confirm/prompt, interrupted input and distinct next actions without replay |
| Files | Authorized upload and chooser paths; page reads the actual bytes after staging scope ends; downloads/fetch saves are retained artifacts with verified bytes |
| Operator collaboration | Handoff blocks agent input; explicit operator completion permits takeover of the same Space and correct boundary Page; fresh observation confirms the result |
| Native recovery and diagnostics | SDK-supported Page recovery and diagnostic operations remain reachable when ordinary observation fails; browser-global operations and host-file setters require their own authority |
| Site and diagnostic state | Cookie/storage access, console/network observation, emulation and request routing through the native browser protocol, with explicit credential and browser-wide authority boundaries |
| Concurrent work and failure | Several explicit browser/Page owners, cancellation, reconnect/replacement, missing Spaces, lost results and partial progress; no hidden browser switching or duplicate effects |
| Autonomous Keeper use | Goal-only requests through a Keeper's actual discovered tool/skill surface, lasting multi-step tasks, recovery and resulting application state compared with the native task |

This table is an acceptance obligation, not a list of implemented features.
The existing integration describes native calls and limitations in
[the Ego RFC](../rfc/RFC-browser-live-ego.md). Keep an actual gap open until
the installed MASC path proves it. In particular, the workflow currently
exposes a finite set of Page methods. MASC sends no raw pointer drag, and raw
keyboard typing uses only the bounded native-window path. Neither settles earlier
uncertain input or establishes native parity; an ordinary
SDK success and a dialog interruption must not be conflated. The native raw-input
completion contract remains part of the open comparison. Additional public SDK methods, Page/Space
composition and actual Keeper acceptance remain part of the full target.

## Installed MASC tool-path fixture

`scripts/probe-browser-ego-masc.py` uses HTTP MCP and the public production
browser tools. It creates one test Page on an explicitly observed Ego
connection. It never operates another existing Page or finishes the shared
Space. Obtain the connection with `BrowserTabs mode=connections`; check its
Space and tab inventory before selecting it. A configured declaration or
cached connection row alone does not prove that its Space exists.

With an existing, current credential for your own MASC client:

```sh
python3 scripts/probe-browser-ego-masc.py \
  --endpoint http://127.0.0.1:8935/mcp \
  --agent YOUR_CLIENT_ID --token-file /path/to/your-client.token \
  --client-id OBSERVED_EGO_CONNECTION \
  --out artifacts/ego-native-parity/UNUSED_RUN_NAME
```

The fixture exercises Unicode form entry, option selection, trusted rich
paste and save, shadow/frame/offscreen input, a wrong-URL refusal, a final
snapshot and screenshot, then closes only its own test Page. Its HTTP server
records the save independently of the browser's tool receipts. Every tool
reply and its elapsed time is retained. An unexpected result stops execution;
the test Page remains for inspection and the sequence is never replayed.
The fixture server stops when the run ends, so a preserved failed Page is a
historical observation, not a still-live application endpoint.

If the close request itself loses its response, the Page state is unconfirmed;
the driver neither claims it remained open nor repeats the close.

Outputs are private working evidence under `artifacts/`. Inspect and sanitize
selected records before retaining them under `docs/evidence/`. They can
contain runtime/browser identifiers; never include the bearer or the MCP
session identifier. Record and verify the server's actual source/binary
identity separately. The script's own digest identifies the driver, not the
running server. These are operator-driven tool-path observations, not an
autonomous Keeper run, a deployment receipt, a full SDK equivalence verdict
or Release verification.

Continue the remaining families above with actual MASC tools and then
goal-only Keeper requests. Compare full task latency and model/tool latency
separately; report failures and unfinished tasks alongside successful ones.
No arbitrary success percentage or runtime execution budget replaces the
required observed behavior. Broad progress is tracked in
[issue #45556](https://github.com/jeong-sik/masc/issues/45556).
