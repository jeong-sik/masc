# Native input window foundation

This record supports the pure decoder introduced by #47404. It does not enable
MASC raw typing or settle the product's retained Input state.

The actual module at `b5a838d21bf9d13fa8ee9bbb80846fa810e21fd9` generated
the marker strings and classified one native `keyboard.type('a')` invocation.
The installed executable was Ego Lite 0.6.2.5, SHA-256
`f1af063d9309fda5c6790a4e2342b573cf8d82759b808edba7983ec9770cd110`.
No upstream SDK modification, shim, synthetic action receipt, key-up, reset or
input replay was used.

## Observed result

- Native invocation exited 0 and returned actual JavaScript `undefined`, retained
  separately as `returnKind: void`.
- A named isolated context was discovered through the native bootstrap drain.
  Both marker evaluations used its native unique context ID.
- One final drain contained 37 native events. The authentic start and end were
  at indices 0 and 32, with the same native session and execution context.
- The compiled decoder returned `VERIFIED_EXPERIMENTAL_SDK_TAIL_ONLY`.
- The owned field contained `a`. Its closed server ledger joined one document,
  five complete POST bodies and five trusted events: focus, keydown, beforeinput,
  input, keyup. The original fixture process exited 0 after joining its handlers.
- [Actual browser image](actual-one-key.png) shows the same document and field.

An initial attempt used an invalid bare role locator and stopped at focus,
before an intent or keyboard call. A distinct pure read confirmed the same empty
document before the corrected CSS locator was used. Both attempts remain in the
private run record; there was exactly one raw keyboard invocation.

The former owned Space 24 was independently reported missing before navigation.
The user explicitly approved one replacement Space; this sample used its initial
Page, Space 25 / p1. It does not settle or recreate the former Space.

## Retained scope

[normal-key-projection.json](normal-key-projection.json) is an explicitly derived
public projection. It retains the expected bindings, native bootstrap identity,
marker replies, actual void tag, every event's method/session and the two binding
payloads. Other interval event parameters are omitted because native Network events can
include browser cookies and headers. This projection is not the complete native
array that the decoder consumed. The private originals are identified by digest,
and were inspected independently without publishing their sensitive contents.

The separate module component compiled the complete new interface, implementation
and seven contract tests against the actual Surface identity declarations and
encoder. All seven passed, including old-capture/new-Page rejection, protocol-only
`Not_invoked` rejection, malformed/duplicate bounds, native context/session changes
and lifecycle relevance within the interval. This was not a full MASC/Peer build,
CI result or installed MASC tool run.

## Remaining work

Connect the verified completion to the existing Release/Input authority with the
current command, generation and durable writer CAS. Apply it to ordinary
`type_text` and workflow `keyboard.type`, including popup Page progression.
Measure interrupted input, main-frame/iframe/OOPIF dialogs, FIFO loss, lifecycle,
control and transport failures before enabling those routes. This normal sample
proves neither physical input freshness nor complete Ego Lite parity.
