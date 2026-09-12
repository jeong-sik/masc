# Read a Keeper's retained browser observations

Browser Lane's `h` opens the selected Keeper's retained observations from its 100 most recent tool-call receipts. The title names the Keeper and says these are historical reads. `[` moves toward the newest receipt and `]` toward older receipts; `j`/`k` scroll the retained page. `r` reloads the receipt list. `h` or Escape returns to the current browser. `y` copies the historical receipt identity, artifact and observed URL, explicitly marked `current=false`.

Only normalized artifact references with the Browser_observation MIME and an execution identity appear. The selected artifact is fetched lazily through the existing authenticated artifact endpoint; that endpoint verifies the stored content address. The TUI verifies the returned identity/byte length and decodes the original browser scene, including scope, viewport and truncation. Missing artifacts are visible errors; log previews do not stand in for complete pages.

Historical state is separate from the live Browser Lane state. Selection uses a distinct async generation, so late artifact results cannot replace a newer selection or a closed viewer. Loading the receipt list does not consume navigation keys as new requests. Browser actions, screenshots and current-page cadence requests are inactive while this reader is open; its scene is never passed as a live action target.

Tab and Shift-Tab use the global surface ring and close the historical reader. A live scene held underneath the reader does not receive these keys.

This is a reader for committed observations, not a recording of every rendered browser frame. It needs the retained-observation producer in #35546. The list covers only the explicitly stated recent receipt window. It does not infer an aligned screenshot, hidden page content, or current validity from old node references.

Validation includes a native PTY fixture with a delayed artifact: move to another saved page, release the late result, and verify that the selected content remains unchanged. Action and screenshot keys must issue no current browser requests. Returning to the browser restores its separately held current page. The model test covers list-load navigation, artifact validation and schema-rejected producer receipts.
