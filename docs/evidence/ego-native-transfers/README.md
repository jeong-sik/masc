# Native Ego uploads and selector drags

MASC no longer wraps file-input and chooser locators in top-document CSS
preflight or postflight. `setInputFiles` receives the observed native locator
or ref unchanged. The upload receipt's `chosen` describes regular staged files
handed to the SDK, not a readback of input.files or proof of submission. Sandbox
file authorization, private staging and the task-space file lease remain.
Chooser waits use the SDK default and host cancellation, without MASC's own
5000ms or command deadline. Cleanup of a captured chooser not handed files
remains. Once setFiles enters, the SDK owns its cleanup even on failure.

Selector-to-selector drag without waypoints calls `page.dragAndDrop` directly.
Coordinate, scene-identity and custom-waypoint drags retain their distinct
MASC contract and raw button-release cleanup. The SDK's native drag can be
interrupted before release. On an error MASC sends native mouse.up once;
missing/failed release or a dialog keeps the existing release-uncertain state,
so later input is refused while observation/dialog handling/finish remain.

## Evidence

- Installed Ego 0.6.0.20 executed the production `nativeUpload` function for
  five targets: input, label, wrapper, shadow input and observed snapshot ref.
  The owned fixture's input metadata and snapshot showed the staged file.
- Production `nativeTargetInput` dispatched native dragAndDrop; the fixture
  received a trusted drop and showed "Native drop completed".
- [proof.json](proof.json) binds those results to both production function
  hashes; [sdk-output.txt](sdk-output.txt) and the inspected
  [native-transfers.png](native-transfers.png) record the observed state.
- [chooser-failure.txt](chooser-failure.txt): while the chooser was captured,
  the fixture changed its file input to text. SDK setFiles failed with
  "Node is not a file input element"; without a second setFiles call, the next
  chooser and upload succeeded in the same process.
- [drag-dialog.txt](drag-dialog.txt): an owned mousedown handler opened an
  alert. Native drag returned a dialog after mouse-down, with no mouse-up.
  After dismissal a mouse move reported buttons=0, and explicit mouse.up
  generated the missing event. This is evidence of absent release, not a claim
  that subsequent movement preserved a pressed button.
- Node production-boundary tests cover unchanged native selectors and uncertain
  failure without replay. OCaml sources parse; full host tests remain separate.

This folder proves the production JavaScript on installed Ego. It does not by
itself prove full OCaml host routing, a real Keeper workflow or deployment.
The earlier workflow-layer run 40072146277 failed on a pointer_target warning;
the bottom-layer repair and later selected-suite/runtime evidence are recorded
in the [integration audit](../ego-native-integration/). No local Dune/full
regression or installed MASC replacement is claimed.

Remaining adapters were checked against the SDK: document-window scrolling is
not wheel-under-pointer; direct href navigation preserves observed node and
referrer semantics; scene/coordinate identity has no Ego equivalent. Dialogs
and downloads already use native SDK calls, retaining only MASC receipts and
artifact/process/file lifetime integration. See the integration audit for
host/Keeper proof and lifecycle. Original space 4 was found missing; the
operator explicitly approved continuing in space 9.
