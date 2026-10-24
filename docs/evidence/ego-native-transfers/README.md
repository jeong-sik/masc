# Native Ego uploads and selector drags

MASC no longer wraps file-input and chooser locators in top-document CSS
preflight or postflight. `setInputFiles` receives the observed native locator
or ref unchanged. The upload receipt's `chosen` describes regular staged files
handed to the SDK, not a readback of input.files or proof of submission. Sandbox
file authorization, private staging and the task-space file lease remain.
Chooser waits use the SDK default and host cancellation, without MASC's own
5000ms or command deadline. Cleanup of an unanswered chooser remains.

Selector-to-selector drag without waypoints calls `page.dragAndDrop` directly.
Coordinate, scene-identity and custom-waypoint drags retain their distinct
MASC contract and raw button-release cleanup.

## Evidence

- Installed Ego 0.6.0.20 executed the production `nativeUpload` function for
  five targets: input, label, wrapper, shadow input and observed snapshot ref.
  The owned fixture's input metadata and snapshot showed the staged file.
- Production `nativeTargetInput` dispatched native dragAndDrop; the fixture
  received a trusted drop and showed "Native drop completed".
- [proof.json](proof.json) binds those results to both production function
  hashes; [sdk-output.txt](sdk-output.txt) and the inspected
  [native-transfers.png](native-transfers.png) record the observed state.
- Node production-boundary tests cover unchanged native selectors and uncertain
  failure without replay. OCaml sources parse; full host tests remain separate.

This evidence proves the production JavaScript on installed Ego, not full OCaml
host routing, a real Keeper workflow or deployment. The selected workflow-layer
CI run 40072146277 failed compilation on a pointer_target fragile-match warning
before tests ran; its repair is tracked separately on the bottom stack layer.
No local Dune/full regression or installed MASC replacement is claimed.

Remaining adapters were checked against the SDK: document-window scrolling is
not wheel-under-pointer; direct href navigation preserves observed node and
referrer semantics; scene/coordinate identity has no Ego equivalent. Dialogs
and downloads already use native SDK calls, retaining only MASC receipts and
artifact/process/file lifetime integration. The continuing goal still needs
host and real Keeper evidence. Resume task space 4 until that goal ends.
