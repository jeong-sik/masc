# ego native HTML5 drop evidence — 2026-11-05

`html5-drop.html` holds one `draggable=true` element and one drop zone. The
drop zone cancels `dragenter` and `dragover` and reads the `text/plain` value
that `dragstart` put on the DataTransfer.

In a real ego lite TaskSpace (guide v2.2.0, macOS) the page was opened from a
local file and `page.dragAndDrop("#src", "#dst")` ran once. The page recorded a
trusted pointerdown, a trusted dragstart, dragenter, dragover, a trusted drop
whose DataTransfer value was `card-1`, and dragend with `dropEffect=copy`. The
call returned an empty receipt and no error. `html5-drop.json` holds the raw
result. The TaskSpace was finished with no kept pages.

This is the call MASC makes for a selector-to-selector `drag_to` without `via`
on an ego connection. It was run through `ego-browser nodejs`, not through the
MASC server. One fixture passing does not establish that every application
accepts the drop; read the page afterward.
